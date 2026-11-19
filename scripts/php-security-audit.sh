#!/usr/bin/env bash
# Audit APT-managed PHP versions and optionally upgrade installed PHP packages.
# Ubuntu/Debian. No changes are made unless --upgrade is supplied.
set -Eeuo pipefail
export LC_ALL=C

# ===== CONFIGURATION: minimum fixed UPSTREAM versions (19 Nov 2026) =====
declare -A FIXED_UPSTREAM=(
  [8.2]="8.2.36"
  [8.3]="8.3.37"
  [8.4]="8.4.28"
  [8.5]="8.5.13"
  [8.6]="8.6.0"
)

# Optional: VERIFIED vendor-backported minimum APT package versions.
# Set ONLY after checking the OS/vendor security advisory for THIS issue.
# Example format: [8.3]="8.3.6-0ubuntu0.24.04.N" (replace N with verified value)
# These values are FULL dpkg package versions, NOT the output of `php -v`.
declare -A FIXED_VENDOR_PACKAGE=(
  # [8.3]="8.3.6-0ubuntu0.24.04.N"
)
# ========================================================================

usage() {
  cat <<'EOF'
Usage: php-security-audit.sh [--check | --upgrade] [--yes]

  --check    Audit installed APT PHP versions (default, no changes)
  --upgrade  Refresh APT, audit, preview, and upgrade installed PHP packages
  --yes      Skip the script's confirmation prompt (requires --upgrade)
  --help     Show help

Exit codes: 0 = all audited branches patched; 2 = review required; 1 = error.
EOF
}

MODE=check
YES=0
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    --upgrade) MODE=upgrade ;;
    --yes) YES=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
  esac
done
if (( YES )) && [[ "$MODE" != upgrade ]]; then
  printf '%s\n' '--yes is valid only with --upgrade' >&2
  exit 1
fi
for cmd in dpkg-query dpkg apt-cache awk sort; do
  command -v "$cmd" >/dev/null || { printf 'Missing command: %s\n' "$cmd" >&2; exit 1; }
done

# Indexed arrays for one upgrade transaction; associative arrays for branches.
declare -a PHP_PACKAGES=()
declare -A BRANCH_PACKAGE=()
declare -A BRANCH_VERSION=()
declare -a BRANCHES=()
REVIEW_COUNT=0

