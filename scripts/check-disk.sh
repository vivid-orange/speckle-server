#!/bin/bash
set -euo pipefail
# check-disk.sh - Alert when disk usage exceeds threshold
# Usage: Add to crontab to run hourly:
#   0 * * * * /home/speckle-user/git/speckle-server/scripts/check-disk.sh

THRESHOLD=80
COOLDOWN_SECONDS=21600  # 6 hours between alerts
RECIPIENT="t.reinhardt@whitbywood.com"
HOST_NAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# SMTP settings (read from .env)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "${DATE} - ERROR: .env file not found at ${ENV_FILE}"
  exit 1
fi

SMTP_HOST=$(grep '^EMAIL_HOST=' "$ENV_FILE" | cut -d'=' -f2- || true)
SMTP_PORT=$(grep '^EMAIL_PORT=' "$ENV_FILE" | cut -d'=' -f2- || true)
SMTP_USER=$(grep '^EMAIL_USERNAME=' "$ENV_FILE" | cut -d'=' -f2- || true)
SMTP_PASS=$(grep '^EMAIL_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2- || true)
SMTP_FROM=$(grep '^EMAIL_FROM=' "$ENV_FILE" | cut -d'=' -f2- || true)

if [ -z "$SMTP_HOST" ] || [ -z "$SMTP_PORT" ] || [ -z "$SMTP_USER" ] || [ -z "$SMTP_PASS" ] || [ -z "$SMTP_FROM" ]; then
  echo "${DATE} - ERROR: Missing SMTP configuration in ${ENV_FILE}"
  exit 1
fi

# Check root filesystem usage
USAGE=$(df / --output=pcent | tail -1 | tr -d ' %')

if [ "$USAGE" -ge "$THRESHOLD" ]; then
  # Cooldown: skip if an alert was sent recently
  LOCK_FILE="/tmp/check-disk-alert.lock"
  if [ -f "$LOCK_FILE" ]; then
    LAST_ALERT=$(stat -c %Y "$LOCK_FILE")
    NOW=$(date +%s)
    ELAPSED=$(( NOW - LAST_ALERT ))
    if [ "$ELAPSED" -lt "$COOLDOWN_SECONDS" ]; then
      echo "${DATE} - Disk at ${USAGE}% but alert already sent $((ELAPSED / 3600))h ago (cooldown: $((COOLDOWN_SECONDS / 3600))h)"
      exit 0
    fi
  fi

  DISK_REPORT=$(df -h)
  DOCKER_REPORT=$(docker system df 2>/dev/null || echo "Could not retrieve Docker disk usage")

  # Build email message
  MESSAGE="From: ${SMTP_FROM}
To: ${RECIPIENT}
Subject: Disk alert: ${HOST_NAME} at ${USAGE}%
Content-Type: text/plain; charset=UTF-8

Disk usage on ${HOST_NAME} has reached ${USAGE}% (threshold: ${THRESHOLD}%).
Checked at: ${DATE}

== Filesystem Usage ==
${DISK_REPORT}

== Docker Disk Usage ==
${DOCKER_REPORT}

--
Sent by check-disk.sh on ${HOST_NAME}"

  # Send via curl SMTP (use netrc file to avoid leaking credentials in process list)
  NETRC_FILE=$(mktemp)
  chmod 600 "$NETRC_FILE"
  printf 'machine %s login %s password %s\n' "$SMTP_HOST" "$SMTP_USER" "$SMTP_PASS" > "$NETRC_FILE"
  trap 'rm -f "$NETRC_FILE"' EXIT

  CURL_EXIT=0
  echo "$MESSAGE" | curl -s --url "smtp://${SMTP_HOST}:${SMTP_PORT}" \
    --ssl-reqd \
    --netrc-file "$NETRC_FILE" \
    --mail-from "${SMTP_FROM}" \
    --mail-rcpt "${RECIPIENT}" \
    --upload-file - || CURL_EXIT=$?

  rm -f "$NETRC_FILE"
  trap - EXIT

  if [ $CURL_EXIT -eq 0 ]; then
    touch "$LOCK_FILE"
    echo "${DATE} - Alert sent: disk at ${USAGE}%"
  else
    echo "${DATE} - ERROR: Failed to send disk alert email"
  fi
else
  echo "${DATE} - Disk usage at ${USAGE}% (below ${THRESHOLD}% threshold)"
fi
