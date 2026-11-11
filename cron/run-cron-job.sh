#!/usr/bin/env bash
# Call one cron endpoint of an app, then write a neat block to that app's log file.
#
# Usage:  run-cron-job.sh <app> <job-name> <endpoint> [quiet]
#   app        name of a block in apps.conf (gives the base URL, env file and log file)
#   job-name   label shown in the log, for example "update-ages"
#   endpoint   path to call, for example "/api/cron/update-ages"
#   quiet      optional. Write a log block only when the call fails.
#              Use it for jobs that run every few minutes, so the log stays short.
#
# The secret is read from the app's env file (variable CRON_SECRET) and sent as a Bearer token.
# It never appears on the command line, so it does not show up in `ps`.
set -u
umask 077

APP="${1:-}"; JOB_NAME="${2:-}"; ENDPOINT="${3:-}"; QUIET="${4:-}"
if [ -z "$APP" ] || [ -z "$JOB_NAME" ] || [ -z "$ENDPOINT" ]; then
  echo "usage: $0 <app> <job-name> <endpoint> [quiet]" >&2
  exit 2
fi

CONFIG="${CRON_APPS_CONF:-$(dirname "$0")/apps.conf}"
[ -r "$CONFIG" ] || { echo "cannot read $CONFIG" >&2; exit 2; }

# apps.conf lines:  app | base url | env file | log file
# (a line starting with # is a comment)
LINE=$(awk -F'|' -v app="$APP" '
  /^[[:space:]]*#/ { next }
  { k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k) }
  k == app { print; exit }' "$CONFIG")
[ -n "$LINE" ] || { echo "app '$APP' not found in $CONFIG" >&2; exit 2; }

trim() { echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }
BASE_URL=$(trim "$(echo "$LINE" | cut -d'|' -f2)")
ENV_FILE=$(trim "$(echo "$LINE" | cut -d'|' -f3)")
LOG_FILE=$(trim "$(echo "$LINE" | cut -d'|' -f4)")
mkdir -p "$(dirname "$LOG_FILE")"

# secret from the env file: take the value after the first "=", drop quotes and carriage returns
CRON_SECRET=$(grep -E '^CRON_SECRET=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "\"'\r")

UTC_TIME=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
LOCAL_TIME=$(TZ="${LOG_TZ:-Asia/Kolkata}" date "+%Y-%m-%d %H:%M:%S ${LOG_TZ_LABEL:-IST}")

RESPONSE_FILE=$(mktemp)
HEADER_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE" "$HEADER_FILE"' EXIT
printf 'Authorization: Bearer %s\n' "$CRON_SECRET" >"$HEADER_FILE"

START=$(date +%s%3N)
HTTP_CODE=$(curl -s \
  -o "$RESPONSE_FILE" \
  -w '%{http_code}' \
  -H "@$HEADER_FILE" \
  -H 'Content-Type: application/json' \
  --max-time "${CRON_TIMEOUT:-60}" \
  "${BASE_URL}${ENDPOINT}")
END=$(date +%s%3N)
DURATION=$((END - START))

OK=0
if [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 300 ]; then OK=1; fi

if [ "$QUIET" != "quiet" ] || [ "$OK" = "0" ]; then
  {
    echo "======================================================================"
    echo "UTC Time   : $UTC_TIME"
    echo "Local Time : $LOCAL_TIME"
    echo "Job        : $JOB_NAME"
    echo "Endpoint   : $ENDPOINT"
    echo "HTTP Code  : $HTTP_CODE"
    echo "Duration   : ${DURATION} ms"
    if [ "$OK" = "1" ]; then echo "Status     : SUCCESS ✅"; else echo "Status     : FAILED ❌"; fi
    echo
    echo "Response:"
    cat "$RESPONSE_FILE"
    echo
    echo "======================================================================"
    echo
  } >>"$LOG_FILE"
fi

[ "$OK" = "1" ]
