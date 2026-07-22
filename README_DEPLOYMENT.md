# HPYS 2026 — Production Deployment Guide

Oracle Cloud **ARM64** · Ubuntu 24.04 · Docker Engine · Docker Compose · Host Nginx · Cloudflare · HTTPS

---

## 1. Architecture overview

```
Internet → Cloudflare (HTTPS/CDN) → Host Nginx (443/80)
                                      ├─ /          → 127.0.0.1:8080  (frontend container, nginx)
                                      ├─ /api       → 127.0.0.1:8000  (backend Express + Socket.IO)
                                      ├─ /uploads   → 127.0.0.1:8000
                                      └─ /socket.io → 127.0.0.1:8000  (WebSocket upgrade)

Docker Compose services:
  frontend  — React 19 / Vite 6 static SPA (multi-stage build)
  backend   — Express 5 / Node 22 / Socket.IO (non-root uid 1001)
  mysql     — MySQL 8.0.43 (ARM64), not published to the host

Networks:
  frontend-network — frontend + backend
  backend-network  — backend + mysql
```

| Item | Value |
|------|--------|
| Frontend build | `npm ci` → `npm run build` (Vite) |
| Frontend env (build-time) | `VITE_API_BASE_URL`, `VITE_BACKEND_URL` (required) |
| Backend start | `node src/server.js` |
| Backend port | `8000` |
| Uploads | `/app/uploads` → URL `/uploads` |
| Health probe | `GET /health` (JSON `{ status: "healthy" }`) |
| Databases | `hpys_db`, `hpys_reels_metadata`, `hpys_reels_db_1..6`, `hpys_profile_img` |

---

## 2. Server requirements

- Oracle Cloud **Ampere (ARM64)** shape
- Ubuntu **24.04 LTS**
- ≥ 2 OCPU, ≥ 4 GB RAM (8 GB+ recommended with reels BLOBs)
- ≥ 50 GB block volume
- VCN security list: **80**, **443** only (do not expose 3306/8000/8080 publicly)
- Domain DNS via Cloudflare (proxied)

---

## 3. Install Docker (Ubuntu 24.04 ARM64)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker "$USER"
# log out / back in
docker version
docker compose version
uname -m   # must print aarch64
```

---

## 4. Host directory layout

```text
/opt/hpys
├── docker-compose.yml
├── .env
├── .env.example
├── deploy.sh
├── backup.sh
├── README_DEPLOYMENT.md
├── mysql/
│   └── init-databases.sh
├── frontend/
├── backend/
└── data/
    ├── mysql/
    ├── uploads/
    ├── backups/
    └── logs/
```

### Initial setup

```bash
sudo mkdir -p /opt/hpys
sudo chown "$USER":"$USER" /opt/hpys
cd /opt/hpys

# Place infra files here, then:
git clone <FRONTEND_GIT_URL> frontend
git clone <BACKEND_GIT_URL>  backend

cp .env.example .env
nano .env   # replace every CHANGE_ME_* value; set public VITE_* URLs
chmod 600 .env
chmod +x deploy.sh backup.sh mysql/init-databases.sh

mkdir -p data/mysql data/uploads data/backups data/logs
# Backend container runs as uid 1001
sudo chown -R 1001:1001 data/uploads data/logs
```

**Monorepo note:**

```env
FRONTEND_DIR=./hpys2026_frontend
BACKEND_DIR=./hpys2026_backend
```

---

## 5. Environment variables

1. `FRONTEND_DIR` / `BACKEND_DIR` / `IMAGE_TAG`
2. `VITE_API_BASE_URL` / `VITE_BACKEND_URL` (baked at **image build** time)
3. `MYSQL_ROOT_PASSWORD`, `DB_PASSWORD` (required — compose fails closed if missing)
4. Reels/profile DB names (hosts stay `mysql` inside Compose)
5. SMTP + WhatsApp (runtime only)

`deploy.sh` refuses to run while `CHANGE_ME_` placeholders remain in `.env`.

After changing `VITE_*`, rebuild the frontend image.

---

## 6. Database bootstrap

### Bundled MySQL (Compose profile `local-mysql`)

In `.env`:

```env
COMPOSE_PROFILES=local-mysql
DB_HOST=mysql
MYSQL_ROOT_PASSWORD=...
DB_PASSWORD=...
```

On first MySQL start (empty `data/mysql`):

1. Image creates `MYSQL_USER` / `MYSQL_DATABASE`
2. `mysql/init-databases.sh` creates all HPYS schemas and grants to `$MYSQL_USER`
3. Backend auto-creates reels/profile **tables**
4. Import main schema/data:

```bash
docker exec -i hpys-mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" hpys_db < backend/database.sql
```

> Init scripts run **only** on an empty data directory.

### External MySQL (Hostinger / managed)

Do **not** set `COMPOSE_PROFILES=local-mysql`. Point hosts at the remote server (hostname/IP — not an `https://` URL):

