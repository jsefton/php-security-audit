#!/usr/bin/env bash
# Report whether this server needs a reboot and, with --reboot, reboot it.
# No changes are made unless --reboot is supplied.
set -Eeuo pipefail
export LC_ALL=C

# Ubuntu creates this file (and <file>.pkgs) when an update needs a reboot.
REBOOT_REQUIRED_FILE=${REBOOT_REQUIRED_FILE:-/var/run/reboot-required}
# Installed kernel images are /boot/vmlinuz-<release>.
BOOT_DIR=${BOOT_DIR:-/boot}

usage() {
  cat <<'EOF'
Usage: reboot.sh [--check | --reboot] [--yes] [--if-required] [--delay MINUTES]

  --check          Report whether a reboot is required (default, no changes)
  --reboot         Reboot this server, after showing the check and confirming
  --yes            Skip the confirmation prompt (requires --reboot)
  --if-required    Reboot only if a reboot is required (requires --reboot)
  --delay MINUTES  Minutes to wait before rebooting, 0 to 9999 (default: 1;
                   requires --reboot). The delay lets an SSH session end
                   cleanly; 0 reboots at once and may drop the connection.
  --help           Show help

Cancel a scheduled reboot with: sudo shutdown -c

Exit codes: 0 = no reboot required, or reboot scheduled; 2 = reboot required;
1 = error.
EOF
}

MODE=check
YES=0
IF_REQUIRED=0
DELAY=1
DELAY_SET=0
while (( $# )); do
  case "$1" in
    --check) MODE=check ;;
    --reboot) MODE=reboot ;;
    --yes) YES=1 ;;
    --if-required) IF_REQUIRED=1 ;;
    --delay)
      if (( $# < 2 )); then printf '%s\n' '--delay needs a number of minutes' >&2; exit 1; fi
      DELAY=$2; DELAY_SET=1; shift ;;
    --delay=*) DELAY=${1#*=}; DELAY_SET=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done
if [[ "$MODE" != reboot ]] && (( YES || IF_REQUIRED || DELAY_SET )); then
  printf '%s\n' '--yes, --if-required and --delay are valid only with --reboot' >&2
  exit 1
fi
if [[ ! "$DELAY" =~ ^[0-9]{1,4}$ ]]; then
  printf 'Invalid --delay: %s (expected 0 to 9999 minutes)\n' "$DELAY" >&2
  exit 1
fi
DELAY=$((10#$DELAY))

if [[ "$MODE" == reboot ]]; then
  if (( EUID != 0 )); then
    printf 'Reboot mode requires root. Run: sudo bash %s --reboot\n' "$0" >&2
    exit 1
  fi
  # systemd's shutdown schedules the reboot and returns at once.
  if [[ ! -d /run/systemd/system ]]; then
    printf 'Reboot mode requires systemd, which is not running here.\n' >&2
    exit 1
  fi
  command -v shutdown >/dev/null || { printf 'Missing command: shutdown\n' >&2; exit 1; }
fi
for cmd in sort tail uname; do
  command -v "$cmd" >/dev/null || { printf 'Missing command: %s\n' "$cmd" >&2; exit 1; }
done

# Kernel flavour: "generic" in 6.8.0-48-generic, "amd64" in 6.1.0-26-amd64.
kernel_flavour() {
  if [[ "$1" =~ ^[0-9][0-9.]*-[0-9][0-9.]*-(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Newest kernel in BOOT_DIR with the same flavour as the given release.
newest_kernel() {
  local flavour image name
  local -a names=()
  flavour=$(kernel_flavour "$1")
  [[ -n "$flavour" ]] || return 0
  shopt -s nullglob
  for image in "$BOOT_DIR"/vmlinuz-*; do
    name=${image##*/vmlinuz-}
    if [[ "$(kernel_flavour "$name")" == "$flavour" ]]; then names+=("$name"); fi
  done
  shopt -u nullglob
  ((${#names[@]})) || return 0
  printf '%s\n' "${names[@]}" | sort -V | tail -n 1
}

HOST=${HOSTNAME:-unknown}
RUNNING=$(uname -r)
NEWEST=$(newest_kernel "$RUNNING")
declare -a REASONS=()

if [[ -e "$REBOOT_REQUIRED_FILE" ]]; then
  pkgs=$(sort -u -- "$REBOOT_REQUIRED_FILE.pkgs" 2>/dev/null | tr '\n' ' ' || true)
  REASONS+=("$REBOOT_REQUIRED_FILE exists${pkgs:+ (packages: ${pkgs% })}")
fi
if [[ -n "$NEWEST" && "$NEWEST" != "$RUNNING" &&
      "$(printf '%s\n%s\n' "$RUNNING" "$NEWEST" | sort -V | tail -n 1)" == "$NEWEST" ]]; then
  REASONS+=("a newer kernel is installed: $NEWEST (running $RUNNING)")
fi
if ((${#REASONS[@]})); then RESULT_CODE=2; else RESULT_CODE=0; fi

since=$(uptime -s 2>/dev/null || true)
pretty=$(uptime -p 2>/dev/null || true)
printf '========== REBOOT CHECK ==========\n'
printf 'Host:            %s\n' "$HOST"
printf 'Booted:          %s%s\n' "${since:-unknown}" "${pretty:+ ($pretty)}"
printf 'Running kernel:  %s\n' "$RUNNING"
printf 'Newest kernel:   %s\n' "${NEWEST:-unknown (none of the same flavour in $BOOT_DIR)}"
if (( RESULT_CODE == 2 )); then
  printf '\nResult: REBOOT REQUIRED.\n'
  printf '  - %s\n' "${REASONS[@]}"
else
  printf '\nResult: NO REBOOT REQUIRED.\n'
fi

if [[ "$MODE" == check ]]; then
  exit "$RESULT_CODE"
fi

if (( IF_REQUIRED && RESULT_CODE == 0 )); then
  printf '\nNot rebooting: no reboot is required (--if-required).\n'
  exit 0
fi

sessions=$(who 2>/dev/null || true)
printf '\nLogged-in sessions (the reboot disconnects them):\n'
if [[ -n "$sessions" ]]; then
  while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$sessions"
else
  printf '  (none)\n'
fi

if (( DELAY == 0 )); then plan=now; else plan="in $DELAY minute(s)"; fi
if (( ! YES )); then
  printf '\nReboot %s %s? [y/N] ' "$HOST" "$plan"
  read -r answer || exit 1
  case "$answer" in
    y|Y|yes|YES) ;;
    *) printf 'Cancelled. No reboot scheduled.\n'; exit "$RESULT_CODE" ;;
  esac
fi

if (( DELAY == 0 )); then when=now; else when="+$DELAY"; fi
if ! shutdown -r "$when" "Reboot requested by ${SUDO_USER:-$(id -un)} with reboot.sh"; then
  printf 'shutdown failed; no reboot scheduled.\n' >&2
  exit 1
fi
if (( DELAY == 0 )); then
  printf '\nRebooting %s now.\n' "$HOST"
else
  printf '\nReboot of %s scheduled %s. To cancel: sudo shutdown -c\n' "$HOST" "$plan"
fi
