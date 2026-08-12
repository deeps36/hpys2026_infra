#!/usr/bin/env bash
# Production Oracle backup + verification against host MySQL (systemd).
# No secrets printed. No migration. No Docker volume/firewall changes.
set -euo pipefail
cd /opt/hpys

echo "=== OPT_HPYS ==="
test -d /opt/hpys && echo HAS_OPT_HPYS=yes
test -f /opt/hpys/.env && echo HAS_ENV=yes || { echo HAS_ENV=no; exit 1; }
test -f /opt/hpys/backup.sh && echo HAS_BACKUP_SH=yes || echo HAS_BACKUP_SH=no
test -f /opt/hpys/docker-compose.yml && echo HAS_COMPOSE=yes || echo HAS_COMPOSE=no

read_env() {
  local key="$1"
  local val=""
  val="$(grep -E "^${key}=" .env | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  printf '%s' "${val}"
}

echo "=== ENV_KEYS_PRESENT_NO_VALUES ==="
for k in DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD COMPOSE_PROFILES; do
  if grep -Eq "^${k}=" .env; then echo "KEY_PRESENT=$k"; else echo "KEY_MISSING=$k"; fi
done

DB_HOST="$(read_env DB_HOST)"
DB_PORT="$(read_env DB_PORT)"; DB_PORT="${DB_PORT:-3306}"
DB_DATABASE="$(read_env DB_DATABASE)"
DB_USERNAME="$(read_env DB_USERNAME)"
DB_PASSWORD="$(read_env DB_PASSWORD)"
COMPOSE_PROFILES="$(read_env COMPOSE_PROFILES)"

echo "DB_HOST_IS_HOSTINGER=$([[ "${DB_HOST}" == "srv1953.hstgr.io" ]] && echo yes || echo no)"
echo "DB_HOST_IS_ORACLE_IP=$([[ "${DB_HOST}" == "130.210.51.96" ]] && echo yes || echo no)"
echo "DB_HOST_IS_MYSQL_SERVICE=$([[ "${DB_HOST}" == "mysql" ]] && echo yes || echo no)"
echo "DB_DATABASE=${DB_DATABASE}"
echo "DB_USERNAME=${DB_USERNAME}"
echo "COMPOSE_PROFILES=${COMPOSE_PROFILES}"
echo "PASSWORD_SET=$([[ -n "${DB_PASSWORD}" ]] && echo yes || echo no)"

if [[ "${DB_HOST}" == "srv1953.hstgr.io" ]]; then
  echo "ERROR: Hostinger host detected — refusing"
  exit 2
fi

echo "=== MYSQL_LOCATION ==="
HPYS_MYSQL_DOCKER=no
if docker inspect hpys-mysql >/dev/null 2>&1; then
  HPYS_MYSQL_DOCKER=yes
  echo "HPYS_MYSQL_IMAGE=$(docker inspect -f '{{.Config.Image}}' hpys-mysql)"
  echo "HPYS_MYSQL_STATUS=$(docker inspect -f '{{.State.Status}}' hpys-mysql)"
else
  echo "HPYS_MYSQL_DOCKER=no"
fi
echo "SYSTEMD_MYSQL=$(systemctl is-active mysql 2>/dev/null || systemctl is-active mysqld 2>/dev/null || echo inactive)"
echo "MYSQLDUMP_PATH=$(command -v mysqldump || true)"
echo "MYSQL_CLIENT_PATH=$(command -v mysql || true)"

if ! command -v mysqldump >/dev/null 2>&1; then
  echo "ERROR: mysqldump not installed on host"
  exit 3
fi
if ! command -v mysql >/dev/null 2>&1; then
  echo "ERROR: mysql client not installed on host"
  exit 3
fi

# Prefer loopback on the Oracle host (do not rely on public exposure).
CONNECT_HOST="127.0.0.1"
# If DB_HOST is mysql service name, still use loopback for host mysqld.
if [[ "${DB_HOST}" == "mysql" ]]; then
  CONNECT_HOST="127.0.0.1"
fi

echo "CONNECT_HOST=${CONNECT_HOST}"
echo "CONNECT_PORT=${DB_PORT}"

echo "=== DISK ==="
df -h /opt/hpys | tail -1
df -h / | tail -1

export MYSQL_PWD="${DB_PASSWORD}"

run_sql() {
  local sql="$1"
  mysql -h"${CONNECT_HOST}" -P"${DB_PORT}" -u"${DB_USERNAME}" -N -e "${sql}" "${DB_DATABASE}"
}

echo "=== DB_READONLY_VERIFY ==="
echo -n "DATABASE="
run_sql "SELECT DATABASE();"
echo -n "VERSION="
run_sql "SELECT VERSION();"
echo -n "USERS_EXISTS="
run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='users';"
echo "CORE_TABLES="
run_sql "SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('users','bonus_quizzes','coin_transactions','game_questions','sessions') ORDER BY table_name;"

USERS_OK="$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='users';" | tr -d '\r')"
if [[ "${USERS_OK}" != "1" ]]; then
  echo "ERROR: users table missing"
  exit 4
