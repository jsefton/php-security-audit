#!/usr/bin/env bash
# Runs on each server. run-on-servers.sh and run-on-servers.ps1 send this file
# over SSH; it is not meant to be run by hand.
# Arguments: <archive URL> <install dir> <1 = update first, 0 = don't> [script [args...]]
set -euo pipefail
url=$1 dir=$2 update=$3
shift 3
case "$dir" in /*) ;; *) dir="$HOME/$dir" ;; esac
dir=${dir%/}
case "$dir" in
  ''|/|"$HOME") echo "Refusing to use install directory: '$dir'" >&2; exit 1 ;;
esac

if [ "$update" = 1 ]; then
  if [ -e "$dir" ] && [ ! -f "$dir/scripts/check-all.sh" ]; then
    echo "$dir exists but is not an install of these scripts; refusing to replace it." >&2
    exit 1
  fi
  if command -v curl >/dev/null 2>&1; then
    fetch=(curl -fsSL "$url")
  elif command -v wget >/dev/null 2>&1; then
    fetch=(wget -qO- "$url")
  else
    echo "curl or wget is required on the server." >&2
    exit 1
  fi
  new=$(mktemp -d "$dir.new.XXXXXX")
  if ! "${fetch[@]}" | tar -xz --strip-components=1 -C "$new" ||
     [ ! -f "$new/scripts/check-all.sh" ]; then
    rm -rf -- "$new"
    echo "Failed to download and unpack $url" >&2
    exit 1
  fi
  rm -rf -- "$dir"
  mv -- "$new" "$dir"
  echo "Scripts updated in $dir"
fi

[ "$#" -gt 0 ] || exit 0
script="$dir/scripts/$1"
shift
if [ ! -f "$script" ]; then
  echo "Script not found on the server: $script" >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  exec bash "$script" "$@"
fi
exec sudo bash "$script" "$@"
