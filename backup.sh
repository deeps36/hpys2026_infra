#!/usr/bin/env bash
# =============================================================================
# HPYS backup — MySQL logical dump + uploads archive, 30-day retention
# External Hostinger (default) or local compose mysql (profile local-mysql).
# Usage: ./backup.sh
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

cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

read_env() {
  local key="$1"
  local val=""
  val="$(grep -E "^${key}=" .env | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  printf '%s' "${val}"
}

mkdir -p "${BACKUP_DIR}"
[[ -f .env ]] || { echo "ERROR: .env not found"; exit 1; }

COMPOSE_PROFILES="$(read_env COMPOSE_PROFILES)"
DB_HOST="$(read_env DB_HOST)"
DB_PORT="$(read_env DB_PORT)"; DB_PORT="${DB_PORT:-3306}"
DEFAULT_USER="$(read_env DB_USERNAME)"
DEFAULT_PASS="$(read_env DB_PASSWORD)"

OUT_SQL="${TMP_DIR}/hpys_all_${STAMP}.sql"
OUT_GZ="${BACKUP_DIR}/hpys_all_${STAMP}.sql.gz"
OUT_UPLOADS="${BACKUP_DIR}/hpys_uploads_${STAMP}.tar.gz"

echo "==> Starting backup at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
: > "${OUT_SQL}"

dump_one() {
  local db_name="$1" user="$2" pass="$3" host="$4" port="$5"
  [[ -n "${db_name}" ]] || return 0
  user="${user:-${DEFAULT_USER}}"
  pass="${pass:-${DEFAULT_PASS}}"
  host="${host:-${DB_HOST}}"
  port="${port:-${DB_PORT}}"

  echo "==> Dumping database ${db_name} (@${host}:${port} as ${user})"

  if [[ "${COMPOSE_PROFILES}" == *"local-mysql"* ]] && docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    local root_pw
    root_pw="$(read_env MYSQL_ROOT_PASSWORD)"
    docker exec -e MYSQL_PWD="${root_pw}" "${CONTAINER}" \
      mysqldump -uroot --single-transaction --routines --triggers --events \
        --hex-blob --max-allowed-packet=512M --set-gtid-purged=OFF \
        --databases "${db_name}" >> "${OUT_SQL}"
  else
    [[ -n "${host}" && -n "${user}" && -n "${pass}" ]] || {
      echo "ERROR: missing host/user/password for ${db_name}"; exit 1
    }
    docker run --rm -e MYSQL_PWD="${pass}" mysql:8.0.43 \
      mysqldump -h"${host}" -P"${port}" -u"${user}" \
        --single-transaction --routines --triggers --events \
        --hex-blob --max-allowed-packet=512M --set-gtid-purged=OFF \
        --databases "${db_name}" >> "${OUT_SQL}"
  fi
}

dump_one "$(read_env DB_DATABASE)" \
  "$(read_env DB_USERNAME)" "$(read_env DB_PASSWORD)" \
  "$(read_env DB_HOST)" "$(read_env DB_PORT)"

dump_one "$(read_env REELS_METADATA_DB_NAME)" \
  "$(read_env REELS_METADATA_DB_USER)" "$(read_env REELS_METADATA_DB_PASSWORD)" \
  "$(read_env REELS_METADATA_DB_HOST)" "$(read_env REELS_METADATA_DB_PORT)"

for i in 1 2 3 4 5 6; do
  dump_one "$(read_env REELS_DB_${i}_NAME)" \
    "$(read_env REELS_DB_${i}_USER)" "$(read_env REELS_DB_${i}_PASSWORD)" \
    "$(read_env REELS_DB_${i}_HOST)" "$(read_env REELS_DB_${i}_PORT)"
done

dump_one "$(read_env PROFILE_DB_NAME)" \
  "$(read_env PROFILE_DB_USER)" "$(read_env PROFILE_DB_PASSWORD)" \
  "$(read_env PROFILE_DB_HOST)" "$(read_env PROFILE_DB_PORT)"

if [[ ! -s "${OUT_SQL}" ]]; then
  echo "ERROR: dump file is empty"; exit 1
fi
if ! grep -q "Dump completed" "${OUT_SQL}"; then
  echo "ERROR: dump missing 'Dump completed' marker"; exit 1
fi

gzip -9 -c "${OUT_SQL}" > "${OUT_GZ}.partial"
mv -f "${OUT_GZ}.partial" "${OUT_GZ}"
chmod 600 "${OUT_GZ}"
echo "==> Wrote ${OUT_GZ} ($(du -h "${OUT_GZ}" | awk '{print $1}'))"

if [[ -d "${UPLOADS_DIR}" ]] && [[ -n "$(ls -A "${UPLOADS_DIR}" 2>/dev/null || true)" ]]; then
  tar -C "${UPLOADS_DIR}" -czf "${OUT_UPLOADS}.partial" .
  mv -f "${OUT_UPLOADS}.partial" "${OUT_UPLOADS}"
  chmod 600 "${OUT_UPLOADS}"
  echo "==> Wrote ${OUT_UPLOADS}"
else
  echo "==> Uploads empty — skip"
fi

find "${BACKUP_DIR}" -type f \( -name 'hpys_all_*.sql.gz' -o -name 'hpys_uploads_*.tar.gz' \) \
  -mtime "+${RETENTION_DAYS}" -print -delete || true
echo "==> Backup complete"