scan_installed() {
  PHP_PACKAGES=()
  BRANCH_PACKAGE=()
  BRANCH_VERSION=()
  BRANCHES=()

  local pkg version state branch
  while IFS=$'\t' read -r pkg version state; do
    [[ -n "$pkg" && ${state:1:1} == i ]] || continue

    # Keep the runtime, extensions, PHP meta packages, Apache and embed modules.
    if [[ "$pkg" =~ ^php[0-9]+\.[0-9]+($|-) ||
          "$pkg" =~ ^php- || "$pkg" == php-common ||
          "$pkg" =~ ^libapache2-mod-php[0-9]+\.[0-9]+$ ||
          "$pkg" =~ ^libphp[0-9]+\.[0-9]+-embed$ ]]; then
      PHP_PACKAGES+=("$pkg")
    else
      continue
    fi

    branch=''
    if [[ "$pkg" =~ ^php([0-9]+\.[0-9]+)($|-) ]]; then
      branch=${BASH_REMATCH[1]}
    elif [[ "$pkg" =~ ^libapache2-mod-php([0-9]+\.[0-9]+)$ ]]; then
      branch=${BASH_REMATCH[1]}
    elif [[ "$pkg" =~ ^libphp([0-9]+\.[0-9]+)-embed$ ]]; then
      branch=${BASH_REMATCH[1]}
    fi

    if [[ -n "$branch" ]]; then
      # Prefer the common runtime package to represent the branch.
      if [[ -z "${BRANCH_PACKAGE[$branch]:-}" || "$pkg" == "php${branch}-common" ]]; then
        BRANCH_PACKAGE[$branch]=$pkg
        BRANCH_VERSION[$branch]=$version
      fi
    fi
  done < <(dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Abbrev}\n' \
      'php*' 'libapache2-mod-php*' 'libphp*-embed' 2>/dev/null || true)

  if ((${#BRANCH_PACKAGE[@]})); then
    mapfile -t BRANCHES < <(printf '%s\n' "${!BRANCH_PACKAGE[@]}" | sort -V)
  fi
}

# Strip Debian epoch and revision; retain upstream pre-release suffixes.
upstream_version() {
  local value=${1#*:}
  printf '%s' "${value%%-*}"
}

classify() {
  local branch=$1 package_version=$2 upstream fixed vendor
  upstream=$(upstream_version "$package_version")
  fixed=${FIXED_UPSTREAM[$branch]:-}
  vendor=${FIXED_VENDOR_PACKAGE[$branch]:-}

  if [[ -n "$fixed" ]] && dpkg --compare-versions "$upstream" ge "$fixed"; then
    printf 'PATCHED (upstream)'
  elif [[ -n "$vendor" ]] && dpkg --compare-versions "$package_version" ge "$vendor"; then
    if [[ -z "$fixed" ]]; then
      printf 'BACKPORT VERIFIED (EOL branch)'
    else
      printf 'PATCHED (vendor backport)'
    fi
  elif [[ -z "$fixed" ]]; then
    printf 'EOL / FIX STATUS UNKNOWN'
  else
    printf 'POTENTIALLY IMPACTED'
  fi
}

apt_candidate() {
  local candidate
  candidate=$(apt-cache policy "$1" | awk '$1 == "Candidate:" {print $2; exit}')
  if [[ -z "$candidate" || "$candidate" == '(none)' ]]; then
    printf 'unavailable'
  else
    printf '%s' "$candidate"
  fi
}

report() {
  local title=$1 branch pkg current fixed status candidate candidate_status available
  REVIEW_COUNT=0
  printf '\n========== %s ==========\n' "$title"
  printf 'Installed APT-managed PHP packages: %d\n' "${#PHP_PACKAGES[@]}"

  if ((${#BRANCHES[@]} == 0)); then
    printf 'No APT-managed versioned PHP runtime packages found.\n'
    printf 'This does NOT check Docker, custom binaries or other runtimes.\n'
    REVIEW_COUNT=1
    return 0
  fi

  for branch in "${BRANCHES[@]}"; do
    pkg=${BRANCH_PACKAGE[$branch]}
    current=${BRANCH_VERSION[$branch]}
    fixed=${FIXED_UPSTREAM[$branch]:-'not supported upstream'}
    status=$(classify "$branch" "$current")
    candidate=$(apt_candidate "$pkg")

    if [[ "$candidate" == unavailable ]]; then
      available='No APT candidate'
    elif dpkg --compare-versions "$candidate" gt "$current"; then
      candidate_status=$(classify "$branch" "$candidate")
      if [[ "$candidate_status" == PATCHED* ]]; then
        available='FIX AVAILABLE in configured APT repositories'
      else
        available='Update available; security fix NOT verified'
      fi
    else
      available='No newer version in configured APT repositories'
    fi

    printf '\nPHP %-6s | %-27s | %s\n' "$branch" "$status" "$available"
    printf '  Representative package: %s\n' "$pkg"
    printf '  Installed APT version:  %s\n' "$current"
    printf '  Fixed upstream version: %s\n' "$fixed"
    printf '  APT candidate:          %s\n' "$candidate"

    if [[ "$status" != PATCHED* ]]; then
      REVIEW_COUNT=$((REVIEW_COUNT + 1))
    fi
  done
  printf '\nSummary: %d branch(es) require review.\n' "$REVIEW_COUNT"
  printf 'NOTE: Ubuntu/Debian vendor backports may retain an older PHP version.\n'
  printf '      Configure FIXED_VENDOR_PACKAGE only with verified security-advisory values.\n'
}

if [[ "$MODE" == upgrade ]]; then
  if (( EUID != 0 )); then
    printf 'Upgrade mode requires root. Run: sudo bash %s --upgrade\n' "$0" >&2
    exit 1
  fi
  command -v apt-get >/dev/null || { printf 'apt-get not found\n' >&2; exit 1; }

  printf 'Refreshing APT metadata...\n'
  apt-get update
  scan_installed
  report 'BEFORE UPGRADE'
  if ((${#PHP_PACKAGES[@]} == 0)); then
    printf '\nNothing to upgrade.\n'
    exit 2
  fi

  printf '\n========== APT UPGRADE PREVIEW ==========\n'
  apt-get -s install --only-upgrade "${PHP_PACKAGES[@]}"

  if (( ! YES )); then
    printf '\nApply the PHP package upgrades shown above? [y/N] '
    read -r answer || exit 1
    case "$answer" in
      y|Y|yes|YES) ;;
      *) printf 'Cancelled. No upgrades applied.\n'; exit 0 ;;
    esac
  fi

  # Upgrade only already-installed PHP packages. APT may update dependencies.
  apt-get -y install --only-upgrade "${PHP_PACKAGES[@]}"
  scan_installed
  report 'AFTER UPGRADE'
  printf '\nCheck PHP-FPM service health and application smoke tests.\n'
else
  scan_installed
  report 'PHP SECURITY AUDIT'
fi

if (( REVIEW_COUNT > 0 )); then
  exit 2
fi
