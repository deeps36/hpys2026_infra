#!/usr/bin/env bash
# =============================================================================
# HPYS backup — MySQL logical dump + uploads archive, 30-day retention
# Usage: ./backup.sh
# Cron: 15 2 * * * /opt/hpys/backup.sh >> /opt/hpys/data/logs/backup.log 2>&1
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

BACKUP_DIR="${ROOT_DIR}/data/backups"
UPLOADS_DIR="${ROOT_DIR}/data/uploads"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
STAMP="$(date -u '+%Y%m%d_%H%M%S')"
CONTAINER="${MYSQL_CONTAINER:-hpys-mysql}"
TMP_DIR="$(mktemp -d /tmp/hpys-backup.XXXXXX)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

read_env() {
  local key="$1"
  local val=""
  val="$(grep -E "^${key}=" .env | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  val="${val%\"}"
  val="${val#\"}"
  val="${val%\'}"
  val="${val#\'}"
  printf '%s' "${val}"
}

mkdir -p "${BACKUP_DIR}"

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found"
  exit 1
fi

MYSQL_ROOT_PASSWORD="$(read_env MYSQL_ROOT_PASSWORD)"
DB_DATABASE="$(read_env DB_DATABASE)"
DB_DATABASE="${DB_DATABASE:-hpys_db}"

REELS_METADATA_DB_NAME="$(read_env REELS_METADATA_DB_NAME)"
REELS_METADATA_DB_NAME="${REELS_METADATA_DB_NAME:-hpys_reels_metadata}"
PROFILE_DB_NAME="$(read_env PROFILE_DB_NAME)"
PROFILE_DB_NAME="${PROFILE_DB_NAME:-hpys_profile_img}"

REELS_DB_1_NAME="$(read_env REELS_DB_1_NAME)"; REELS_DB_1_NAME="${REELS_DB_1_NAME:-hpys_reels_db_1}"
REELS_DB_2_NAME="$(read_env REELS_DB_2_NAME)"; REELS_DB_2_NAME="${REELS_DB_2_NAME:-hpys_reels_db_2}"
REELS_DB_3_NAME="$(read_env REELS_DB_3_NAME)"; REELS_DB_3_NAME="${REELS_DB_3_NAME:-hpys_reels_db_3}"
REELS_DB_4_NAME="$(read_env REELS_DB_4_NAME)"; REELS_DB_4_NAME="${REELS_DB_4_NAME:-hpys_reels_db_4}"
REELS_DB_5_NAME="$(read_env REELS_DB_5_NAME)"; REELS_DB_5_NAME="${REELS_DB_5_NAME:-hpys_reels_db_5}"
REELS_DB_6_NAME="$(read_env REELS_DB_6_NAME)"; REELS_DB_6_NAME="${REELS_DB_6_NAME:-hpys_reels_db_6}"

if [[ -z "${MYSQL_ROOT_PASSWORD}" ]]; then
  echo "ERROR: MYSQL_ROOT_PASSWORD missing in .env"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo "ERROR: MySQL container '${CONTAINER}' is not running"
  exit 1
fi

OUT_SQL="${TMP_DIR}/hpys_all_${STAMP}.sql"
OUT_GZ="${BACKUP_DIR}/hpys_all_${STAMP}.sql.gz"
OUT_UPLOADS="${BACKUP_DIR}/hpys_uploads_${STAMP}.tar.gz"

echo "==> Starting backup at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "==> Dumping databases from ${CONTAINER}"

# Dump to temp on host via stdout; fail closed if mysqldump errors
docker exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" "${CONTAINER}" \
  mysqldump \
    -uroot \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --hex-blob \
    --max-allowed-packet=512M \
    --set-gtid-purged=OFF \
    --databases \
      "${DB_DATABASE}" \
      "${REELS_METADATA_DB_NAME}" \
      "${REELS_DB_1_NAME}" \
      "${REELS_DB_2_NAME}" \
      "${REELS_DB_3_NAME}" \
      "${REELS_DB_4_NAME}" \
      "${REELS_DB_5_NAME}" \
      "${REELS_DB_6_NAME}" \
      "${PROFILE_DB_NAME}" \
  > "${OUT_SQL}"

# Integrity checks before promoting to backups/
if [[ ! -s "${OUT_SQL}" ]]; then
  echo "ERROR: dump file is empty"
  exit 1
fi
if ! grep -q "Dump completed" "${OUT_SQL}"; then
  echo "ERROR: dump does not contain 'Dump completed' marker — refusing to archive"
  exit 1
fi

gzip -9 -c "${OUT_SQL}" > "${OUT_GZ}.partial"
mv -f "${OUT_GZ}.partial" "${OUT_GZ}"
chmod 600 "${OUT_GZ}"

SIZE="$(du -h "${OUT_GZ}" | awk '{print $1}')"
echo "==> Wrote ${OUT_GZ} (${SIZE})"

# Uploads are not in MySQL — back them up or restores are incomplete
if [[ -d "${UPLOADS_DIR}" ]] && [[ -n "$(ls -A "${UPLOADS_DIR}" 2>/dev/null || true)" ]]; then
  echo "==> Archiving uploads"
  tar -C "${UPLOADS_DIR}" -czf "${OUT_UPLOADS}.partial" .
  mv -f "${OUT_UPLOADS}.partial" "${OUT_UPLOADS}"
  chmod 600 "${OUT_UPLOADS}"
  echo "==> Wrote ${OUT_UPLOADS} ($(du -h "${OUT_UPLOADS}" | awk '{print $1}'))"
else
  echo "==> Uploads directory empty — skipping uploads archive"
fi

echo "==> Pruning backups older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -type f \( -name 'hpys_all_*.sql.gz' -o -name 'hpys_uploads_*.tar.gz' \) \
  -mtime "+${RETENTION_DAYS}" -print -delete || true

echo "==> Backup complete"
ls -lh "${BACKUP_DIR}"/hpys_all_*.sql.gz 2>/dev/null | tail -n 5 || true
ls -lh "${BACKUP_DIR}"/hpys_uploads_*.tar.gz 2>/dev/null | tail -n 5 || true
