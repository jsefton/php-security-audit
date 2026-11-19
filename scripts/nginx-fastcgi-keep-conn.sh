#!/usr/bin/env bash
# Check the loaded nginx configuration for fastcgi_keep_conn.
# Read-only. Equivalent to: sudo nginx -T 2>/dev/null | grep -n 'fastcgi_keep_conn'
# with each match traced back to its file and line and classified.
set -Eeuo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: nginx-fastcgi-keep-conn.sh [--check]

  --check  Search the loaded nginx configuration (nginx -T) for
           fastcgi_keep_conn (default, no changes). Requires root.
  --help   Show help

Exit codes: 0 = not impacted or nginx not installed; 2 = review required; 1 = error.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --check) ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 1 ;;
  esac
done
for cmd in awk mktemp; do
  command -v "$cmd" >/dev/null || { printf 'Missing command: %s\n' "$cmd" >&2; exit 1; }
done

printf '\n========== NGINX fastcgi_keep_conn CHECK ==========\n'

# /usr/sbin is not always on a non-root PATH.
NGINX=$(command -v nginx || true)
if [[ -z "$NGINX" && -x /usr/sbin/nginx ]]; then
  NGINX=/usr/sbin/nginx
fi
if [[ -z "$NGINX" ]]; then
  printf 'nginx not found: not applicable.\n'
  exit 0
fi
if (( EUID != 0 )); then
  printf 'This check needs root to read the full nginx configuration.\n' >&2
  printf 'Run: sudo bash %s\n' "$0" >&2
  exit 1
fi

ERR_FILE=$(mktemp)
trap 'rm -f -- "$ERR_FILE"' EXIT
if ! DUMP=$("$NGINX" -T 2>"$ERR_FILE"); then
  printf 'nginx -T failed, so the configuration could not be checked:\n' >&2
  sed 's/^/  /' "$ERR_FILE" >&2
  exit 1
fi

# nginx -T prints "# configuration file <path>:" before each file's contents.
# Output per match: state, dump line, file, file line, text.
MATCHES=$(awk '
  { sub(/\r$/, "") }
  index($0, "# configuration file ") == 1 && /:$/ {
    file = substr($0, 22, length($0) - 22); fline = 0; next
  }
  { fline++ }
  /fastcgi_keep_conn/ {
    code = $0; sub(/#.*/, "", code); code = tolower(code)
    if (code ~ /(^|[ \t;{])fastcgi_keep_conn[ \t]+on[ \t]*;/) state = "on"
    else if (code ~ /(^|[ \t;{])fastcgi_keep_conn[ \t]+off[ \t]*;/) state = "off"
    else if (code !~ /fastcgi_keep_conn/) state = "comment"
    else state = "unclear"
    text = $0; sub(/^[ \t]+/, "", text)
    printf "%s\t%d\t%s\t%d\t%s\n", state, NR, file, fline, text
  }
' <<<"$DUMP")

ON_COUNT=0
UNCLEAR_COUNT=0
TOTAL=0
if [[ -n "$MATCHES" ]]; then
  printf 'Matches in nginx -T output (dump line | file:line: text):\n'
  while IFS=$'\t' read -r state dump_line file file_line text; do
    TOTAL=$((TOTAL + 1))
    case "$state" in
      on) label=ON; ON_COUNT=$((ON_COUNT + 1)) ;;
      off) label=off ;;
      comment) label=comment ;;
      *) label=UNCLEAR; UNCLEAR_COUNT=$((UNCLEAR_COUNT + 1)) ;;
    esac
    printf '  %-9s %6s | %s:%s: %s\n' "[$label]" "$dump_line" "$file" "$file_line" "$text"
  done <<<"$MATCHES"
fi

if (( ON_COUNT > 0 )); then
  printf '\nResult: IMPACTED. fastcgi_keep_conn is on in %d place(s).\n' "$ON_COUNT"
  exit 2
elif (( UNCLEAR_COUNT > 0 )); then
  printf '\nResult: REVIEW REQUIRED. %d match(es) could not be classified; check them manually.\n' \
    "$UNCLEAR_COUNT"
  exit 2
elif (( TOTAL > 0 )); then
  printf '\nResult: NOT IMPACTED. fastcgi_keep_conn is off or commented out everywhere.\n'
else
  printf 'No fastcgi_keep_conn directives found (nginx default: off).\n'
  printf '\nResult: NOT IMPACTED.\n'
fi
