#!/usr/bin/env bash
# Run on your own machine (Linux, macOS or Git Bash), not on a server.
# On Windows, run-on-servers.cmd / run-on-servers.ps1 does the same from PowerShell.
# For each selected server in local/servers.txt: connect over SSH, install or
# update the scripts from GitHub (the README's Quick start), then run the chosen
# script there with sudo. Output is shown live and saved under local/logs/.
set -uo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR="$ROOT_DIR/lib"
LOCAL_DIR="$ROOT_DIR/local"
SERVERS_FILE="$LOCAL_DIR/servers.txt"
LOG_ROOT="$LOCAL_DIR/logs"

# Archive each server downloads the scripts from.
DEFAULT_ARCHIVE_URL=https://github.com/jsefton/php-security-audit/archive/refs/heads/main.tar.gz
ARCHIVE_URL=${ARCHIVE_URL:-$DEFAULT_ARCHIVE_URL}
# Install directory on each server. A relative path is under the SSH user's home.
INSTALL_DIR=${INSTALL_DIR:-php-security-audit}

usage() {
  cat <<'EOF'
Usage: run-on-servers.sh [options] [-- SCRIPT [ARGS...]]

Updates the scripts on each selected server from GitHub, then runs SCRIPT
there with sudo. With no options, asks which action and servers to use.
The action menu is lib/actions.txt.

  --servers LIST  Servers to use: "all", or numbers, ranges, names or hosts
                  separated by commas, e.g. "1,3-4,web-2". Skips that menu.
  --update-only   Install or update the scripts without running anything
  --no-update     Run without updating the scripts first
  --yes           Skip the "Continue?" confirmation
  --list          List the servers in local/servers.txt and exit
  --clear-logs    Delete the run logs in local/logs on this machine and exit
                  (no servers are contacted)
  --help          Show help

  -- SCRIPT ARGS  Script in scripts/ and its arguments. Skips the action
                  menu, e.g. -- php-upload-progress.sh --patch --yes

Exit codes: 0 = OK on every server; 2 = review required; 1 = error or SSH failure.
EOF
}

die() { printf '%s\n' "$*" >&2; exit 1; }

