# HPYS 2026 — Production Deployment

Oracle Cloud **ARM64** Ubuntu 24.04 · Docker Compose · Hostinger remote MySQL · Host Nginx · Cloudflare

This document is the single source of truth for reproducing production **without manual edits on the VM**.

---

## Architecture

```
Internet
  → Cloudflare (HTTPS)
    → Host Nginx :443
         ├─ /              → 127.0.0.1:8080   hpys-frontend (nginx SPA)
         ├─ /api/*         → 127.0.0.1:8000   hpys-backend  (Express + Socket.IO)
         ├─ /uploads/*     → 127.0.0.1:8000
         ├─ /socket.io/*   → 127.0.0.1:8000
         └─ /health        → 127.0.0.1:8000/health

Optional API vhost (api26.hpys.in):
  entire host → 127.0.0.1:8000

Docker Compose (default — Hostinger MySQL):
  frontend + backend only
  COMPOSE_PROFILES empty  →  mysql container NOT started

MySQL (Hostinger Remote):
  srv1953.hstgr.io:3306
  9 schemas: main, metadata, reels_1..6, profile_img
```

### Critical Express mounts (do not regress)

| Mount | Router | Public paths |
|-------|--------|--------------|
| `/api` | auth, user | `/api/request_otp`, … |
| `/api/reels` | reels | **`/api/reels`**, `/api/reels/upload`, `/api/reels/job/:id`, `/api/reels/init` |
| `/reels` | reels | dual mount (subdirectory / API-host without extra prefix) |
| `/health` | app.js | healthcheck JSON |

**Bug that broke production:** mounting reels at `app.use('/api', reelsRoutes)` exposed `/api/upload` instead of `/api/reels/upload`. Fixed permanently in `hpys2026_backend/src/app.js`.

### Upload limits (must stay aligned)

| Layer | Limit |
|-------|-------|
| Multer (`reelsRoutes.js`) | **500 MB** |
| Express JSON | 100 MB |
| Host Nginx `client_max_body_size` | **500 M** |
| Backend container memory | **2048 m** (in-memory uploads) |

---

## Repositories (server layout)

| Role | GitHub | Path on server |
|------|--------|----------------|
| Infra | `https://github.com/deeps36/hpys2026_infra.git` | `/opt/hpys` |
| Frontend | `https://github.com/avddev369/hpys2026_frontend.git` | `/opt/hpys/frontend` |
| Backend | `https://github.com/avddev369/hpys2026_backend.git` | `/opt/hpys/backend` |

Prefer `main` on all three after merges (Dockerfiles + this routing fix).
`deploy.sh` checks out `DEPLOY_BRANCH` (default **`main`**) for frontend and backend on every run.

---

## Environment variables

Copy `/opt/hpys/.env.example` → `/opt/hpys/.env` (`chmod 600`). Never bake secrets into images.

### Frontend (Compose build args)

| Variable | Required value shape |
|----------|----------------------|
| `VITE_API_BASE_URL` | Public API base **including `/api`**, e.g. `https://api26.hpys.in/api` |
| `VITE_BACKEND_URL` | Origin for Socket.IO, e.g. `https://api26.hpys.in` |

Frontend code calls `` `${VITE_API_BASE_URL}/reels` `` → must resolve to `/api/reels`.

### Backend (runtime via Compose `environment:`)

| Group | Variables |
|-------|-----------|
| Core | `NODE_ENV=production`, `PORT=8000` |
| Main MySQL | `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` (+ optional `LOCAL_DB_*` / `PROD_DB_*`) |
| Reels | `REELS_DB_COUNT=6`, `REELS_DB_LIMIT_BYTES`, `REELS_METADATA_DB_*`, `REELS_DB_1_*` … `REELS_DB_6_*` |
| Profile images | `PROFILE_DB_*` |
| SMTP | `SMTP_*` |
| WhatsApp | `WHATSAPP_*` |
| Optional S3 | `AWS_REGION`, `AWS_S3_BUCKET_NAME`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |

**Hostinger:** allow-list the Oracle **public IP** under Remote MySQL. Egress TCP **3306** from the VCN.

`REELS_DB_COUNT` defaults to **10** in code if unset — always set `6` in `.env`.

---

## Deployment steps (fresh server)

