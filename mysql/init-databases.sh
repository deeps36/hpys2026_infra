#!/bin/bash
# Runs once on empty MySQL data dir (docker-entrypoint-initdb.d).
# Uses MYSQL_USER from the container environment so grants match DB_USERNAME.
set -euo pipefail

export MYSQL_PWD="${MYSQL_ROOT_PASSWORD}"

mysql -uroot <<EOSQL
CREATE DATABASE IF NOT EXISTS \`hpys_db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_reels_metadata\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_reels_db_1\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_reels_db_2\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_reels_db_3\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_reels_db_4\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_reels_db_5\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_reels_db_6\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS \`hpys_profile_img\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

GRANT ALL PRIVILEGES ON \`hpys_db\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_reels_metadata\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_reels_db_1\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_reels_db_2\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_reels_db_3\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_reels_db_4\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_reels_db_5\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_reels_db_6\`.* TO '${MYSQL_USER}'@'%';
GRANT ALL PRIVILEGES ON \`hpys_profile_img\`.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOSQL

unset MYSQL_PWD
