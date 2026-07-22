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
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

FRONTEND_DIR="./frontend"
BACKEND_DIR="./backend"
IMAGE_TAG="${IMAGE_TAG:-latest}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-180}"
AUTO_ROLLBACK="${AUTO_ROLLBACK:-1}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
DEPLOY_LOG="${ROOT_DIR}/data/logs/deploy.log"
HAD_PREVIOUS=0

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
  [[ "${COMPOSE_PROFILES}" == *"local-mysql"* ]]
}

if [[ -f .env ]]; then
  val="$(read_env FRONTEND_DIR)"; [[ -n "${val}" ]] && FRONTEND_DIR="${val}"
  val="$(read_env BACKEND_DIR)";  [[ -n "${val}" ]] && BACKEND_DIR="${val}"
  val="$(read_env IMAGE_TAG)";    [[ -n "${val}" ]] && IMAGE_TAG="${val}"
  val="$(trim "$(read_env COMPOSE_PROFILES)")"; COMPOSE_PROFILES="${val}"
fi

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
  log "Local MySQL profile enabled (COMPOSE_PROFILES=${COMPOSE_PROFILES})"
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

# Pull infra repo itself when /opt/hpys is a git clone of hpys2026_infra
if [[ -d "${ROOT_DIR}/.git" ]]; then
  log "Pulling latest infra code (${ROOT_DIR})"
  git -C "${ROOT_DIR}" pull --ff-only || log "WARNING: infra git pull failed — continuing with local files"
fi

pull_repo() {
  local dir="$1"
  local label="$2"
  if [[ -d "${dir}/.git" ]]; then
    log "Pulling latest ${label} code (${dir})"
    git -C "${dir}" pull --ff-only
  elif [[ -d "${dir}" ]]; then
    log "${label} at ${dir} is not a git repo — skipping pull"
  else
    err "${label} directory missing: ${dir}"
    exit 1
  fi
}

pull_repo "${FRONTEND_DIR}" "frontend"
pull_repo "${BACKEND_DIR}" "backend"

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
if docker image inspect "hpys-frontend:${IMAGE_TAG}" >/dev/null 2>&1; then
  docker tag "hpys-frontend:${IMAGE_TAG}" hpys-frontend:previous
  HAD_PREVIOUS=1
fi
if docker image inspect "hpys-backend:${IMAGE_TAG}" >/dev/null 2>&1; then
  docker tag "hpys-backend:${IMAGE_TAG}" hpys-backend:previous
  HAD_PREVIOUS=1
fi

rollback() {
  if [[ "${AUTO_ROLLBACK}" != "1" || "${HAD_PREVIOUS}" != "1" ]]; then
    log "Auto-rollback skipped (AUTO_ROLLBACK=${AUTO_ROLLBACK}, HAD_PREVIOUS=${HAD_PREVIOUS})"
    return 1
  fi
  err "Deploy unhealthy — attempting automatic rollback to :previous"
  docker tag hpys-frontend:previous "hpys-frontend:${IMAGE_TAG}" || true
  docker tag hpys-backend:previous "hpys-backend:${IMAGE_TAG}" || true
  if [[ -n "${COMPOSE_PROFILES}" ]]; then
    IMAGE_TAG="${IMAGE_TAG}" COMPOSE_PROFILES="${COMPOSE_PROFILES}" docker compose up -d --remove-orphans || true
  else
    IMAGE_TAG="${IMAGE_TAG}" docker compose up -d --remove-orphans || true
  fi
  sleep 5
  docker compose ps || true
  return 0
}

export IMAGE_TAG
export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

# Empty COMPOSE_PROFILES must be unset so Compose does not enable any profiles
if [[ -n "${COMPOSE_PROFILES}" ]]; then
  export COMPOSE_PROFILES
else
  unset COMPOSE_PROFILES || true
fi

log "Building images (tag=${IMAGE_TAG})"
docker compose build --pull

log "Starting containers (profiles=${COMPOSE_PROFILES:-<none>})"
docker compose up -d --remove-orphans

# Ensure mysql container is NOT running in external mode
if ! uses_local_mysql; then
  if docker ps --format '{{.Names}}' | grep -qx 'hpys-mysql'; then
    log "Stopping leftover local mysql container (external DB mode)"
    docker compose --profile local-mysql stop mysql 2>/dev/null || docker stop hpys-mysql 2>/dev/null || true
    docker compose --profile local-mysql rm -f mysql 2>/dev/null || docker rm -f hpys-mysql 2>/dev/null || true
  fi
fi

WAIT_SERVICES=(backend frontend)
if uses_local_mysql; then
  WAIT_SERVICES=(mysql backend frontend)
fi

log "Waiting for services to become healthy: ${WAIT_SERVICES[*]} (timeout ${HEALTH_TIMEOUT_SEC}s)"
deadline=$((SECONDS + HEALTH_TIMEOUT_SEC))
all_healthy=0
while (( SECONDS < deadline )); do
  all_healthy=1
  for svc in "${WAIT_SERVICES[@]}"; do
    cid="$(docker compose ps -q "${svc}" 2>/dev/null || true)"
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
  err "Services did not become healthy within ${HEALTH_TIMEOUT_SEC}s"
  docker compose ps || true
  docker compose logs --tail=100 || true
  rollback || true
  err "Manual rollback (if needed):"
  echo "  docker tag hpys-frontend:previous hpys-frontend:${IMAGE_TAG}"
  echo "  docker tag hpys-backend:previous  hpys-backend:${IMAGE_TAG}"
  echo "  IMAGE_TAG=${IMAGE_TAG} docker compose up -d"
  exit 1
fi

log "Smoke checks (localhost)"
if command -v curl >/dev/null 2>&1; then
  curl -fsS --max-time 5 "http://127.0.0.1:8080/" >/dev/null
  curl -fsS --max-time 5 "http://127.0.0.1:8000/health" >/dev/null
else
  wget -q -T 5 -O /dev/null "http://127.0.0.1:8080/"
  wget -q -T 5 -O /dev/null "http://127.0.0.1:8000/health"
fi
log "Smoke checks passed"

log "Container status"
docker compose ps

log "Removing dangling images (keeps :previous and current tags)"
docker image prune -f

log "Deploy finished successfully at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
docker compose ps