### 1. Docker (ARM64)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git
# Install Docker Engine + Compose plugin for Ubuntu arm64 (see README_DEPLOYMENT.md)
uname -m   # must be aarch64
```

### 2. Clone

```bash
sudo mkdir -p /opt/hpys && sudo chown "$USER":"$USER" /opt/hpys
cd /opt/hpys
git clone https://github.com/deeps36/hpys2026_infra.git .
git clone https://github.com/avddev369/hpys2026_frontend.git frontend
git clone https://github.com/avddev369/hpys2026_backend.git backend
git -C frontend checkout main
git -C backend checkout main
```

### 3. Env + data dirs

```bash
cp .env.example .env && chmod 600 .env
# Edit .env — Hostinger hosts/names/users/passwords; COMPOSE_PROFILES=
mkdir -p data/{uploads,logs,backups,mysql}
sudo chown -R 1001:1001 data/uploads data/logs
```

### 4. Host Nginx

```bash
sudo cp /opt/hpys/nginx/hpys-host.conf /etc/nginx/sites-available/hpys
# Edit YOUR_DOMAIN + SSL paths
sudo ln -sf /etc/nginx/sites-available/hpys /etc/nginx/sites-enabled/hpys
sudo nginx -t && sudo systemctl reload nginx
```

### 5. Deploy (rebuilds containers from Git)

```bash
cd /opt/hpys
./deploy.sh
```

`deploy.sh` pulls infra + app repos, builds images, waits for health, smoke-tests `/`, `/health`, `/api/reels`, `/api/reels/upload`.

---

## Rollback steps

Automatic: `deploy.sh` tags `:previous` before rebuild and rolls back if health/smoke fails.

Manual:

```bash
cd /opt/hpys
docker tag hpys-frontend:previous hpys-frontend:latest
docker tag hpys-backend:previous  hpys-backend:latest
IMAGE_TAG=latest docker compose up -d
curl -fsS http://127.0.0.1:8000/health
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/api/reels
```

Git rollback:

```bash
cd /opt/hpys/backend && git fetch && git checkout <known-good-sha>
cd /opt/hpys && ./deploy.sh
```

---

## Post-deployment verification

```bash
# Health
curl -fsS http://127.0.0.1:8000/health
# Expect: {"status":"healthy",...}

# Reels list (200 with data, or 500 if DB ACL — must NOT be 404)
curl -sS -o /tmp/reels.json -w '%{http_code}\n' http://127.0.0.1:8000/api/reels

# Upload route exists (expect 4xx without multipart — not 404)
curl -sS -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8000/api/reels/upload

# Init tables (optional once)
curl -sS http://127.0.0.1:8000/api/reels/init

# Via host Nginx / Cloudflare
curl -fsS https://YOUR_DOMAIN/health
curl -sS -o /dev/null -w '%{http_code}\n' https://api26.hpys.in/api/reels

docker compose ps
docker compose logs backend --tail=80 | grep -E 'Reels|Profile|healthy|✗|✓'
```

Success criteria:

- `GET /health` → **200**
- `GET /api/reels` → **not 404** (200 when MySQL reachable)
- `POST /api/reels/upload` → **not 404**

---

## Troubleshooting checklist

| Symptom | Check |
|---------|--------|
| `Route /api/reels not found` / HTTP 404 | Backend image missing mount fix — pull latest backend, `./deploy.sh` |
| `Route /api/upload` works but `/api/reels/upload` 404 | Old buggy mount still deployed |
| Frontend calls `…/reels` on wrong host | `VITE_API_BASE_URL` missing `/api` — fix `.env`, rebuild frontend |
| `ER_ACCESS_DENIED` / Hostinger | Allow-list Oracle public IP; verify user/password/DB name |
| Upload 413 | Host Nginx `client_max_body_size` &lt; 500M — use `nginx/hpys-host.conf` |
| Upload OOM / killed | Raise backend `mem_limit` (Compose already 2048m) |
| Backend unhealthy | `docker compose logs backend`; DB connectivity; `/health` |
| `hpys-mysql` running unexpectedly | `COMPOSE_PROFILES` must be empty for Hostinger |
| Upload EACCES | `sudo chown -R 1001:1001 /opt/hpys/data/uploads` |
| Socket.IO fails | Nginx `/socket.io/` upgrade headers; `VITE_BACKEND_URL` origin |
| Drift after manual VM edit | **Never edit running containers** — change Git, redeploy |

---

## Production invariants (prevent drift)

1. **No manual `docker exec` / `sed` on VM app code** — change Git, run `./deploy.sh`.
2. Reels always mounted at **`/api/reels`** (+ `/reels`).
3. `VITE_API_BASE_URL` always ends with **`/api`**.
4. Nginx body size **500M**; multer **500MB**.
5. Health at **`GET /health`** (Compose + Dockerfile healthchecks).
6. CORS `origin: '*'`; `trust proxy` enabled for Cloudflare/Nginx.
7. External MySQL only unless `COMPOSE_PROFILES=local-mysql`.
