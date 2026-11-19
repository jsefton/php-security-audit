#!/usr/bin/env bash
# Run every read-only check script in this directory and summarise the results.
# Makes no changes (--refresh only refreshes APT metadata). Run as root so
# every check can read what it needs.
set -Euo pipefail
export LC_ALL=C

# Check scripts to run, with the arguments that keep them read-only.
# Each must exit 0 = OK, 2 = review required, anything else = error.
CHECKS=(
  'php-security-audit.sh --check'
  'php-upload-progress.sh --check'
  'nginx-fastcgi-keep-conn.sh --check'
)

usage() {
  cat <<'EOF'
Usage: check-all.sh [--refresh]

  Runs each check script in this directory in read-only mode and prints a
  summary. The other scripts must be in the same directory as this one.

  --refresh  Run apt-get update first, so the PHP audit sees the latest
             package versions (requires root)
  --help     Show help

Exit codes: 0 = all checks passed; 2 = review required; 1 = a check could not complete.
EOF
}

REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --refresh) REFRESH=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
  esac
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

printf 'Host: %s\nDate: %s\n' "${HOSTNAME:-unknown}" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
if (( EUID != 0 )); then
  printf 'WARNING: not running as root; checks that need root will report an error.\n' >&2
  printf '         Run: sudo bash %s\n' "$0" >&2
fi

declare -a RESULTS=()
ERRORS=0
REVIEWS=0

# Refresh APT metadata only; this installs or upgrades nothing.
if (( REFRESH )); then
  printf '\n################ apt-get update ################\n'
  apt-get update </dev/null
  code=$?
  if (( code == 0 )); then
    result=OK
  else
    result="ERROR (exit $code)"
    ERRORS=$((ERRORS + 1))
  fi
  RESULTS+=("$(printf '%-17s %s' "$result" 'apt-get update')")
fi

for entry in "${CHECKS[@]}"; do
  read -r -a cmd <<<"$entry"
  script="$SCRIPT_DIR/${cmd[0]}"
  printf '\n################ %s ################\n' "$entry"

  if [[ ! -f "$script" ]]; then
    printf 'Script not found: %s\n' "$script" >&2
    result=MISSING
    ERRORS=$((ERRORS + 1))
  else
    bash "$script" "${cmd[@]:1}" </dev/null
    code=$?
    case "$code" in
      0) result=OK ;;
      2) result='REVIEW REQUIRED'; REVIEWS=$((REVIEWS + 1)) ;;
      *) result="ERROR (exit $code)"; ERRORS=$((ERRORS + 1)) ;;
    esac
  fi
  RESULTS+=("$(printf '%-17s %s' "$result" "$entry")")
done

printf '\n========== CHECK-ALL SUMMARY ==========\n'
printf '%s\n' "${RESULTS[@]}"

if (( ERRORS > 0 )); then
  printf '\n%d check(s) could not complete, so the results are incomplete.\n' "$ERRORS"
  exit 1
elif (( REVIEWS > 0 )); then
  printf '\n%d check(s) require review.\n' "$REVIEWS"
  exit 2
fi
printf '\nAll checks passed.\n'
