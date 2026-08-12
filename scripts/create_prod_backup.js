/**
 * One-shot production backup runner using the same approach as backup.sh.
 * - Reads hpys2026_backend/env.production (does not print secrets)
 * - Uses dockerized mysqldump (mysql:8.0.43) like backup.sh
 * - Writes to data/backups/hpys_all_YYYYMMDD_HHMMSS.sql.gz
 * - Does NOT modify schema or run migrations
 *
 * Usage: node scripts/create_prod_backup.js
 */
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const zlib = require('zlib');
const { pipeline } = require('stream/promises');
const { createReadStream, createWriteStream } = require('fs');

const ROOT = path.resolve(__dirname, '..');
const BACKEND_ENV = path.join(ROOT, 'hpys2026_backend', 'env.production');
const BACKUP_DIR = path.join(ROOT, 'data', 'backups');

function parseEnvFile(filePath) {
    const raw = fs.readFileSync(filePath, 'utf8');
    const map = {};
    for (const line of raw.split(/\r?\n/)) {
        if (!line || line.trim().startsWith('#')) continue;
        const idx = line.indexOf('=');
        if (idx <= 0) continue;
        const key = line.slice(0, idx).trim();
        let val = line.slice(idx + 1).trim();
        if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
            val = val.slice(1, -1);
        }
        map[key] = val;
    }
    return map;
}

function envGet(map, ...keys) {
    for (const k of keys) {
        if (map[k] !== undefined && map[k] !== '') return map[k];
    }
    return null;
}

function stampUtc() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return (
        d.getUTCFullYear() +
        p(d.getUTCMonth() + 1) +
        p(d.getUTCDate()) +
        '_' +
        p(d.getUTCHours()) +
        p(d.getUTCMinutes()) +
        p(d.getUTCSeconds())
    );
}

function dumpOne({ host, port, user, password, database, outSqlPath }) {
    if (!database) {
        console.log(`[backup] skip empty database name`);
        return { skipped: true };
    }
    if (!host || !user || !password) {
        throw new Error(`Missing host/user/password for database ${database}`);
    }

    console.log(`[backup] Dumping database=${database} host=${host} port=${port} user=${user}`);

    const args = [
        'run',
        '--rm',
        '-e',
        `MYSQL_PWD=${password}`,
        'mysql:8.0.43',
        'mysqldump',
        `-h${host}`,
        `-P${port}`,
        `-u${user}`,
        '--single-transaction',
        '--routines',
        '--triggers',
        '--events',
        '--hex-blob',
        '--max-allowed-packet=512M',
        '--set-gtid-purged=OFF',
        '--databases',
        database
    ];

    const beforeSize = fs.existsSync(outSqlPath) ? fs.statSync(outSqlPath).size : 0;
    const outFd = fs.openSync(outSqlPath, 'a');
    const stderrChunks = [];

    const result = spawnSync('docker', args, {
        stdio: ['ignore', outFd, 'pipe'],
        encoding: 'utf8',
        maxBuffer: 10 * 1024 * 1024
    });
    fs.closeSync(outFd);

    if (result.stderr) {
        stderrChunks.push(String(result.stderr));
    }

    if (result.status !== 0) {
        const err = stderrChunks.join('').slice(0, 2000);
        throw new Error(`mysqldump failed for ${database}: ${err || 'unknown error'}`);
    }

    const afterSize = fs.statSync(outSqlPath).size;
    const wrote = afterSize - beforeSize;
    if (wrote <= 0) {
        throw new Error(`mysqldump produced empty output for ${database}`);
    }

    // Marker check on the appended region (tail read)
    const tailSize = Math.min(wrote, 256 * 1024);
    const fd = fs.openSync(outSqlPath, 'r');
    const buf = Buffer.alloc(tailSize);
    fs.readSync(fd, buf, 0, tailSize, afterSize - tailSize);
    fs.closeSync(fd);
    if (!buf.toString('utf8').includes('Dump completed')) {
        throw new Error(`mysqldump missing 'Dump completed' marker for ${database}`);
    }

    return { skipped: false, bytes: wrote };
}

