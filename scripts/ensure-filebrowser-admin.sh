#!/usr/bin/env bash
# =============================================================================
# Ensure File Browser admin is reachable via REST (idempotent).
#
# Preferred over CLI while the server is running — BoltDB is locked by the
# live process, so `docker exec … users ls|add|update` hangs with "timeout".
#
# Behaviour:
#   - Login with FILEBROWSER_USERNAME / FILEBROWSER_PASSWORD
#   - Success → OK (admin already matches .env)
#   - Failure → WARN only (do not fail deploy)
#
# Creating a brand-new admin on an empty DB is handled by init-filebrowser.sh
# (CLI with server stopped). REST cannot bootstrap the first user without an
# existing admin token.
# =============================================================================
set -uo pipefail

FB_BASE="${FILEBROWSER_BASE_URL:-http://127.0.0.1:8081}"
FB_USER="${FILEBROWSER_USERNAME:-admin}"
FB_PASS="${FILEBROWSER_PASSWORD:-}"

log() { echo "==> [filebrowser-api] $*"; }
warn() { echo "WARN: [filebrowser-api] $*" >&2; }

if [[ -z "${FB_PASS}" ]]; then
  warn "FILEBROWSER_PASSWORD empty — skipping REST admin check"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  warn "curl not found — skipping REST admin check"
  exit 0
fi

log "Checking admin login via REST ${FB_BASE}/api/login (user=${FB_USER})"
resp="$(curl -sS --max-time 15 -X POST "${FB_BASE}/api/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${FB_USER}\",\"password\":\"${FB_PASS}\"}" 2>/dev/null || true)"

# Successful login returns a raw JWT string (not JSON error object).
if [[ -n "${resp}" && "${resp}" != *"error"* && "${resp}" != *"Wrong"* && "${resp}" != *"Invalid"* && "${#resp}" -gt 20 ]]; then
  log "Admin credentials OK (REST login succeeded) — no CLI needed"
  exit 0
fi

warn "REST login failed for user '${FB_USER}' — .env password may not match existing DB"
warn "File Browser service can still be healthy; fix credentials via the web UI, or:"
warn "  docker compose stop filebrowser"
warn "  docker run --rm --user 1001:33 -v /opt/hpys/filebrowser:/config \\"
warn "    ${FILEBROWSER_IMAGE:-filebrowser/filebrowser:v2.32.0} \\"
warn "    users update ${FB_USER} -p 'YOUR_PASSWORD' --database /config/database.db"
warn "  docker compose up -d filebrowser"
warn "Never run users ls/add/update via docker exec against a LIVE container DB."
exit 0
