#!/usr/bin/env bash
# =============================================================================
# Initialize File Browser (idempotent, BoltDB-safe).
#
# File Browser stores state in BoltDB (database.db). BoltDB allows ONE writer.
# While hpys-filebrowser is running it holds an exclusive lock — any CLI
# (`users ls|add|update`, `config …`) against that live DB hangs until timeout.
# Official docs still support those CLI commands, but ONLY when the server is
# stopped (or against a copy of the DB). See docs/FILE_BROWSER.md.
#
# Strategy:
#   1) First run (no DB file): stop service → CLI config init + admin user → done
#   2) DB already exists: skip ALL CLI — do not touch the live BoltDB
#   3) Admin credential verification / recovery happens after start via REST
#      (scripts/ensure-filebrowser-admin.sh called from deploy.sh)
#
# This script must NOT fail a deploy for soft init problems (exit 0 + warnings).
# =============================================================================
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

FB_DIR="${ROOT_DIR}/filebrowser"
UPLOADS_DIR="${ROOT_DIR}/uploads"
IMAGE="${FILEBROWSER_IMAGE:-filebrowser/filebrowser:v2.32.0}"
FB_USER="${FILEBROWSER_USERNAME:-admin}"
FB_PASS="${FILEBROWSER_PASSWORD:-}"
CLI_TIMEOUT_SEC="${FILEBROWSER_CLI_TIMEOUT_SEC:-45}"

log() { echo "==> [filebrowser] $*"; }
warn() { echo "WARN: [filebrowser] $*" >&2; }
err() { echo "ERROR: [filebrowser] $*" >&2; }

if [[ -z "${FB_PASS}" ]]; then
  warn "FILEBROWSER_PASSWORD is empty — skipping File Browser DB bootstrap"
  exit 0
fi

mkdir -p "${UPLOADS_DIR}/reels" "${UPLOADS_DIR}/users" "${UPLOADS_DIR}/profile" "${UPLOADS_DIR}/temp"
mkdir -p "${FB_DIR}"

if [[ ! -f "${FB_DIR}/settings.json" ]]; then
  warn "Missing ${FB_DIR}/settings.json (should come from Git) — continuing without CLI init"
  exit 0
fi
if [[ ! -f "${FB_DIR}/branding.json" ]]; then
  printf '%s\n' '{"name":"HPYS Files","disableExternal":true}' > "${FB_DIR}/branding.json"
fi

# Permissions: backend uid 1001 + www-data (33)
fix_perms() {
  local target="$1"
  if command -v sudo >/dev/null 2>&1; then
    sudo chown -R 1001:33 "${target}" 2>/dev/null || chown -R 1001:33 "${target}" 2>/dev/null || true
    sudo chmod -R ug+rwX "${target}" 2>/dev/null || chmod -R ug+rwX "${target}" 2>/dev/null || true
    sudo find "${target}" -type d -exec chmod g+s {} \; 2>/dev/null || true
  else
    chown -R 1001:33 "${target}" 2>/dev/null || true
    chmod -R ug+rwX "${target}" 2>/dev/null || true
  fi
}
fix_perms "${UPLOADS_DIR}"
fix_perms "${FB_DIR}"

# Docker created a directory when bind source was missing — unusable as BoltDB.
if [[ -d "${FB_DIR}/database.db" ]]; then
  warn "filebrowser/database.db is a DIRECTORY (bad Docker bind). Remove it manually, then re-deploy."
  exit 0
fi

need_init=0
if [[ ! -f "${FB_DIR}/database.db" ]]; then
  need_init=1
elif [[ ! -s "${FB_DIR}/database.db" ]]; then
  need_init=1
  rm -f "${FB_DIR}/database.db" 2>/dev/null || true
fi

if (( need_init == 0 )); then
  log "Database already exists at ${FB_DIR}/database.db — skipping CLI (BoltDB lock-safe)"
  log "Admin credentials will be verified via REST after the service is healthy"
  fix_perms "${FB_DIR}"
  fix_perms "${UPLOADS_DIR}"
  exit 0
fi

# --- First-run only: server MUST be stopped or BoltDB CLI will hang ("timeout") ---
log "First-run bootstrap: ensuring File Browser is stopped before CLI (BoltDB exclusive lock)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'hpys-filebrowser'; then
  log "Stopping hpys-filebrowser to release BoltDB lock"
  docker stop hpys-filebrowser >/dev/null 2>&1 || true
  # Wait briefly for lock release
  sleep 2
fi

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=KILL "${CLI_TIMEOUT_SEC}" "$@"
  else
    "$@"
  fi
}

fb_cli() {
  # Ephemeral container — NEVER docker exec into the live server for BoltDB writes.
  run_with_timeout docker run --rm \
    --platform linux/arm64 \
    --user "1001:33" \
    --network none \
    -v "${FB_DIR}:/config" \
    -v "${UPLOADS_DIR}:/srv" \
    "${IMAGE}" \
    "$@"
}

log "Initializing File Browser database (CLI while server stopped)"
if ! fb_cli config init --database /config/database.db; then
  warn "config init failed or timed out — continuing; deploy will check service health later"
  exit 0
fi

fb_cli config set --database /config/database.db \
  --address 0.0.0.0 \
  --port 80 \
  --root /srv \
  --auth.method json \
  --signup=false || warn "config set (core) failed"
fb_cli config set --database /config/database.db --commands="" || true

log "Creating admin user '${FB_USER}' via CLI (first-run only)"
if ! fb_cli users add "${FB_USER}" "${FB_PASS}" --perm.admin --database /config/database.db; then
  warn "users add failed or timed out — continuing; use UI or stop+CLI to create admin later"
  exit 0
fi

fix_perms "${FB_DIR}"
fix_perms "${UPLOADS_DIR}"
log "First-run init complete"
exit 0
