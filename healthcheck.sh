
#!/usr/bin/env bash
# Checks the last 24h of ETL logs, disk usage and systemd service state.
set -Eeuo pipefail

LOG_FILE="/var/log/etl/pipeline.log"
SERVICE="etl-pipeline.service"
ENV_FILE="/etc/etl/telegram.env"
DISK_PATH="/var/log/etl"
DISK_WARN_PERCENT=85
LOOKBACK_SECONDS=$((24 * 60 * 60))

issues=()
evidence=""
now_epoch="$(date -u +%s)"
since_epoch="$((now_epoch - LOOKBACK_SECONDS))"

if [[ ! -r "$LOG_FILE" ]]; then
  issues+=("LOG: log file is missing or unreadable: $LOG_FILE")
else
  recent_hits="$(
    grep -E 'ERROR|Traceback|0 rows loaded' "$LOG_FILE" 2>/dev/null |
    awk -v since="$since_epoch" '
      {
        ts = substr($0, 1, 20)
        cmd = "date -u -d \"" ts "\" +%s 2>/dev/null"
        cmd | getline epoch
        close(cmd)
        if (epoch != "" && epoch >= since) print
      }'
  )" || true

  if [[ -n "$recent_hits" ]]; then
    issues+=("LOG: critical signal found in the last 24 hours")
    evidence+=$'\n'"Matching log lines:"$'\n'"$recent_hits"$'\n'
  fi
fi

if df_output="$(df -P "$DISK_PATH" 2>/dev/null)"; then
  used_percent="$(awk 'NR==2 {gsub(/%/, "", $5); print $5}' <<< "$df_output")"
  if [[ -n "$used_percent" ]] && (( used_percent > DISK_WARN_PERCENT )); then
    issues+=("DISK: ${DISK_PATH} filesystem is ${used_percent}% used (warning threshold: >${DISK_WARN_PERCENT}%)")
    evidence+=$'\n'"df -h output:"$'\n'"$(df -h "$DISK_PATH")"$'\n'
  fi
else
  issues+=("DISK: cannot inspect filesystem for ${DISK_PATH}")
fi


if ! systemctl cat "$SERVICE" >/dev/null 2>&1; then
  echo "INFO: ${SERVICE} is not installed yet; skipping systemd check"
else
  service_result="$(systemctl show "$SERVICE" -p Result --value)"
  service_status="$(systemctl show "$SERVICE" -p ExecMainStatus --value)"

  service_logs="$(journalctl -u "$SERVICE" --since "24 hours ago" --no-pager -o cat 2>/dev/null || true)"

  if [[ -z "$service_logs" ]] || ! grep -Eq "Starting ${SERVICE}([[:space:]]|$)" <<< "$service_logs"; then
    issues+=("SYSTEMD: ${SERVICE} has no execution within the last 24 hours")
  fi

  if [[ "$service_result" != "success" || "$service_status" != "0" ]]; then
    issues+=("SYSTEMD: ${SERVICE} result=${service_result}, exit_status=${service_status}")
    evidence+=$'\n'"systemctl journal:"$'\n'"$(tail -n 15 <<< "$service_logs")"$'\n'
  fi
fi


if ((${#issues[@]} == 0)); then
  echo "OK: no critical log signals in 24h, disk usage <= ${DISK_WARN_PERCENT}%, latest ${SERVICE} run succeeded"
  exit 0
fi

root_cause="Operational issue detected; inspect the evidence below."
joined_issues="$(printf '%s\n' "${issues[@]}")"

if grep -qiE 'database connection failed|could not connect|Traceback' <<< "$evidence"; then
  root_cause="Likely ETL runtime failure: database connection error/exception. Check DB reachability, credentials, DNS and network timeouts."
elif grep -qi '0 rows loaded' <<< "$evidence"; then
  root_cause="Likely silent data-quality/source issue: ETL completed but loaded zero rows. Check source filters, upstream arrival and extraction window."
elif grep -qi 'DISK:' <<< "$joined_issues"; then
  root_cause="Disk capacity threshold exceeded or filesystem check failed. Find large files, inspect log growth and verify retention."
elif grep -qi 'SYSTEMD:' <<< "$joined_issues"; then
  root_cause="systemd ETL execution is missing, stale or failed. Inspect journalctl for the unit and the latest ETL log."
fi

last_logs="(log file unavailable)"
if [[ -r "$LOG_FILE" ]]; then
  last_logs="$(tail -n 10 "$LOG_FILE")"
fi

message=$'🚨 ETL PIPELINE ALERT\n'
message+=$'\n'"Time (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"$'\n'
message+=$'\n'"Detected issues:"$'\n'"${joined_issues}"$'\n'
message+=$'\n'"Likely root cause:"$'\n'"${root_cause}"$'\n'
message+=$'\n'"Evidence:"$'\n'"${evidence}"$'\n'
message+=$'\n'"Last 10 log lines:"$'\n'"${last_logs}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "ERROR: Telegram config not found: $ENV_FILE" >&2
  printf '%s\n' "$message"
  exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is not set}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is not set}"

curl --fail --silent --show-error --max-time 20 \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${message}" \
  --data-urlencode "disable_web_page_preview=true" >/dev/null

echo "ALERT: sent to Telegram"

