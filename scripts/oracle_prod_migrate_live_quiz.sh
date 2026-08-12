#!/usr/bin/env bash
# Controlled Live Quiz Step 1 production migration via hpys-backend container.
set -euo pipefail
cd /opt/hpys

read_env() {
  local key="$1"
  local val=""
  val="$(grep -E "^${key}=" .env | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
  val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  printf '%s' "${val}"
}

echo "=== PRECHECK ==="
echo "HOSTNAME=$(hostname)"
echo "SYSTEMD_MYSQL=$(systemctl is-active mysql 2>/dev/null || systemctl is-active mysqld 2>/dev/null || echo inactive)"
BACKUP=/opt/hpys/data/backups/hpys_prod_oracle_20260812_094321.sql.gz
test -f "$BACKUP" && echo BACKUP_EXISTS=yes || { echo BACKUP_MISSING; exit 1; }
gzip -t "$BACKUP" && echo BACKUP_GZIP=PASS
echo "BACKUP_SIZE=$(stat -c%s "$BACKUP")"

DB_HOST="$(read_env DB_HOST)"
DB_PORT="$(read_env DB_PORT)"; DB_PORT="${DB_PORT:-3306}"
DB_DATABASE="$(read_env DB_DATABASE)"
DB_USERNAME="$(read_env DB_USERNAME)"
DB_PASSWORD="$(read_env DB_PASSWORD)"

echo "DB_HOST_IS_HOSTINGER=$([[ "$DB_HOST" == "srv1953.hstgr.io" ]] && echo yes || echo no)"
echo "DB_HOST_IS_ORACLE_IP=$([[ "$DB_HOST" == "130.210.51.96" ]] && echo yes || echo no)"
echo "DB_DATABASE=$DB_DATABASE"
echo "DB_USERNAME=$DB_USERNAME"
[[ "$DB_HOST" != "srv1953.hstgr.io" ]] || { echo ERROR_HOSTINGER; exit 2; }
[[ "$DB_DATABASE" == "hpys_db" ]] || { echo ERROR_DB; exit 3; }

# Host mysql client for verification (loopback)
export MYSQL_PWD="$DB_PASSWORD"
run_sql() { mysql -h127.0.0.1 -P"$DB_PORT" -u"$DB_USERNAME" -N -e "$1" "$DB_DATABASE"; }

echo -n "DATABASE="; run_sql "SELECT DATABASE();"
echo -n "VERSION="; run_sql "SELECT VERSION();"
echo -n "USERS_EXISTS="; run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='users';"
echo -n "USERS_ID="; run_sql "SELECT CONCAT(COLUMN_TYPE,'|',IS_NULLABLE,'|',COLUMN_KEY,'|',EXTRA) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='users' AND column_name='id';"
USERS_BEFORE="$(run_sql "SELECT COUNT(*) FROM users;" | tr -d '\r')"
echo "USERS_COUNT_BEFORE=$USERS_BEFORE"
LQ_BEFORE="$(run_sql "SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name LIKE 'lq\\_%' ORDER BY table_name;" || true)"
if [[ -z "${LQ_BEFORE}" ]]; then echo "LQ_BEFORE=none"; else echo "LQ_BEFORE=$LQ_BEFORE"; exit 4; fi
echo "CORE_BEFORE="; run_sql "SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('users','bonus_quizzes','coin_transactions','game_questions','sessions') ORDER BY table_name;"

echo "=== MIGRATION_FILES ==="
test -f /opt/hpys/backend/src/modules/live-quiz/schema/migrate.js
test -f /opt/hpys/backend/src/modules/live-quiz/schema/sql/001_lq_tables.sql
SQL=/opt/hpys/backend/src/modules/live-quiz/schema/sql/001_lq_tables.sql
MIG=/opt/hpys/backend/src/modules/live-quiz/schema/migrate.js
for pat in 'DROP TABLE' 'DROP DATABASE' 'TRUNCATE' 'DELETE FROM'; do
  if grep -Eqi "$pat" "$SQL" "$MIG"; then echo "DESTRUCTIVE_$pat=yes"; exit 5; else echo "DESTRUCTIVE_$pat=no"; fi
done

echo "=== COPY_INTO_BACKEND_CONTAINER ==="
# Production backend container is read-only; run a one-off writable container
# from the same image with host networking so 127.0.0.1 reaches systemd MySQL.
test -f /opt/hpys/backend/src/modules/live-quiz/schema/migrate.js
test -f /opt/hpys/backend/src/modules/live-quiz/schema/sql/001_lq_tables.sql
echo COPY_OK=mounted_via_volume

