#!/usr/bin/env bash
# =============================================================================
# HPYS production deploy — run on the Oracle Cloud server from /opt/hpys
# Usage: ./deploy.sh
#
# Layout:
#   /opt/hpys              ← clone of hpys2026_infra
#   /opt/hpys/frontend     ← clone of hpys2026_frontend
#   /opt/hpys/backend      ← clone of hpys2026_backend
#
# Default: external Hostinger MySQL (COMPOSE_PROFILES empty → no mysql container)
# Bundled MySQL: COMPOSE_PROFILES=local-mysql and DB_HOST=mysql
#
# Idempotent Git sync (never `git pull`):
#   fetch → checkout main → reset --hard origin/main → clean -fd
# If this script is outdated on the VM, bootstrap once:
#   cd /opt/hpys && git fetch origin && git checkout -f main && \
#   git reset --hard origin/main && ./deploy.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

FRONTEND_DIR="./frontend"
BACKEND_DIR="./backend"
IMAGE_TAG="${IMAGE_TAG:-latest}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-180}"
AUTO_ROLLBACK="${AUTO_ROLLBACK:-1}"
# Always set under `set -u`. Empty = external MySQL (no compose profiles).
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
HPYS_DEPLOY_RESYNC="${HPYS_DEPLOY_RESYNC:-}"
DEPLOY_LOG="${ROOT_DIR}/data/logs/deploy.log"
HAD_PREVIOUS=0
val=""
v=""


mkdir -p data/logs
exec > >(tee -a "${DEPLOY_LOG}") 2>&1

read_env() {
  local key="$1"
  local val=""
  if [[ -f .env ]]; then
    val="$(grep -E "^${key}=" .env | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    val="${val%\"}"
    val="${val#\"}"
    val="${val%\'}"
    val="${val#\'}"
  fi
  printf '%s' "${val}"
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

log() { echo "==> $*"; }
err() { echo "ERROR: $*" >&2; }

uses_local_mysql() {
  [[ "${COMPOSE_PROFILES:-}" == *"local-mysql"* ]]
}

if [[ -f .env ]]; then
  val="$(read_env FRONTEND_DIR)"; [[ -n "${val}" ]] && FRONTEND_DIR="${val}"
  val="$(read_env BACKEND_DIR)";  [[ -n "${val}" ]] && BACKEND_DIR="${val}"
  val="$(read_env IMAGE_TAG)";    [[ -n "${val}" ]] && IMAGE_TAG="${val}"
  val="$(read_env DEPLOY_BRANCH)"; [[ -n "${val}" ]] && DEPLOY_BRANCH="${val}"
  # Empty COMPOSE_PROFILES= in .env is valid (external MySQL)
  COMPOSE_PROFILES="$(trim "$(read_env COMPOSE_PROFILES)")"
fi
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

log "HPYS deploy starting in ${ROOT_DIR}"
date -u '+%Y-%m-%dT%H:%M:%SZ'
log "host=$(hostname) arch=$(uname -m) docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"

if [[ ! -f .env ]]; then
  err ".env not found. Copy .env.example to .env and configure secrets."
  exit 1
fi

if [[ ! -f docker-compose.yml ]]; then
  err "docker-compose.yml not found in ${ROOT_DIR}"
  exit 1
fi

if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "arm64" ]]; then
  log "WARNING: expected ARM64 host (got $(uname -m)); images are platform: linux/arm64"
fi

DB_HOST_VAL="$(read_env DB_HOST)"
DB_PORT_VAL="$(read_env DB_PORT)"
DB_PORT_VAL="${DB_PORT_VAL:-3306}"

if uses_local_mysql; then
  if grep -qE 'CHANGE_ME_' .env; then
    err ".env still contains CHANGE_ME_ placeholders. Replace them before deploying."
    exit 1
  fi
  if [[ -z "$(read_env MYSQL_ROOT_PASSWORD)" ]]; then
    err "COMPOSE_PROFILES includes local-mysql but MYSQL_ROOT_PASSWORD is missing"
    exit 1
  fi
  if [[ -z "${DB_HOST_VAL}" || "${DB_HOST_VAL}" == "mysql" ]]; then
    :
  else
    log "WARNING: local-mysql profile set but DB_HOST=${DB_HOST_VAL} (expected mysql for in-compose DB)"
  fi
  log "Local MySQL profile enabled (COMPOSE_PROFILES=${COMPOSE_PROFILES:-})"