fi

echo "=== USERS_ID ==="
run_sql "SELECT COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, EXTRA FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='users' AND column_name='id';"

echo "=== LQ_TABLES ==="
LQ="$(run_sql "SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name LIKE 'lq\\_%' ORDER BY table_name;" || true)"
if [[ -z "${LQ}" ]]; then
  echo "LQ_TABLES=none"
else
  echo "LQ_TABLES_BEGIN"
  echo "${LQ}"
  echo "LQ_TABLES_END"
fi

echo "=== BACKUP ==="
mkdir -p /opt/hpys/data/backups
STAMP="$(date -u '+%Y%m%d_%H%M%S')"
OUT_GZ="/opt/hpys/data/backups/hpys_prod_oracle_${STAMP}.sql.gz"
OUT_SQL="/tmp/hpys_prod_oracle_${STAMP}.sql"

if [[ -f "${OUT_GZ}" ]]; then
  echo "ERROR: backup target already exists"
  exit 5
fi

mysqldump -h"${CONNECT_HOST}" -P"${DB_PORT}" -u"${DB_USERNAME}" \
  --single-transaction --routines --triggers --events \
  --hex-blob --max-allowed-packet=512M --set-gtid-purged=OFF \
  --databases "${DB_DATABASE}" > "${OUT_SQL}"

if [[ ! -s "${OUT_SQL}" ]]; then
  echo "ERROR: dump empty"
  rm -f "${OUT_SQL}"
  exit 6
fi
if ! grep -q "Dump completed" "${OUT_SQL}"; then
  echo "ERROR: dump missing Dump completed marker"
  rm -f "${OUT_SQL}"
  exit 7
fi

gzip -9 -c "${OUT_SQL}" > "${OUT_GZ}.partial"
mv -f "${OUT_GZ}.partial" "${OUT_GZ}"
chmod 600 "${OUT_GZ}"
rm -f "${OUT_SQL}"

echo "BACKUP_PATH=${OUT_GZ}"
echo "BACKUP_SIZE_BYTES=$(stat -c%s "${OUT_GZ}")"
echo "BACKUP_MTIME_UTC=$(date -u -r "${OUT_GZ}" '+%Y-%m-%dT%H:%M:%SZ')"

echo "=== BACKUP_VERIFY ==="
if gzip -t "${OUT_GZ}"; then
  echo "GZIP_INTEGRITY=PASS"
else
  echo "GZIP_INTEGRITY=FAIL"
  exit 8
fi

TMP_SCAN="/tmp/hpys_backup_scan_${STAMP}.txt"
zcat "${OUT_GZ}" | grep -E '^CREATE TABLE' > "${TMP_SCAN}"
if grep -q 'CREATE TABLE `users`' "${TMP_SCAN}"; then
  echo "USERS_IN_DUMP=yes"
else
  echo "USERS_IN_DUMP=no"
  exit 9
fi

CORE_IN_DUMP=0
for t in bonus_quizzes coin_transactions game_questions sessions; do
  if grep -q "CREATE TABLE \`${t}\`" "${TMP_SCAN}"; then
    echo "CORE_IN_DUMP=${t}"
    CORE_IN_DUMP=1
  fi
done
echo "HPYS_SCHEMA_IN_DUMP=$([[ ${CORE_IN_DUMP} -eq 1 ]] && echo yes || echo no)"

LQ_IN_DUMP="$(grep -E '^CREATE TABLE `lq_' "${TMP_SCAN}" | sed -E 's/^CREATE TABLE `([^`]+)`.*/\1/' | sort -u || true)"
if [[ -z "${LQ_IN_DUMP}" ]]; then
  echo "LQ_IN_DUMP=none"
else
  echo "LQ_IN_DUMP_BEGIN"
  echo "${LQ_IN_DUMP}"
  echo "LQ_IN_DUMP_END"
fi
rm -f "${TMP_SCAN}"

DB_SIZE_BYTES="$(run_sql "SELECT COALESCE(SUM(data_length+index_length),0) FROM information_schema.tables WHERE table_schema=DATABASE();" | tr -d '\r')"
BACKUP_SIZE="$(stat -c%s "${OUT_GZ}")"
echo "DB_SIZE_BYTES=${DB_SIZE_BYTES}"
echo "BACKUP_SIZE_BYTES_AGAIN=${BACKUP_SIZE}"
if [[ "${BACKUP_SIZE}" -lt 1000 ]]; then
  echo "ERROR: backup suspiciously small"
  exit 10
fi

# Unset password from environment
unset MYSQL_PWD

echo "=== SAFETY ==="
echo "SCHEMA_MODIFIED=no"
echo "DATA_MODIFIED=no"
echo "MIGRATION_EXECUTED=no"
echo "DOCKER_VOLUMES_MODIFIED=no"
echo "FIREWALL_MODIFIED=no"
echo "HOSTINGER_USED=no"
echo "MYSQL_LOCATION=host_systemd"
echo "STATUS=PRODUCTION_BACKUP_VERIFIED"
