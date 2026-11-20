#!/usr/bin/env bash
# Refresh APT's package lists with apt-get update --allow-releaseinfo-change.
# Installs and upgrades nothing.
set -Eeuo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: apt-update.sh

  Runs apt-get update --allow-releaseinfo-change: refreshes APT's package
  lists and accepts repositories whose release information (Suite,
  Codename, Origin, Label, ...) has changed, instead of refusing them.
  Installs and upgrades nothing. Requires root.

  --help  Show help

Exit codes: 0 = package lists updated; 1 = error.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
  esac
done

if (( EUID != 0 )); then
  printf 'Requires root. Run: sudo bash %s\n' "$0" >&2
  exit 1
fi
command -v apt-get >/dev/null || { printf 'apt-get not found\n' >&2; exit 1; }

code=0
apt-get update --allow-releaseinfo-change </dev/null || code=$?
if (( code != 0 )); then
  printf '\napt-get update failed (exit %d).\n' "$code" >&2
  exit 1
fi
printf '\nAPT package lists updated.\n'
