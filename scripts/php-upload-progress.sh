#!/usr/bin/env bash
# Check session.upload_progress.enabled in every APT-managed PHP php.ini and
# optionally disable it. Ubuntu/Debian layout: /etc/php/<version>/<sapi>/php.ini
# No changes are made unless --patch is supplied.
set -Eeuo pipefail
export LC_ALL=C

DIRECTIVE=session.upload_progress.enabled
# PHP's built-in value when the directive is not set in any ini file.
DEFAULT_VALUE=1
# Root of the Debian/Ubuntu PHP configuration tree.
PHP_ETC=${PHP_ETC:-/etc/php}

usage() {
  cat <<'EOF'
Usage: php-upload-progress.sh [--check | --patch] [--yes] [--no-reload]

  --check      Report session.upload_progress.enabled for every PHP version
               and SAPI under /etc/php (default, no changes)
  --patch      Set session.upload_progress.enabled = 0 in each php.ini that
               leaves it enabled, then reload PHP-FPM / Apache
  --yes        Skip the confirmation prompt (requires --patch)
  --no-reload  Do not reload services after patching (requires --patch)
  --help       Show help

Exit codes: 0 = disabled everywhere; 2 = review required; 1 = error.
EOF
}

MODE=check
YES=0
RELOAD=1
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --patch) MODE=patch ;;
    --yes) YES=1 ;;
    --no-reload) RELOAD=0 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ "$MODE" != patch ]] && (( YES || ! RELOAD )); then
  printf '%s\n' '--yes and --no-reload are valid only with --patch' >&2
  exit 1
fi
for cmd in awk sort; do
  command -v "$cmd" >/dev/null || { printf 'Missing command: %s\n' "$cmd" >&2; exit 1; }
done

# Shared awk helpers: trim whitespace; parse an ini value (quotes, ; comments).
AWK_LIB='
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function ini_value(s,   j) {
  s = trim(s)
  if (substr(s, 1, 1) == "\"") {
    s = substr(s, 2); j = index(s, "\""); if (j) s = substr(s, 1, j - 1)
  } else {
    j = index(s, ";"); if (j) s = trim(substr(s, 1, j - 1))
  }
  return s
}
function key_of(s,   i) { i = index(s, "="); return i ? trim(substr(s, 1, i - 1)) : "" }
'

# Print "<value>\t<line>" for the last active setting of DIRECTIVE in an ini file.
ini_lookup() {
  awk -v key="$DIRECTIVE" "$AWK_LIB"'
    { line = $0; sub(/\r$/, "", line) }
    key_of(line) == key { value = ini_value(substr(line, index(line, "=") + 1)); num = FNR }
    END { if (num) printf "%s\t%d\n", value, num }
  ' "$1"
}

# Print "<line>\t<directive>\t<value>" for each PHP-FPM pool override.
pool_overrides() {
  awk -v key="$DIRECTIVE" "$AWK_LIB"'
    { line = $0; sub(/\r$/, "", line); k = key_of(line) }
    k == "php_value[" key "]" || k == "php_admin_value[" key "]" ||
    k == "php_flag[" key "]"  || k == "php_admin_flag[" key "]" {
      printf "%d\t%s\t%s\n", FNR, k, ini_value(substr(line, index(line, "=") + 1))
    }
  ' "$1"
}

# Write php.ini to stdout with DIRECTIVE set to 0. Replaces active settings;
# otherwise inserts after the commented default, the [Session] header, or at the end.
build_candidate() {
  awk -v key="$DIRECTIVE" -v setting="$DIRECTIVE = 0" "$AWK_LIB"'
    NR == FNR {
      line = $0; sub(/\r$/, "", line); k = key_of(line); c = k
      sub(/^;+[ \t]*/, "", c)
      if (k == key) active = 1
      else if (c == key) commented = FNR
      else if (trim(line) == "[Session]") session = FNR
      next
    }
    active { line = $0; sub(/\r$/, "", line); if (key_of(line) == key) print setting; else print; next }
    { print }
    FNR == commented || (!commented && FNR == session) { print setting }
    END { if (!active && !commented && !session) printf "\n[Session]\n%s\n", setting }
  ' "$1" "$1"
}

# PHP treats On/Yes/True and non-zero integers as enabled.
is_enabled() {
  local v=${1,,}
  case "$v" in
    on|yes|true) return 0 ;;
    off|no|false|none|'') return 1 ;;
  esac
  [[ "$v" =~ ^[+-]?0*[1-9] ]]
}

