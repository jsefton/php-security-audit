#!/usr/bin/env bash
# Check whether the loaded nginx configuration enables HTTP/2.
# Read-only. Equivalent to: sudo nginx -T 2>&1 | grep -E 'listen.*http2|http2 on'
# with each match traced back to its file and line and classified.
set -Eeuo pipefail
export LC_ALL=C

usage() {
  cat <<'EOF'
Usage: nginx-http2.sh [--check]

  --check  Search the loaded nginx configuration (nginx -T) for HTTP/2:
           "listen ... http2" and "http2 on;" (default, no changes).
           Requires root.
  --help   Show help

Exit codes: 0 = HTTP/2 not enabled or nginx not installed; 2 = review required; 1 = error.
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

printf '\n========== NGINX HTTP/2 CHECK ==========\n'

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
#   on:      "listen ... http2" (any version) or "http2 on;" (nginx 1.25.1+)
#   off:     "http2 off;"
#   unclear: a bare http2 word in code, e.g. a listen split over several lines
#   comment: http2 only inside a comment, on a line the grep above matches
MATCHES=$(awk '
  { sub(/\r$/, "") }
  index($0, "# configuration file ") == 1 && /:$/ {
    file = substr($0, 22, length($0) - 22); fline = 0; next
  }
  { fline++ }
  {
    low = tolower($0); hash = index(low, "#")
    code = hash ? substr(low, 1, hash - 1) : low
    note = hash ? substr(low, hash + 1) : ""
    if (code ~ /(^|[ \t;{])listen[ \t][^;]*[ \t]http2([ \t;]|$)/ ||
        code ~ /(^|[ \t;{])http2[ \t]+on[ \t]*;/) state = "on"
    else if (code ~ /(^|[ \t;{])http2[ \t]+off[ \t]*;/) state = "off"
    else if (code ~ /(^|[ \t;{])http2([ \t;}]|$)/) state = "unclear"
    else if (note ~ /http2/ &&
             (low ~ /listen.*http2/ || note ~ /(^|[^a-z0-9_])http2[ \t]+o(n|ff)/)) state = "comment"
    else next
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
  printf '\nResult: HTTP/2 ENABLED in %d place(s).\n' "$ON_COUNT"
  if (( UNCLEAR_COUNT > 0 )); then
    printf '%d other match(es) could not be classified; check them manually.\n' "$UNCLEAR_COUNT"
  fi
  exit 2
elif (( UNCLEAR_COUNT > 0 )); then
  printf '\nResult: REVIEW REQUIRED. %d match(es) could not be classified; check them manually.\n' \
    "$UNCLEAR_COUNT"
  exit 2
elif (( TOTAL > 0 )); then
  printf '\nResult: HTTP/2 NOT ENABLED. It is off or commented out everywhere.\n'
else
  printf 'No HTTP/2 directives found (nginx default: off).\n'
  printf '\nResult: HTTP/2 NOT ENABLED.\n'
fi