# Quote a value for a POSIX shell (the remote login shell).
sh_quote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Delete local run logs after confirming. Local only: no server is contacted.
clear_logs() {
  local -a runs=()
  if [[ -d "$LOG_ROOT" ]]; then
    shopt -s nullglob
    runs=("$LOG_ROOT"/*)
    shopt -u nullglob
  fi
  if ((${#runs[@]} == 0)); then
    printf 'No local logs to clear in %s\n' "$LOG_ROOT"
    return 0
  fi
  printf 'Local logs: %d run(s) in %s\n' "${#runs[@]}" "$LOG_ROOT"
  printf 'This deletes them from this machine only; servers are not touched.\n'
  if (( ! ASSUME_YES )); then
    read -r -p 'Delete them? [y/N] ' answer || exit 1
    case "$answer" in
      y|Y|yes|YES) ;;
      *) printf 'Cancelled.\n'; return 0 ;;
    esac
  fi
  rm -rf -- "${runs[@]}" || die "Could not delete everything in $LOG_ROOT"
  printf 'Deleted %d run(s) of logs.\n' "${#runs[@]}"
}

SERVERS_ARG=''
CLEAR_LOGS=0
UPDATE=1
UPDATE_ONLY=0
ASSUME_YES=0
LIST_ONLY=0
ACTION=()
while (( $# )); do
  case "$1" in
    --servers) (( $# >= 2 )) || die '--servers needs a value'; SERVERS_ARG=$2; shift 2 ;;
    --servers=*) SERVERS_ARG=${1#*=}; shift ;;
    --update-only) UPDATE_ONLY=1; shift ;;
    --no-update) UPDATE=0; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --list) LIST_ONLY=1; shift ;;
    --clear-logs) CLEAR_LOGS=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --) shift; ACTION=("$@"); break ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done
if (( UPDATE_ONLY && ! UPDATE )); then die '--update-only and --no-update cannot be combined'; fi
if (( UPDATE_ONLY && ${#ACTION[@]} )); then die '--update-only cannot be combined with a script'; fi
if (( CLEAR_LOGS )); then
  if [[ -n "$SERVERS_ARG" ]] || (( UPDATE_ONLY || ! UPDATE || LIST_ONLY || ${#ACTION[@]} )); then
    die '--clear-logs can only be combined with --yes'
  fi
  clear_logs
  exit 0
fi
command -v ssh >/dev/null || die 'ssh not found'
for f in remote-run.sh actions.txt servers.example.txt; do
  [[ -f "$LIB_DIR/$f" ]] || die "Missing $LIB_DIR/$f"
done

# Script sent to and run on each server.
REMOTE_SCRIPT=$(tr -d '\r' < "$LIB_DIR/remote-run.sh")

# Action menu: "<script and arguments> | <description>" per line.
ACTION_CMDS=()
ACTION_DESCS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line=${line%$'\r'}
  if [[ "$line" =~ ^[[:space:]]*(#|$) ]]; then continue; fi
  ACTION_CMDS+=("$(trim "${line%%|*}")")
  if [[ "$line" == *'|'* ]]; then
    ACTION_DESCS+=("$(trim "${line#*|}")")
  else
    ACTION_DESCS+=('')
  fi
done < "$LIB_DIR/actions.txt"

# ----- Server list -----

if [[ ! -f "$SERVERS_FILE" ]]; then
  mkdir -p "$LOCAL_DIR" && cp "$LIB_DIR/servers.example.txt" "$SERVERS_FILE" || exit 1
  printf 'Created %s\nAdd your servers to it, then run this again.\n' "$SERVERS_FILE"
  exit 1
fi

HOSTS=(); USERS=(); PORTS=(); NAMES=()
line_no=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_no=$((line_no + 1))
  line=${line%$'\r'}
  line=${line#$'\xEF\xBB\xBF'}
  line=${line%%#*}
  read -r host user third fourth extra <<<"$line"
  [[ -n "$host" ]] || continue
  bad="$SERVERS_FILE line $line_no: expected <host> <user> [port] [name]"
  [[ -n "$user" ]] || die "$bad"
  [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || die "$SERVERS_FILE line $line_no: invalid host '$host'"
  [[ "$user" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] || die "$SERVERS_FILE line $line_no: invalid user '$user'"
  port=22
  name=$host
  if [[ "$third" =~ ^[0-9]+$ ]]; then
    port=$third
    name=${fourth:-$host}
    [[ -z "$extra" ]] || die "$bad"
  elif [[ -n "$third" ]]; then
    name=$third
    [[ -z "$fourth$extra" ]] || die "$bad"
  fi
  HOSTS+=("$host"); USERS+=("$user"); PORTS+=("$port"); NAMES+=("$name")
done < "$SERVERS_FILE"
((${#HOSTS[@]})) || die "No servers in $SERVERS_FILE. Add one per line: <host> <user> [port] [name]"

print_servers() {
  local i suffix
  for i in "${!HOSTS[@]}"; do
    suffix=''
    if [[ "${PORTS[$i]}" != 22 ]]; then suffix=" port ${PORTS[$i]}"; fi
    printf '  %2d) %-20s %s@%s%s\n' $((i + 1)) "${NAMES[$i]}" "${USERS[$i]}" "${HOSTS[$i]}" "$suffix"
  done
}

if (( LIST_ONLY )); then
  printf 'Servers (%s):\n' "$SERVERS_FILE"
  print_servers
  exit 0
fi

# Parse "all", numbers, ranges, names or hosts into SELECTED (server indexes).
SELECTED=()
parse_selection() {
  local input=${1//,/ } token i a b found seen=' ' error='' count=${#HOSTS[@]}
  SELECTED=()
  set -f
  for token in $input; do
    found=()
    if [[ "$token" == all ]]; then
      found=("${!HOSTS[@]}")
    elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
      if (( a < 1 || b > count || a > b )); then error="Invalid range: $token"; break; fi
      for ((i = a - 1; i < b; i++)); do found+=("$i"); done
    elif [[ "$token" =~ ^[0-9]+$ ]]; then
      a=$((10#$token))
      if (( a < 1 || a > count )); then error="No server number $token"; break; fi
      found=($((a - 1)))
    else
      for i in "${!HOSTS[@]}"; do
        if [[ "${NAMES[$i]}" == "$token" || "${HOSTS[$i]}" == "$token" ]]; then found+=("$i"); fi
      done
      if ((${#found[@]} == 0)); then error="Unknown server: $token"; break; fi
    fi
    for i in "${found[@]}"; do
      if [[ "$seen" != *" $i "* ]]; then SELECTED+=("$i"); seen+="$i "; fi
    done
  done
  set +f
  if [[ -z "$error" ]] && ((${#SELECTED[@]} == 0)); then error='No servers selected'; fi
  if [[ -n "$error" ]]; then printf '%s\n' "$error" >&2; return 1; fi
}

# Files in scripts/ that differ from GitHub main (as of the last fetch or push).
unpushed_scripts() {
  command -v git >/dev/null || return 0
  git -C "$ROOT_DIR" rev-parse -q --verify origin/main >/dev/null 2>&1 || return 0
  {
    git -C "$ROOT_DIR" diff --name-only origin/main -- scripts
    git -C "$ROOT_DIR" ls-files --others --exclude-standard -- scripts
  } 2>/dev/null | sort -u
}

valid_script() {
  if [[ ! "$1" =~ ^[A-Za-z0-9._-]+\.sh$ || ! -f "$ROOT_DIR/scripts/$1" ]]; then
    printf 'Unknown script: %s (expected a file in scripts/)\n' "$1" >&2
    return 1
  fi
}

# ----- Choose action -----

if (( ! UPDATE_ONLY && ${#ACTION[@]} == 0 )); then
  count=${#ACTION_CMDS[@]}
  printf 'Actions:\n'
  for i in "${!ACTION_CMDS[@]}"; do
    printf '  %2d) %-36s %s\n' $((i + 1)) "${ACTION_CMDS[$i]}" "${ACTION_DESCS[$i]}"
  done
  printf '  %2d) %-36s %s\n' $((count + 1)) '(update scripts only)' 'Install or update the scripts; run nothing'
  printf '  %2d) %-36s %s\n' $((count + 2)) '(other)' 'Type a script and its arguments'
  printf '  %2d) %-36s %s\n' $((count + 3)) '(clear local logs)' 'Delete local/logs on this machine; no servers'
  while true; do
    read -r -p 'Choose an action [1]: ' choice || exit 1
    choice=${choice:-1}
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( 10#$choice < 1 || 10#$choice > count + 3 )); then
      printf 'Enter a number from 1 to %d.\n' $((count + 3)) >&2
      continue
    fi
    choice=$((10#$choice))
    if (( choice <= count )); then
      read -r -a ACTION <<<"${ACTION_CMDS[$((choice - 1))]}"
    elif (( choice == count + 1 )); then
      if (( ! UPDATE )); then die '--no-update cannot be combined with updating the scripts'; fi
      UPDATE_ONLY=1
    elif (( choice == count + 3 )); then
      clear_logs
      exit 0
    else
      read -r -p 'Script and arguments (e.g. php-upload-progress.sh --patch --yes): ' custom || exit 1
      read -r -a ACTION <<<"$custom"
      if ((${#ACTION[@]} == 0)) || ! valid_script "${ACTION[0]}"; then ACTION=(); continue; fi
    fi
    break
  done
elif (( ! UPDATE_ONLY )); then
  valid_script "${ACTION[0]}" || exit 1
fi

# ----- Choose servers -----

if [[ -n "$SERVERS_ARG" ]]; then
  parse_selection "$SERVERS_ARG" || exit 1
else
  printf '\nServers (%s):\n' "$SERVERS_FILE"
  print_servers
  while true; do
    read -r -p 'Select servers (e.g. 1 3, 2-4, web-1, all) [all]: ' answer || exit 1
    parse_selection "${answer:-all}" && break
  done
fi

# ----- Confirm -----

if (( UPDATE_ONLY )); then
  action_text='update scripts only'
else
  action_text="${ACTION[*]}"
fi
selected_names=()
for i in "${SELECTED[@]}"; do selected_names+=("${NAMES[$i]}"); done

printf '\nAction:  %s\n' "$action_text"
printf 'Servers: %s\n' "${selected_names[*]}"
if (( UPDATE )); then
  printf 'Scripts: updated from %s first\n' "$ARCHIVE_URL"
else
  printf 'Scripts: not updated (--no-update)\n'
fi
if [[ "$ARCHIVE_URL" == "$DEFAULT_ARCHIVE_URL" ]]; then
  unpushed=$(unpushed_scripts)
  if [[ -n "$unpushed" ]]; then
    printf '\nWARNING: these files differ from GitHub main, so the servers will run the\n'
    printf '         GitHub version, not yours. Commit and push them first:\n'
    while IFS= read -r f; do printf '           %s\n' "$f"; done <<<"$unpushed"
  fi
fi
if (( ! ASSUME_YES )); then
  read -r -p 'Continue? [y/N] ' answer || exit 1
  case "$answer" in
    y|Y|yes|YES) ;;
    *) printf 'Cancelled.\n'; exit 0 ;;
  esac
fi

# ----- Run -----

REMOTE_CMD="bash -c $(sh_quote "$REMOTE_SCRIPT") bash $(sh_quote "$ARCHIVE_URL") $(sh_quote "$INSTALL_DIR") $UPDATE"
if (( ! UPDATE_ONLY )); then
  for arg in "${ACTION[@]}"; do REMOTE_CMD+=" $(sh_quote "$arg")"; done
fi

# With a terminal, allocate one on the server so sudo and the scripts can prompt.
if [[ -t 0 ]]; then SSH_TTY_OPTS=(-t); else SSH_TTY_OPTS=(-T -n); fi

LOG_DIR="$LOG_ROOT/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR" || exit 1

RESULTS=()
ERRORS=0
REVIEWS=0
for i in "${SELECTED[@]}"; do
  label="${NAMES[$i]} (${USERS[$i]}@${HOSTS[$i]})"
  log="$LOG_DIR/$(printf '%02d' $((i + 1)))-$(safe_name "${NAMES[$i]}").log"
  printf '\n################ %s ################\n' "$label"

  ssh "${SSH_TTY_OPTS[@]}" -o ConnectTimeout=15 -p "${PORTS[$i]}" -l "${USERS[$i]}" \
    -- "${HOSTS[$i]}" "$REMOTE_CMD" 2>&1 | tee "$log.part"
  code=${PIPESTATUS[0]}
  tr -d '\r' < "$log.part" > "$log" && rm -f -- "$log.part"

  case "$code" in
    0) if (( UPDATE_ONLY )); then result=UPDATED; else result=OK; fi ;;
    2) result='REVIEW REQUIRED'; REVIEWS=$((REVIEWS + 1)) ;;
    255) result='SSH FAILED'; ERRORS=$((ERRORS + 1)) ;;
    *) result="ERROR (exit $code)"; ERRORS=$((ERRORS + 1)) ;;
  esac
  RESULTS+=("$(printf '%-17s %s' "$result" "$label")")
done

printf '\n========== SUMMARY: %s ==========\n' "$action_text"
printf '%s\n' "${RESULTS[@]}"
printf '\nLogs: %s\n' "$LOG_DIR"

if (( ERRORS > 0 )); then exit 1; fi
if (( REVIEWS > 0 )); then exit 2; fi
exit 0