ini_version() { local d=${1%/*/php.ini}; printf '%s' "${d##*/}"; }
ini_sapi() { local d=${1%/php.ini}; printf '%s' "${d##*/}"; }

declare -a INI_FILES=()
declare -A INI_STATUS=()
declare -A INI_SOURCE=()
declare -a POOL_OVERRIDES=()
REVIEW_COUNT=0

scan() {
  INI_FILES=()
  INI_STATUS=()
  INI_SOURCE=()
  POOL_OVERRIDES=()

  local -a found=()
  local ini dir file result value line_no source from_conf_d key status
  shopt -s nullglob
  found=("$PHP_ETC"/*/*/php.ini)
  shopt -u nullglob
  ((${#found[@]})) || return 0
  mapfile -t INI_FILES < <(printf '%s\n' "${found[@]}" | sort -V)

  for ini in "${INI_FILES[@]}"; do
    dir=${ini%/php.ini}
    value=$DEFAULT_VALUE
    source="not set (PHP default: $DEFAULT_VALUE)"
    from_conf_d=0

    # PHP reads php.ini, then conf.d/*.ini in name order; the last setting wins.
    for file in "$ini" "$dir"/conf.d/*.ini; do
      [[ -f "$file" ]] || continue
      result=$(ini_lookup "$file")
      [[ -n "$result" ]] || continue
      value=${result%$'\t'*}
      line_no=${result##*$'\t'}
      source="$file:$line_no = ${value:-(empty)}"
      if [[ "$file" == "$ini" ]]; then from_conf_d=0; else from_conf_d=1; fi
    done

    if ! is_enabled "$value"; then
      INI_STATUS[$ini]=DISABLED
    elif (( from_conf_d )); then
      INI_STATUS[$ini]='ENABLED (conf.d)'
    else
      INI_STATUS[$ini]=ENABLED
    fi
    INI_SOURCE[$ini]=$source

    # PHP-FPM pools can override php.ini with php_value / php_admin_value.
    [[ "${dir##*/}" == fpm ]] || continue
    for file in "$dir/php-fpm.conf" "$dir"/pool.d/*.conf; do
      [[ -f "$file" ]] || continue
      while IFS=$'\t' read -r line_no key value; do
        if is_enabled "$value"; then status=ENABLED; else status=DISABLED; fi
        POOL_OVERRIDES+=("$ini"$'\t'"$status"$'\t'"$file:$line_no $key = ${value:-(empty)}")
      done < <(pool_overrides "$file")
    done
  done
}

report() {
  local title=$1 ini entry status detail conf_d=0 pool_enabled=0
  REVIEW_COUNT=0
  printf '\n========== %s ==========\n' "$title"
  printf 'Directive: %s (PHP default when not set: %s, enabled)\n' "$DIRECTIVE" "$DEFAULT_VALUE"

  if ((${#INI_FILES[@]} == 0)); then
    printf 'No php.ini files found under %s/<version>/<sapi>/.\n' "$PHP_ETC"
    printf 'This does NOT check Docker, custom builds or other PHP installs.\n'
    REVIEW_COUNT=1
    return 0
  fi

  for ini in "${INI_FILES[@]}"; do
    status=${INI_STATUS[$ini]}
    printf '\nPHP %-5s %-8s | %s\n' "$(ini_version "$ini")" "$(ini_sapi "$ini")" "$status"
    printf '  php.ini: %s\n' "$ini"
    printf '  Set by:  %s\n' "${INI_SOURCE[$ini]}"
    if [[ "$status" != DISABLED ]]; then REVIEW_COUNT=$((REVIEW_COUNT + 1)); fi
    if [[ "$status" == 'ENABLED (conf.d)' ]]; then conf_d=1; fi
  done

  if ((${#POOL_OVERRIDES[@]})); then
    printf '\nPHP-FPM pool overrides (take precedence over php.ini for that pool):\n'
    for entry in "${POOL_OVERRIDES[@]}"; do
      IFS=$'\t' read -r ini status detail <<<"$entry"
      printf '  PHP %-5s %-8s | %-8s | %s\n' "$(ini_version "$ini")" fpm "$status" "$detail"
      if [[ "$status" == ENABLED ]]; then
        REVIEW_COUNT=$((REVIEW_COUNT + 1))
        pool_enabled=1
      fi
    done
  fi

  printf '\nSummary: %d item(s) require review.\n' "$REVIEW_COUNT"
  if (( conf_d )); then
    printf 'NOTE: ENABLED (conf.d) means a conf.d file overrides php.ini. --patch does\n'
    printf '      not change conf.d files; set the value to 0 in the file shown.\n'
  fi
  if (( pool_enabled )); then
    printf 'NOTE: --patch does not change PHP-FPM pool files; remove or set the\n'
    printf '      enabling pool override to 0 manually.\n'
  fi
}

# Test a service's configuration before reloading it (passes if no test tool exists).
test_service_config() {
  local svc=$1 version
  case "$svc" in
    apache2)
      if command -v apache2ctl >/dev/null; then apache2ctl configtest; fi ;;
    php*-fpm)
      version=${svc#php}; version=${version%-fpm}
      if command -v "php-fpm$version" >/dev/null; then "php-fpm$version" -t; fi ;;
  esac
}

# Reload one service if it is running. Returns 1 if a reload is still needed.
reload_service() {
  local svc=$1
  if (( ! RELOAD )); then
    printf 'Reload skipped (--no-reload): %s\n' "$svc"
    return 1
  fi
  if ! command -v systemctl >/dev/null; then
    printf 'systemctl not found: reload %s manually.\n' "$svc"
    return 1
  fi
  if ! systemctl is-active --quiet "$svc"; then
    printf '%s is not running: no reload needed.\n' "$svc"
    return 0
  fi
  if ! test_service_config "$svc"; then
    printf 'Config test failed: %s NOT reloaded.\n' "$svc"
    return 1
  fi
  if systemctl reload "$svc"; then
    printf 'Reloaded %s\n' "$svc"
  else
    printf 'Reload failed: %s\n' "$svc"
    return 1
  fi
}

if [[ "$MODE" == patch ]]; then
  if (( EUID != 0 )); then
    printf 'Patch mode requires root. Run: sudo bash %s --patch\n' "$0" >&2
    exit 1
  fi
  for cmd in diff mktemp readlink; do
    command -v "$cmd" >/dev/null || { printf 'Missing command: %s\n' "$cmd" >&2; exit 1; }
  done

  scan
  report 'BEFORE PATCH'

  declare -a PLAN=()
  declare -a SERVICES=()
  declare -A SEEN=()
  for ini in ${INI_FILES[@]+"${INI_FILES[@]}"}; do
    if [[ "${INI_STATUS[$ini]}" != ENABLED ]]; then continue; fi
    PLAN+=("$ini")
    case "$(ini_sapi "$ini")" in
      fpm) svc="php$(ini_version "$ini")-fpm" ;;
      apache2) svc=apache2 ;;
      *) continue ;;
    esac
    if [[ -z "${SEEN[$svc]:-}" ]]; then
      SEEN[$svc]=1
      SERVICES+=("$svc")
    fi
  done

  if ((${#PLAN[@]} == 0)); then
    printf '\nNothing to patch: no php.ini leaves %s enabled.\n' "$DIRECTIVE"
    if (( REVIEW_COUNT > 0 )); then exit 2; fi
    exit 0
  fi

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf -- "$WORK_DIR"' EXIT

  printf '\n========== PATCH PREVIEW ==========\n'
  for i in "${!PLAN[@]}"; do
    build_candidate "${PLAN[$i]}" > "$WORK_DIR/$i.ini"
    diff -u --label "${PLAN[$i]}" --label "${PLAN[$i]} (patched)" \
      -- "${PLAN[$i]}" "$WORK_DIR/$i.ini" || true
  done
  if ((${#SERVICES[@]})); then
    if (( RELOAD )); then
      printf '\nServices to reload after patching: %s\n' "${SERVICES[*]}"
    else
      printf '\nServices that will need a reload (--no-reload given): %s\n' "${SERVICES[*]}"
    fi
  fi

  if (( ! YES )); then
    printf '\nApply the php.ini changes shown above? [y/N] '
    read -r answer || exit 1
    case "$answer" in
      y|Y|yes|YES) ;;
      *) printf 'Cancelled. No changes made.\n'; exit 2 ;;
    esac
  fi

  # Back up each php.ini, then replace it atomically with owner and mode kept.
  printf '\n========== APPLYING ==========\n'
  STAMP=$(date +%Y%m%d%H%M%S)
  declare -A DONE=()
  for i in "${!PLAN[@]}"; do
    ini=${PLAN[$i]}
    target=$(readlink -f -- "$ini")
    if [[ -n "${DONE[$target]:-}" ]]; then continue; fi
    DONE[$target]=1
    backup="$target.bak-$STAMP"
    cp -p -- "$target" "$backup"
    tmp=$(mktemp "$target.XXXXXX")
    cat -- "$WORK_DIR/$i.ini" > "$tmp"
    chown --reference="$target" -- "$tmp"
    chmod --reference="$target" -- "$tmp"
    mv -f -- "$tmp" "$target"
    printf 'Updated %s (backup: %s)\n' "$ini" "$backup"
  done

  RELOAD_PENDING=0
  if ((${#SERVICES[@]})); then
    printf '\n========== RELOAD ==========\n'
    for svc in "${SERVICES[@]}"; do
      if ! reload_service "$svc"; then RELOAD_PENDING=$((RELOAD_PENDING + 1)); fi
    done
  fi

  scan
  report 'AFTER PATCH'
  if (( RELOAD_PENDING > 0 )); then
    printf '\n%d service(s) still need a reload before the change takes effect.\n' "$RELOAD_PENDING"
    REVIEW_COUNT=$((REVIEW_COUNT + RELOAD_PENDING))
  fi
else
  scan
  report 'SESSION UPLOAD PROGRESS CHECK'
fi

if (( REVIEW_COUNT > 0 )); then
  exit 2
fi
