#!/bin/bash
set -euo pipefail
# backup.sh - Nightly backup of the Speckle Postgres database and MinIO blob storage
# Usage: Add to crontab to run nightly:
#   30 2 * * * /home/speckle-user/git/speckle-server/scripts/backup.sh >> /var/log/speckle-backup.log 2>&1
#
# Each run creates BACKUP_ROOT/<YYYY-MM-DD_HHMM>/ containing:
#   globals.sql.zst   roles/tablespaces (pg_dumpall --globals-only)
#   <db>.dump         pg_dump custom format, zstd-compressed (restore with pg_restore)
#   minio/            copy of the MinIO data volume; unchanged files are hard-linked to the
#                     previous snapshot, so each snapshot only costs the newly uploaded files
#
# If scripts/backup-offsite.sh exists and is executable, it is called with the snapshot path
# after a successful backup, to copy it off this server.

BACKUP_ROOT="${BACKUP_ROOT:-/home/speckle-user/backups}"
DATABASES="${DATABASES:-speckle}"
KEEP_DAILY="${KEEP_DAILY:-3}"    # most recent snapshots to keep
KEEP_WEEKLY="${KEEP_WEEKLY:-2}"  # most recent Sunday snapshots to keep, in addition
MINIO_VOLUME="${MINIO_VOLUME:-speckle-server_minio-data}"
RECIPIENT="t.reinhardt@whitbywood.com"
HOST_NAME=$(hostname)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_DIR}/.env"
COMPOSE=(docker compose -f "${REPO_DIR}/docker-compose-deps.yml")

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"; }

send_alert() {
  local subject="$1" body="$2"
  local smtp_host smtp_port smtp_user smtp_pass smtp_from
  smtp_host=$(grep '^EMAIL_HOST=' "$ENV_FILE" | cut -d'=' -f2- || true)
  smtp_port=$(grep '^EMAIL_PORT=' "$ENV_FILE" | cut -d'=' -f2- || true)
  smtp_user=$(grep '^EMAIL_USERNAME=' "$ENV_FILE" | cut -d'=' -f2- || true)
  smtp_pass=$(grep '^EMAIL_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2- || true)
  smtp_from=$(grep '^EMAIL_FROM=' "$ENV_FILE" | cut -d'=' -f2- || true)
  if [ -z "$smtp_host" ] || [ -z "$smtp_user" ] || [ -z "$smtp_pass" ] || [ -z "$smtp_from" ]; then
    log "ERROR: Missing SMTP configuration in ${ENV_FILE}, cannot send alert"
    return
  fi

  # netrc file keeps credentials out of the process list
  local netrc
  netrc=$(mktemp)
  chmod 600 "$netrc"
  printf 'machine %s login %s password %s\n' "$smtp_host" "$smtp_user" "$smtp_pass" > "$netrc"
  printf 'From: %s\nTo: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n\n--\nSent by backup.sh on %s\n' \
    "$smtp_from" "$RECIPIENT" "$subject" "$body" "$HOST_NAME" |
    curl -s --url "smtp://${smtp_host}:${smtp_port}" --ssl-reqd --login-options "AUTH=LOGIN" \
      --netrc-file "$netrc" --mail-from "$smtp_from" --mail-rcpt "$RECIPIENT" --upload-file - ||
    log "ERROR: Failed to send alert email"
  rm -f "$netrc"
}

WORK_DIR=""
on_error() {
  local exit_code=$? line=$1
  log "ERROR: backup failed at line ${line} (exit ${exit_code})"
  # Leave no half-written snapshot behind; it would be picked up as the next --link-dest
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    sudo rm -rf -- "$WORK_DIR"
  fi
  send_alert "Backup FAILED: ${HOST_NAME}" "The Speckle backup failed at line ${line} (exit ${exit_code}).
See /var/log/speckle-backup.log on ${HOST_NAME}.

Disk usage:
$(df -h /)"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# Only one backup at a time
exec 9> "${BACKUP_ROOT}.lock"
if ! flock -n 9; then
  log "Another backup is still running, skipping"
  exit 0
fi

mkdir -p "$BACKUP_ROOT"
STAMP=$(date '+%Y-%m-%d_%H%M')
SNAPSHOT="${BACKUP_ROOT}/${STAMP}"
WORK_DIR="${BACKUP_ROOT}/.inprogress-${STAMP}"
PREVIOUS=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)
mkdir -p "$WORK_DIR"
START=$(date +%s)
log "Starting backup into ${SNAPSHOT}"

# --- Postgres ---
"${COMPOSE[@]}" exec -T postgres sh -c 'pg_dumpall -U "$POSTGRES_USER" --globals-only' |
  zstd -q -3 > "${WORK_DIR}/globals.sql.zst"
for db in $DATABASES; do
  "${COMPOSE[@]}" exec -T -e DB="$db" postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$DB" -Fc -Z zstd:3' \
    > "${WORK_DIR}/${db}.dump"
  # Reads the whole archive's table of contents, so a truncated dump fails here
  "${COMPOSE[@]}" exec -T postgres pg_restore --list < "${WORK_DIR}/${db}.dump" > /dev/null
  log "Dumped database ${db} ($(du -h "${WORK_DIR}/${db}.dump" | cut -f1))"
done

# --- MinIO ---
MINIO_PATH=$(docker volume inspect -f '{{.Mountpoint}}' "$MINIO_VOLUME")
LINK_DEST=()
if [ -n "$PREVIOUS" ] && [ -d "${PREVIOUS}/minio" ]; then
  LINK_DEST=(--link-dest="${PREVIOUS}/minio")
fi
sudo rsync -a --delete "${LINK_DEST[@]}" "${MINIO_PATH}/" "${WORK_DIR}/minio/"
log "Copied MinIO volume ($(sudo du -sh "${WORK_DIR}/minio" | cut -f1) new/changed incl. links)"

mv "$WORK_DIR" "$SNAPSHOT"
WORK_DIR=""
log "Backup complete in $(( $(date +%s) - START ))s: $(sudo du -sh "$SNAPSHOT" | cut -f1)"

# --- Off-site copy (optional) ---
if [ -x "${SCRIPT_DIR}/backup-offsite.sh" ]; then
  "${SCRIPT_DIR}/backup-offsite.sh" "$SNAPSHOT"
  log "Off-site copy done"
fi

# --- Retention: newest KEEP_DAILY snapshots, plus the newest KEEP_WEEKLY Sunday ones ---
mapfile -t ALL < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r)
declare -A KEEP=()
for s in "${ALL[@]:0:$KEEP_DAILY}"; do KEEP["$s"]=1; done
weekly=0
for s in "${ALL[@]}"; do
  [ "$weekly" -ge "$KEEP_WEEKLY" ] && break
  day=$(basename "$s" | cut -d_ -f1)
  if [ "$(date -d "$day" +%u)" = "7" ]; then
    KEEP["$s"]=1
    weekly=$((weekly + 1))
  fi
done
for s in "${ALL[@]}"; do
  if [ -z "${KEEP[$s]:-}" ]; then
    sudo rm -rf -- "$s"
    log "Pruned old snapshot $(basename "$s")"
  fi
done

log "Retained $(( ${#ALL[@]} )) -> ${#KEEP[@]} snapshots; backups now use $(sudo du -sh "$BACKUP_ROOT" | cut -f1), disk at $(df / --output=pcent | tail -1 | tr -d ' ')"