```env
# COMPOSE_PROFILES=   (leave unset/empty)
DB_HOST=your-mysql-hostname-or-ip
DB_PORT=3306
# set matching REELS_*_HOST / PROFILE_DB_HOST if they differ
```

Then `docker compose up -d` starts only `frontend` + `backend`.

---

## 7. Deploy

```bash
cd /opt/hpys
./deploy.sh
```

What it does:

1. Blocks on placeholder / missing secrets; logs to `data/logs/deploy.log`
2. Warns if host is not ARM64
3. `git pull --ff-only` (when `.git` exists)
4. Tags current images as `:previous` **before** rebuild
5. Builds with BuildKit (`DOCKER_BUILDKIT=1`)
6. `docker compose up -d` and waits until **mysql, backend, frontend** are `healthy`
7. Smoke-tests `http://127.0.0.1:8080/` and `:8000/`
8. On failure: auto-rollback to `:previous` (disable with `AUTO_ROLLBACK=0`)
9. Prunes dangling layers only after success (keeps `:previous`)

Verify:

```bash
docker compose ps
curl -sS http://127.0.0.1:8080/ | head
curl -sS http://127.0.0.1:8000/health
```

---

## 8. Host Nginx (reverse proxy) + Cloudflare

```bash
sudo apt-get install -y nginx
```

Example `/etc/nginx/sites-available/hpys`:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name your-domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name your-domain.com;

    ssl_certificate     /etc/ssl/hpys/origin.pem;
    ssl_certificate_key /etc/ssl/hpys/origin.key;

    client_max_body_size 100M;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_request_buffering off;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400;
    }

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

> Ubuntu 24.04 ships Nginx ≥ 1.24. If `http2 on;` is rejected, use `listen 443 ssl http2;` instead.

```bash
sudo ln -sf /etc/nginx/sites-available/hpys /etc/nginx/sites-enabled/hpys
sudo nginx -t && sudo systemctl reload nginx
```

**Cloudflare:** proxied DNS, SSL mode **Full (strict)**, Origin Certificate, **WebSockets** enabled.

---

## 9. Update process

```bash
cd /opt/hpys
./deploy.sh
```

---

## 10. Rollback process

`deploy.sh` snapshots running images to `:previous` before each build.

**Application rollback (no DB change):**

```bash
cd /opt/hpys
# Do NOT run docker compose down -v
docker tag hpys-frontend:previous hpys-frontend:latest
docker tag hpys-backend:previous  hpys-backend:latest
docker compose up -d
docker compose ps
```

**Code rollback then rebuild:**

```bash
git -C frontend checkout <good-sha>
git -C backend  checkout <good-sha>
./deploy.sh
```

**Database rollback:** restore a backup (section 12). Always restore DB + matching uploads when possible.

---

## 11. Backup

```bash
./backup.sh
```

Produces:

- `/opt/hpys/data/backups/hpys_all_YYYYMMDD_HHMMSS.sql.gz` (all HPYS schemas)
- `/opt/hpys/data/backups/hpys_uploads_YYYYMMDD_HHMMSS.tar.gz` (when uploads exist)

Validates the dump contains `Dump completed`, writes via temp+rename, `chmod 600`, retains **30 days**.