run_migrate() {
  docker run --rm --network host \
    -v /opt/hpys/backend/src/modules/live-quiz:/app/src/modules/live-quiz:ro \
    -e DB_HOST=127.0.0.1 \
    -e DB_PORT="$DB_PORT" \
    -e DB_DATABASE="$DB_DATABASE" \
    -e DB_USERNAME="$DB_USERNAME" \
    -e DB_PASSWORD="$DB_PASSWORD" \
    -e LOCAL_DB_HOST=127.0.0.1 \
    -e LOCAL_DB_PORT="$DB_PORT" \
    -e LOCAL_DB_DATABASE="$DB_DATABASE" \
    -e LOCAL_DB_USERNAME="$DB_USERNAME" \
    -e LOCAL_DB_PASSWORD="$DB_PASSWORD" \
    -e PROD_DB_HOST=127.0.0.1 \
    -e PROD_DB_PORT="$DB_PORT" \
    -e PROD_DB_DATABASE="$DB_DATABASE" \
    -e PROD_DB_USERNAME="$DB_USERNAME" \
    -e PROD_DB_PASSWORD="$DB_PASSWORD" \
    -w /app \
    hpys-backend:latest \
    node src/modules/live-quiz/schema/migrate.js
}

echo "=== MIGRATION_1 ==="
run_migrate
echo "MIGRATION_1_OK=yes"

EXPECTED='lq_quizzes lq_questions lq_question_options lq_question_media lq_quiz_participants lq_quiz_sessions lq_answers lq_scores lq_leaderboard_snapshots lq_quiz_events lq_audit_logs'
echo "=== VERIFY_AFTER_1 ==="
for t in $EXPECTED; do
  c="$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='$t';" | tr -d '\r')"
  echo "TABLE_$t=$c"
  [[ "$c" == "1" ]] || { echo "MISSING $t"; exit 6; }
done

echo "UNIQUES="
run_sql "SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS cols FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name IN ('lq_answers','lq_questions','lq_quiz_participants','lq_scores','lq_quizzes') AND NON_UNIQUE=0 GROUP BY TABLE_NAME, INDEX_NAME, NON_UNIQUE ORDER BY TABLE_NAME, INDEX_NAME;"

echo "FKS="
run_sql "SELECT CONSTRAINT_NAME, TABLE_NAME, REFERENCED_TABLE_NAME, DELETE_RULE FROM information_schema.referential_constraints WHERE constraint_schema=DATABASE() AND table_name LIKE 'lq_%' ORDER BY TABLE_NAME, CONSTRAINT_NAME;"

echo "FK_COLUMNS="
run_sql "SELECT CONSTRAINT_NAME, TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME FROM information_schema.key_column_usage WHERE table_schema=DATABASE() AND table_name LIKE 'lq_%' AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION;"

echo "DATETIME3="
run_sql "SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name LIKE 'lq_%' AND DATA_TYPE='datetime' ORDER BY TABLE_NAME, COLUMN_NAME;"

echo "EXTENSIBLE="
run_sql "SELECT COLUMN_NAME, COLUMN_TYPE FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='lq_questions' AND column_name IN ('type','scoring_policy');"

echo "PARTICIPANT_ID_TYPE="
run_sql "SELECT TABLE_NAME, COLUMN_TYPE FROM information_schema.columns WHERE table_schema=DATABASE() AND column_name='participant_id' AND table_name LIKE 'lq_%' ORDER BY TABLE_NAME;"

USERS_AFTER1="$(run_sql "SELECT COUNT(*) FROM users;" | tr -d '\r')"
echo "USERS_COUNT_AFTER1=$USERS_AFTER1"
[[ "$USERS_AFTER1" == "$USERS_BEFORE" ]] || { echo ERROR_USERS_COUNT; exit 7; }
echo "CORE_AFTER1="; run_sql "SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('users','bonus_quizzes','coin_transactions','game_questions','sessions') ORDER BY table_name;"

echo "=== MIGRATION_2 ==="
run_migrate
echo "MIGRATION_2_OK=yes"

echo "=== VERIFY_AFTER_2 ==="
for t in $EXPECTED; do
  c="$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='$t';" | tr -d '\r')"
  echo "TABLE2_$t=$c"
  [[ "$c" == "1" ]] || exit 8
done
LQ_COUNT="$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name LIKE 'lq\\_%';" | tr -d '\r')"
echo "LQ_TABLE_COUNT=$LQ_COUNT"
[[ "$LQ_COUNT" == "11" ]] || exit 9
USERS_AFTER2="$(run_sql "SELECT COUNT(*) FROM users;" | tr -d '\r')"
echo "USERS_COUNT_AFTER2=$USERS_AFTER2"
[[ "$USERS_AFTER2" == "$USERS_BEFORE" ]] || exit 10
ANS_UQ="$(run_sql "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='lq_answers' AND index_name='uq_lq_answers_quiz_question_participant' AND NON_UNIQUE=0;" | tr -d '\r')"
echo "ANSWER_UNIQUE_COLS=$ANS_UQ"
[[ "$ANS_UQ" == "quiz_id,question_id,participant_id" ]] || exit 11
USERS_FK="$(run_sql "SELECT COUNT(*) FROM information_schema.referential_constraints WHERE constraint_schema=DATABASE() AND constraint_name='fk_lq_participants_user';" | tr -d '\r')"
echo "USERS_FK_PRESENT=$USERS_FK"
[[ "$USERS_FK" == "1" ]] || exit 12

unset MYSQL_PWD
echo "HOSTINGER_TOUCHED=no"
echo "STATUS=LIVE_QUIZ_STEP1_PRODUCTION_MIGRATION_VERIFIED"