else
  # External MySQL — COMPOSE_PROFILES empty must not start mysql container
  if grep -E 'CHANGE_ME_' .env | grep -vE '^[[:space:]]*#|^[[:space:]]*MYSQL_ROOT_PASSWORD=' | grep -qE 'CHANGE_ME_'; then
    err ".env still contains CHANGE_ME_ placeholders. Replace them before deploying."
    exit 1
  fi
  if [[ -z "${DB_HOST_VAL}" ]]; then
    err "DB_HOST is required for external MySQL (example: srv1953.hstgr.io)"
    exit 1
  fi
  if [[ "${DB_HOST_VAL}" == "mysql" ]]; then
    err "DB_HOST=mysql requires COMPOSE_PROFILES=local-mysql. For Hostinger set DB_HOST=srv1953.hstgr.io and leave COMPOSE_PROFILES empty."
    exit 1
  fi
  if [[ "${DB_HOST_VAL}" =~ ^https?:// ]]; then
    err "DB_HOST must be a MySQL hostname/IP (e.g. srv1953.hstgr.io), not a website URL."
    exit 1
  fi
  log "External MySQL mode (COMPOSE_PROFILES empty). DB_HOST=${DB_HOST_VAL}:${DB_PORT_VAL}"
fi

for required in VITE_API_BASE_URL VITE_BACKEND_URL DB_PASSWORD DB_DATABASE DB_USERNAME; do
  if [[ -z "$(read_env "${required}")" ]]; then
    err "Missing required .env value: ${required}"
    exit 1
  fi
done

# Vite URLs must be public HTTP(S) app URLs, not the MySQL hostname
for vite_key in VITE_API_BASE_URL VITE_BACKEND_URL; do
  v="$(read_env "${vite_key}")"
  if [[ "${v}" == *"hstgr.io"* ]] || [[ "${v}" == *"srv1953"* ]]; then
    err "${vite_key} points at MySQL host (${v}). Use your public site URL (Cloudflare/Oracle domain)."
    exit 1
  fi
done

chmod 600 .env || true
mkdir -p data/uploads data/backups data/logs
if uses_local_mysql; then
  mkdir -p data/mysql mysql
fi

if command -v sudo >/dev/null 2>&1; then
  sudo chown -R 1001:1001 data/uploads data/logs 2>/dev/null \
    || chown -R 1001:1001 data/uploads data/logs 2>/dev/null \
    || true
else
  chown -R 1001:1001 data/uploads data/logs 2>/dev/null || true
fi

# Force every clone to match origin/<branch> exactly.
# Never uses `git pull` (fails when there is no upstream / diverged history).
# `git clean -fd` does NOT remove ignored paths (.env, data/*, frontend/, backend/).
sync_repo() {
  local dir="$1"
  local label="$2"
  local branch="${DEPLOY_BRANCH:-main}"

  if [[ ! -d "${dir}/.git" ]]; then
    if [[ -d "${dir}" ]]; then
      err "${label} at ${dir} exists but is not a git repo"
    else
      err "${label} directory missing: ${dir}"
    fi
    exit 1
  fi

  log "Syncing ${label} → origin/${branch} (fetch + hard reset)"
  git -C "${dir}" fetch origin --prune
  # Create local main if needed; -f discards local modifications on switch
  if git -C "${dir}" show-ref --verify --quiet "refs/heads/${branch}"; then
    git -C "${dir}" checkout -f "${branch}"
  else
    git -C "${dir}" checkout -B "${branch}" "origin/${branch}"
  fi
  git -C "${dir}" reset --hard "origin/${branch}"
  git -C "${dir}" clean -fd
  log "  ${label} @ $(git -C "${dir}" rev-parse --short HEAD) ($(git -C "${dir}" log -1 --pretty=%s))"
}

# Re-exec once after infra sync so this run uses the latest deploy.sh / compose from Git
if [[ "${HPYS_DEPLOY_RESYNC:-}" != "1" ]]; then
  if [[ -d "${ROOT_DIR}/.git" ]]; then
    sync_repo "${ROOT_DIR}" "infra"
  fi
  export HPYS_DEPLOY_RESYNC=1
  # Preserve optional env across re-exec (empty string is intentional)
  export COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
  export DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
  export IMAGE_TAG="${IMAGE_TAG:-latest}"
  log "Re-executing deploy.sh from synced infra tree"
  exec bash "${ROOT_DIR}/deploy.sh" "$@"
fi

sync_repo "${FRONTEND_DIR}" "frontend"
sync_repo "${BACKEND_DIR}" "backend"

if [[ ! -f "${FRONTEND_DIR}/Dockerfile" ]]; then
  err "Frontend Dockerfile missing at ${FRONTEND_DIR}/Dockerfile"
  exit 1
fi
if [[ ! -f "${BACKEND_DIR}/Dockerfile" ]]; then
  err "Backend Dockerfile missing at ${BACKEND_DIR}/Dockerfile"
  exit 1
fi

# Preflight: TCP reachability to external MySQL (Hostinger must allow Oracle egress IP)
if ! uses_local_mysql; then
  log "Checking TCP connectivity to ${DB_HOST_VAL}:${DB_PORT_VAL}"
  if timeout 8 bash -c "echo >/dev/tcp/${DB_HOST_VAL}/${DB_PORT_VAL}" 2>/dev/null; then
    log "MySQL port is reachable"
  else
    err "Cannot reach ${DB_HOST_VAL}:${DB_PORT_VAL} from this host."
    err "On Hostinger: enable Remote MySQL and allow this Oracle server public IP."
    err "On Oracle VCN: allow egress TCP/3306 to Hostinger."
    exit 1
  fi
fi

log "Snapshotting current images as :previous (if present)"
if docker image inspect "hpys-frontend:${IMAGE_TAG:-latest}" >/dev/null 2>&1; then
  docker tag "hpys-frontend:${IMAGE_TAG:-latest}" hpys-frontend:previous
  HAD_PREVIOUS=1
fi
if docker image inspect "hpys-backend:${IMAGE_TAG:-latest}" >/dev/null 2>&1; then
  docker tag "hpys-backend:${IMAGE_TAG:-latest}" hpys-backend:previous
  HAD_PREVIOUS=1
fi

# Run docker compose with a clean child env: unset COMPOSE_PROFILES when empty so
# Compose does not treat a blank export as an active profile list.
compose() {
  if [[ -n "${COMPOSE_PROFILES:-}" ]]; then
    env IMAGE_TAG="${IMAGE_TAG:-latest}" COMPOSE_PROFILES="${COMPOSE_PROFILES}" \
      docker compose "$@"
  else
    env -u COMPOSE_PROFILES IMAGE_TAG="${IMAGE_TAG:-latest}" \
      docker compose "$@"
  fi
}

rollback() {
  if [[ "${AUTO_ROLLBACK:-1}" != "1" || "${HAD_PREVIOUS:-0}" != "1" ]]; then
    log "Auto-rollback skipped (AUTO_ROLLBACK=${AUTO_ROLLBACK:-1}, HAD_PREVIOUS=${HAD_PREVIOUS:-0})"
    return 1
  fi
  err "Deploy unhealthy — attempting automatic rollback to :previous"
  docker tag hpys-frontend:previous "hpys-frontend:${IMAGE_TAG:-latest}" || true
  docker tag hpys-backend:previous "hpys-backend:${IMAGE_TAG:-latest}" || true
  compose up -d --remove-orphans || true
  sleep 5
  compose ps || true
  return 0
}

export IMAGE_TAG="${IMAGE_TAG:-latest}"
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1
# Always keep COMPOSE_PROFILES bound in this shell (set -u). Empty means no profiles.
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"

log "Building images (tag=${IMAGE_TAG:-latest})"
compose build --pull

log "Starting containers with force-recreate (profiles=${COMPOSE_PROFILES:-<none>})"
compose up -d --force-recreate --remove-orphans

# Ensure mysql container is NOT running in external mode
if ! uses_local_mysql; then
  if docker ps --format '{{.Names}}' | grep -qx 'hpys-mysql'; then
    log "Stopping leftover local mysql container (external DB mode)"
    env -u COMPOSE_PROFILES docker compose --profile local-mysql stop mysql 2>/dev/null || docker stop hpys-mysql 2>/dev/null || true
    env -u COMPOSE_PROFILES docker compose --profile local-mysql rm -f mysql 2>/dev/null || docker rm -f hpys-mysql 2>/dev/null || true
  fi
fi

WAIT_SERVICES=(backend frontend)
if uses_local_mysql; then
  WAIT_SERVICES=(mysql backend frontend)
fi

log "Waiting for services to become healthy: ${WAIT_SERVICES[*]} (timeout ${HEALTH_TIMEOUT_SEC:-180}s)"
deadline=$((SECONDS + HEALTH_TIMEOUT_SEC))
all_healthy=0
while (( SECONDS < deadline )); do
  all_healthy=1
  for svc in "${WAIT_SERVICES[@]}"; do
    cid="$(compose ps -q "${svc}" 2>/dev/null || true)"
    if [[ -z "${cid}" ]]; then
      all_healthy=0
      break
    fi
    running="$(docker inspect --format='{{.State.Running}}' "${cid}" 2>/dev/null || echo false)"
    if [[ "${running}" != "true" ]]; then
      all_healthy=0
      break
    fi
    status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || echo missing)"
    if [[ "${status}" != "healthy" ]]; then
      all_healthy=0
      break
    fi
  done
  if (( all_healthy == 1 )); then
    log "All required services healthy"
    break
  fi
  sleep 5
done

if (( all_healthy != 1 )); then
  err "Services did not become healthy within ${HEALTH_TIMEOUT_SEC:-180}s"
  compose ps || true
  compose logs --tail=100 || true
  rollback || true
  err "Manual rollback (if needed):"
  echo "  docker tag hpys-frontend:previous hpys-frontend:${IMAGE_TAG:-latest}"
  echo "  docker tag hpys-backend:previous  hpys-backend:${IMAGE_TAG:-latest}"
  echo "  IMAGE_TAG=${IMAGE_TAG:-latest} docker compose up -d"
  exit 1
fi

log "Post-deploy verification (localhost)"
http_code() {
  local method="${1:-GET}"
  local url="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -X "${method}" "${url}" || printf '000'
  else
    wget -S -T 15 -O /dev/null --method="${method}" "${url}" 2>&1 | awk '/HTTP\// {print $2; exit}' || printf '000'
  fi
}

verify_health() {
  local url="http://127.0.0.1:8000/health"
  local code
  code="$(http_code GET "${url}")"
  if [[ "${code}" != "200" ]]; then
    err "VERIFY FAIL ${url} → HTTP ${code} (expected 200)"
    exit 1
  fi
  log "  OK GET ${url} → HTTP ${code}"
}

# Route must exist. Accept 2xx/4xx/5xx except 404/000 (DB may return 500; upload without file → 400).
verify_route() {
  local method="$1"
  local url="$2"
  local code
  code="$(http_code "${method}" "${url}")"
  if [[ -z "${code}" || "${code}" == "000" || "${code}" == "404" ]]; then
    err "VERIFY FAIL ${method} ${url} → HTTP ${code:-none} (route missing or unreachable)"
    exit 1
  fi
  log "  OK ${method} ${url} → HTTP ${code}"
}

if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 5 "http://127.0.0.1:8080/" >/dev/null || {
    err "VERIFY FAIL frontend http://127.0.0.1:8080/"
    exit 1
  }
else
  wget -q -T 5 -O /dev/null "http://127.0.0.1:8080/" || {
    err "VERIFY FAIL frontend http://127.0.0.1:8080/"
    exit 1
  }
fi

verify_health
verify_route GET "http://127.0.0.1:8000/api/reels"
verify_route POST "http://127.0.0.1:8000/api/reels/upload"
log "Post-deploy verification passed"

log "Container status"
compose ps

log "Removing dangling images (keeps :previous and current tags)"
docker image prune -f

log "Deploy finished successfully at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
compose ps
