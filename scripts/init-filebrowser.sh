#!/usr/bin/env bash
# =============================================================================
# Initialize File Browser DB + admin user (idempotent).
# Called from deploy.sh. Expects infra root as cwd (/opt/hpys).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

FB_DIR="${ROOT_DIR}/filebrowser"
UPLOADS_DIR="${ROOT_DIR}/uploads"
IMAGE="${FILEBROWSER_IMAGE:-filebrowser/filebrowser:v2.31.3}"
FB_USER="${FILEBROWSER_USERNAME:-admin}"
FB_PASS="${FILEBROWSER_PASSWORD:-}"

log() { echo "==> [filebrowser] $*"; }
err() { echo "ERROR: [filebrowser] $*" >&2; }

if [[ -z "${FB_PASS}" ]]; then
  err "FILEBROWSER_PASSWORD is required"
  exit 1
fi

mkdir -p "${UPLOADS_DIR}/reels" "${UPLOADS_DIR}/users" "${UPLOADS_DIR}/profile" "${UPLOADS_DIR}/temp"
mkdir -p "${FB_DIR}"

if [[ ! -f "${FB_DIR}/settings.json" ]]; then
  err "Missing ${FB_DIR}/settings.json (should come from Git)"
  exit 1
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

fb_cli() {
  docker run --rm \
    --platform linux/arm64 \
    --user "1001:33" \
    --network none \
    -v "${FB_DIR}:/config" \
    -v "${UPLOADS_DIR}:/srv" \
    "${IMAGE}" \
    "$@"
}

need_init=0
if [[ ! -f "${FB_DIR}/database.db" ]]; then
  need_init=1
elif [[ ! -s "${FB_DIR}/database.db" ]]; then
  need_init=1
  rm -f "${FB_DIR}/database.db"
fi

if (( need_init == 1 )); then
  log "Initializing File Browser database (no default credentials)"
  fb_cli config init --database /config/database.db
  fb_cli config set --database /config/database.db \
    --address 0.0.0.0 \
    --port 80 \
    --root /srv \
    --auth.method json \
    --signup=false
  # Disable command/shell execution entirely
  fb_cli config set --database /config/database.db --commands="" || true

  log "Creating admin user '${FB_USER}'"
  fb_cli users add "${FB_USER}" "${FB_PASS}" --perm.admin --database /config/database.db
else
  log "Database exists — syncing admin password from .env"
  if ! fb_cli users update "${FB_USER}" -p "${FB_PASS}" --database /config/database.db 2>/dev/null; then
    log "Admin missing — creating '${FB_USER}'"
    fb_cli users add "${FB_USER}" "${FB_PASS}" --perm.admin --database /config/database.db
  fi
fi

fix_perms "${FB_DIR}"
fix_perms "${UPLOADS_DIR}"
log "Init complete"