```bash
crontab -e
15 2 * * * /opt/hpys/backup.sh >> /opt/hpys/data/logs/backup.log 2>&1
```

---

## 12. Restore

**Stop writers first** to avoid mixed state:

```bash
cd /opt/hpys
docker compose stop backend frontend

# Restore databases
gunzip -c data/backups/hpys_all_YYYYMMDD_HHMMSS.sql.gz \
  | docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" hpys-mysql \
      mysql -uroot

# Restore uploads (optional but recommended)
sudo rm -rf data/uploads/*
sudo tar -C data/uploads -xzf data/backups/hpys_uploads_YYYYMMDD_HHMMSS.tar.gz
sudo chown -R 1001:1001 data/uploads

docker compose start backend frontend
docker compose ps
```

---

## 13. Logs

```bash
docker compose logs -f --tail=200
docker compose logs -f backend
sudo tail -f /var/log/nginx/error.log
```

Container logs are rotated (`max-size=20m`, `max-file=5`).

---

## 14. Troubleshooting

| Symptom | Checks |
|---------|--------|
| Frontend shows old API host | Rebuild after `VITE_*` change; purge Cloudflare cache |
| `VITE_* is required` at compose up | Set both vars in `.env` |
| Backend unhealthy | `docker compose logs backend`; MySQL healthy?; uploads owned by 1001 |
| MySQL healthcheck flapping | Password special chars OK via `CMD-SHELL`; check `docker compose logs mysql` |
| Init DBs missing | Init runs only on empty `data/mysql` |
| 502 from host Nginx | `ss -lntp \| grep -E '8080\|8000'` |
| Socket.IO fails | Upgrade headers + Cloudflare WebSockets |
| Camera / QR scanner blocked | Frontend nginx `Permissions-Policy` must allow `camera=(self)` |
| Upload EACCES | `sudo chown -R 1001:1001 data/uploads` |
| ARM pull/build errors | `uname -m` → `aarch64`; images use `platform: linux/arm64` |

```bash
docker compose ps
docker inspect --format='{{.State.Health.Status}}' hpys-backend
docker exec -it hpys-mysql mysql -uhpys -p -e 'SHOW DATABASES;'
```

---

## 15. Security notes

- `.env` mode `600`; never commit secrets
- Backend does **not** receive `MYSQL_ROOT_PASSWORD` (explicit env only)
- MySQL not published; app ports bound to `127.0.0.1`
- Backend non-root (`hpys` / 1001)
- `no-new-privileges`, `cap_drop: ALL` (frontend re-adds only nginx-required caps)
- Frontend + backend `read_only: true` with `tmpfs` for writable paths
- MySQL `./data/backups` mount is **read-only** (host `backup.sh` writes archives)
- Uploads owned by uid `1001` on the host
- Frontend nginx: `server_tokens off` + security headers on all locations
- `deploy.sh` refuses `CHANGE_ME_` placeholders and auto-rollbacks to `:previous` on failed health

---

## 16. Performance notes

- Multi-stage images; pinned `node:22.23.1-alpine`, `nginx:1.27.5-alpine`, `mysql:8.0.43`
- BuildKit npm cache mounts; `pull_policy: build` for app images
- Compose-native `cpus` / `mem_limit` (not Swarm `deploy.resources`)
- Log rotation; Vite `/assets/` immutable cache; gzip (+ wasm); nginx `open_file_cache`
- MySQL `max_allowed_packet=512M`, configurable InnoDB buffer pool
- `init: true` + graceful stop periods

---

## 17. Future recommendations

1. Optionally add DB readiness to `GET /health` (ping MySQL)
2. Tag images with git SHA (`IMAGE_TAG=$(git rev-parse --short HEAD)`)
3. Restrict Socket.IO / CORS origins away from `*`
4. Prefer OCI/S3 object storage for media (S3 already wired on `awa1.1`; configure `AWS_*`)
5. Off-host backup sync (OCI Object Storage / S3)
6. Rotate any credentials that ever lived in historical `env.production` files