function scanSqlFileForSchema(sqlPath) {
    const text = fs.readFileSync(sqlPath, 'utf8');
    return inspectSql(text);
}

function scanGzipForSchema(gzPath) {
    const gunzipped = zlib.gunzipSync(fs.readFileSync(gzPath));
    // Only scan DDL markers; do not log row data
    return inspectSql(gunzipped.toString('utf8'));
}

async function compressGzip(src, dest) {
    const partial = dest + '.partial';
    await pipeline(createReadStream(src), zlib.createGzip({ level: 9 }), createWriteStream(partial));
    fs.renameSync(partial, dest);
}

function verifyGzip(filePath) {
    try {
        zlib.gunzipSync(fs.readFileSync(filePath));
        return true;
    } catch (e) {
        throw new Error(`gzip integrity check failed: ${e.message}`);
    }
}

function inspectSql(sqlText) {
    const hasUsers = /CREATE TABLE .*`users`/i.test(sqlText) || /CREATE TABLE users/i.test(sqlText);
    const coreHints = ['bonus_quizzes', 'coin_transactions', 'game_questions', 'sessions'];
    const coreFound = coreHints.filter((t) => new RegExp('`' + t + '`|' + t, 'i').test(sqlText));
    const lqMatches = sqlText.match(/CREATE TABLE(?: IF NOT EXISTS)? [`']?(lq_[a-z0-9_]+)/gi) || [];
    const lqTables = [...new Set(lqMatches.map((m) => {
        const mm = m.match(/lq_[a-z0-9_]+/i);
        return mm ? mm[0].toLowerCase() : null;
    }).filter(Boolean))];

    return {
        hasUsers,
        coreTablesDetected: coreFound,
        existingHpysSchemaDetected: hasUsers && coreFound.length > 0,
        lqTablesPresent: lqTables
    };
}

async function main() {
    if (!fs.existsSync(BACKEND_ENV)) {
        throw new Error(`Missing production env file: ${BACKEND_ENV}`);
    }

    const map = parseEnvFile(BACKEND_ENV);
    const host = envGet(map, 'DB_HOST', 'PROD_DB_HOST', 'LOCAL_DB_HOST');
    const port = envGet(map, 'DB_PORT', 'PROD_DB_PORT', 'LOCAL_DB_PORT') || '3306';
    const user = envGet(map, 'DB_USERNAME', 'PROD_DB_USERNAME', 'LOCAL_DB_USERNAME');
    const password = envGet(map, 'DB_PASSWORD', 'PROD_DB_PASSWORD', 'LOCAL_DB_PASSWORD');
    const database = envGet(map, 'DB_DATABASE', 'PROD_DB_DATABASE', 'LOCAL_DB_DATABASE');

    console.log('[backup] Environment=PRODUCTION');
    console.log(`[backup] Database=${database}`);
    console.log(`[backup] HostingerTarget=${host === 'srv1953.hstgr.io'}`);
    console.log(`[backup] UsernameSet=${Boolean(user)} PasswordSet=${Boolean(password)}`);

    if (!database || !host || !user || !password) {
        throw new Error('Production DB configuration incomplete in env.production');
    }

    fs.mkdirSync(BACKUP_DIR, { recursive: true });

    const stamp = stampUtc();
    const sqlName = `hpys_all_${stamp}.sql`;
    const gzName = `hpys_all_${stamp}.sql.gz`;
    const sqlPath = path.join(BACKUP_DIR, sqlName);
    const gzPath = path.join(BACKUP_DIR, gzName);

    if (fs.existsSync(gzPath) || fs.existsSync(sqlPath)) {
        throw new Error('Backup target already exists; refusing to overwrite');
    }

    // Free space check (Node doesn't give drive free easily on all platforms; best-effort)
    console.log('[backup] Writing uncompressed SQL then compressing (official backup.sh pattern)');

    fs.writeFileSync(sqlPath, `-- HPYS production logical backup\n-- created_utc=${new Date().toISOString()}\n-- database=${database}\n\n`, 'utf8');

    // Main DB first (required)
    dumpOne({ host, port, user, password, database, outSqlPath: sqlPath });

    // Optional related DBs if configured (same as backup.sh)
    const extras = [];
    extras.push({
        database: envGet(map, 'REELS_METADATA_DB_NAME'),
        user: envGet(map, 'REELS_METADATA_DB_USER') || user,
        password: envGet(map, 'REELS_METADATA_DB_PASSWORD') || password,
        host: envGet(map, 'REELS_METADATA_DB_HOST') || host,
        port: envGet(map, 'REELS_METADATA_DB_PORT') || port
    });
    for (let i = 1; i <= 6; i++) {
        extras.push({
            database: envGet(map, `REELS_DB_${i}_NAME`),
            user: envGet(map, `REELS_DB_${i}_USER`) || user,
            password: envGet(map, `REELS_DB_${i}_PASSWORD`) || password,
            host: envGet(map, `REELS_DB_${i}_HOST`) || host,
            port: envGet(map, `REELS_DB_${i}_PORT`) || port
        });
    }
    extras.push({
        database: envGet(map, 'PROFILE_DB_NAME'),
        user: envGet(map, 'PROFILE_DB_USER') || user,
        password: envGet(map, 'PROFILE_DB_PASSWORD') || password,
        host: envGet(map, 'PROFILE_DB_HOST') || host,
        port: envGet(map, 'PROFILE_DB_PORT') || port
    });

    for (const extra of extras) {
        if (!extra.database) continue;
        try {
            dumpOne({ ...extra, outSqlPath: sqlPath });
        } catch (err) {
            // Main DB backup is mandatory; extras are best-effort with clear logs
            console.warn(`[backup] WARNING optional dump failed for ${extra.database}: ${err.message}`);
        }
    }

    const sqlStat = fs.statSync(sqlPath);
    if (sqlStat.size <= 0) {
        throw new Error('Uncompressed dump is empty');
    }

    // Tail-check for Dump completed without relying on full-file string search only
    const tailSize = Math.min(sqlStat.size, 512 * 1024);
    const fd = fs.openSync(sqlPath, 'r');
    const tailBuf = Buffer.alloc(tailSize);
    fs.readSync(fd, tailBuf, 0, tailSize, sqlStat.size - tailSize);
    fs.closeSync(fd);
    if (!tailBuf.toString('utf8').includes('Dump completed')) {
        throw new Error("Dump missing 'Dump completed' marker");
    }

    const inspection = scanSqlFileForSchema(sqlPath);
    console.log('[backup] Inspection:', JSON.stringify({
        hasUsers: inspection.hasUsers,
        existingHpysSchemaDetected: inspection.existingHpysSchemaDetected,
        coreTablesDetected: inspection.coreTablesDetected,
        lqTablesPresent: inspection.lqTablesPresent
    }));

    await compressGzip(sqlPath, gzPath);
    try {
        fs.chmodSync(gzPath, 0o600);
    } catch (_) {
        /* Windows may ignore chmod */
    }

    // Remove uncompressed after successful gzip (official script keeps only .gz)
    fs.unlinkSync(sqlPath);

    const okGzip = verifyGzip(gzPath);
    const gzStat = fs.statSync(gzPath);
    const finalInspection = scanGzipForSchema(gzPath);

    console.log(JSON.stringify({
        status: 'OK',
        environment: 'PRODUCTION',
        database,
        backupFile: path.relative(ROOT, gzPath).replace(/\\/g, '/'),
        backupAbs: gzPath,
        backupSizeBytes: gzStat.size,
        backupTimestampUtc: new Date(gzStat.mtimeMs).toISOString(),
        compressionVerified: okGzip,
        readable: true,
        usersTablePresent: finalInspection.hasUsers,
        existingHpysSchemaDetected: finalInspection.existingHpysSchemaDetected,
        coreTablesDetected: finalInspection.coreTablesDetected,
        lqTablesPresent: finalInspection.lqTablesPresent,
        productionSchemaModified: false,
        productionDataModified: false,
        liveQuizMigrationExecuted: false
    }, null, 2));
}

main().catch((err) => {
    console.error('[backup] FAILED:', err.message);
    process.exitCode = 1;
});
