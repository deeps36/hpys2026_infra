# HPYS 2026 — Production Deployment Guide

**Oracle Cloud ARM64 (Ubuntu 24.04) + Docker Compose + Hostinger remote MySQL + Host Nginx + Cloudflare**

---

## Repositories

| Role | Repo | Cloned on server as |
|------|------|---------------------|
| Infra (compose, deploy, env template) | `https://github.com/deeps36/hpys2026_infra.git` | `/opt/hpys` |
| Frontend | `https://github.com/avddev369/hpys2026_frontend.git` | `/opt/hpys/frontend` |
| Backend | `https://github.com/avddev369/hpys2026_backend.git` | `/opt/hpys/backend` |

---

## Architecture

```
Internet → Cloudflare HTTPS → Host Nginx :443
                               ├─ /           → 127.0.0.1:8080  (frontend)
                               ├─ /api        → 127.0.0.1:8000  (backend)
                               ├─ /uploads    → 127.0.0.1:8000
                               └─ /socket.io  → 127.0.0.1:8000

Docker Compose (default):
  frontend  — static SPA (nginx)
  backend   — Express + Socket.IO (Node 22)

MySQL:
  Hostinger remote  srv1953.hstgr.io:3306
  (local mysql container is NOT started — profile local-mysql is opt-in only)
```

| Item | Value |
|------|--------|
| Frontend build args | `VITE_API_BASE_URL`, `VITE_BACKEND_URL` (public HTTPS site) |
| Backend port | `8000` |
| Health | `GET /health` |
| Uploads | `./data/uploads` → `/app/uploads` |
| `COMPOSE_PROFILES` empty | only `frontend` + `backend` |

---

## Hostinger requirements (do these first)

1. **Remote MySQL** enabled in hPanel.
2. **Allow Oracle server public IP** under Remote MySQL access (otherwise TCP/3306 is refused).
3. Note all database names / users / passwords (main, metadata, reels_1..6, profile_img).
4. Confirm hostname is `srv1953.hstgr.io` and port `3306`.
5. MySQL host is **not** `https://lightgrey-falcon-908132.hostingersite.com` (that is the old API URL).

---

## Oracle VCN / firewall

- Ingress: **80**, **443** (and SSH).
- Egress: allow **TCP 3306** to Hostinger (`srv1953.hstgr.io`).
- Do **not** publish Docker ports 8000/8080 publicly (bound to `127.0.0.1` only).

---

## Exact commands — Oracle server (start → running)

### 1) Install Docker (Ubuntu 24.04 ARM64)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git

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
# log out and SSH back in
uname -m          # must be aarch64
docker version
docker compose version
```

### 2) Create `/opt/hpys` and clone three repos

```bash
sudo mkdir -p /opt/hpys
sudo chown "$USER":"$USER" /opt/hpys
cd /opt/hpys

git clone https://github.com/deeps36/hpys2026_infra.git .
git clone https://github.com/avddev369/hpys2026_frontend.git frontend
git clone https://github.com/avddev369/hpys2026_backend.git backend

# Prefer branches that include Dockerfiles (main after merge, or awa1.1)
git -C frontend checkout main
git -C backend checkout main
```

### 3) Create `.env` for Hostinger MySQL

```bash
cd /opt/hpys
cp .env.example .env
chmod 600 .env
nano .env
```

**Must set (no `CHANGE_ME_` left except optional unused keys):**

```env
COMPOSE_PROFILES=

FRONTEND_DIR=./frontend
BACKEND_DIR=./backend

# Public site served from THIS Oracle box (Cloudflare domain)
VITE_API_BASE_URL=https://YOUR_DOMAIN/api
VITE_BACKEND_URL=https://YOUR_DOMAIN

DB_HOST=srv1953.hstgr.io
DB_PORT=3306
DB_DATABASE=u914595671_hpys_db
DB_USERNAME=u914595671_hpys_db
DB_PASSWORD=<real Hostinger password>

# Same host for shards — use your real Hostinger DB names/users/passwords
LOCAL_DB_HOST=srv1953.hstgr.io
PROD_DB_HOST=srv1953.hstgr.io
REELS_METADATA_DB_HOST=srv1953.hstgr.io
REELS_DB_1_HOST=srv1953.hstgr.io
REELS_DB_2_HOST=srv1953.hstgr.io
REELS_DB_3_HOST=srv1953.hstgr.io
REELS_DB_4_HOST=srv1953.hstgr.io
REELS_DB_5_HOST=srv1953.hstgr.io
REELS_DB_6_HOST=srv1953.hstgr.io
PROFILE_DB_HOST=srv1953.hstgr.io
```

Also fill SMTP / WhatsApp / optional AWS from your secrets.

### 4) Permissions + scripts

```bash
cd /opt/hpys
chmod +x deploy.sh backup.sh
mkdir -p data/uploads data/backups data/logs
sudo chown -R 1001:1001 data/uploads data/logs
```

### 5) Preflight MySQL from the Oracle host

```bash
# Replace with your Oracle public IP check on Hostinger allow-list first
curl -s ifconfig.me; echo

# TCP test to Hostinger
timeout 8 bash -c 'echo >/dev/tcp/srv1953.hstgr.io/3306' && echo OK || echo FAIL
```

### 6) Deploy

```bash
cd /opt/hpys
./deploy.sh
```

`deploy.sh` will:

- reject `DB_HOST=mysql` unless `local-mysql` profile is set  
- reject website URLs as `DB_HOST`  
- unset empty `COMPOSE_PROFILES` (mysql container stays off)  
- build ARM64 images, start **frontend + backend only**  
- wait for healthy, smoke-test `/` and `/health`  

### 7) Verify containers

```bash
docker compose ps
# Expect: hpys-frontend, hpys-backend  — NO hpys-mysql

curl -sS http://127.0.0.1:8080/ | head
curl -sS http://127.0.0.1:8000/health
docker compose logs --tail=80 backend
```

### 8) Host Nginx + TLS

```bash
sudo apt-get install -y nginx
sudo nano /etc/nginx/sites-available/hpys
```

Use the site config in § Host Nginx below, then:

```bash
sudo ln -sf /etc/nginx/sites-available/hpys /etc/nginx/sites-enabled/hpys
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Install Cloudflare Origin Certificate (or certbot) at the paths referenced in the Nginx config.

### 9) Cloudflare

- DNS A/AAAA → Oracle public IP (proxied)
- SSL/TLS: **Full (strict)**
- WebSockets: **On**

### 10) Ongoing updates

```bash
cd /opt/hpys
./deploy.sh
```

---

## Host Nginx example

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name YOUR_DOMAIN;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name YOUR_DOMAIN;

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

---

## Backup / restore (external MySQL)

```bash
./backup.sh
```

Uses `mysqldump` via `mysql:8.0.43` client container against `DB_HOST` (per-database credentials).

Restore is done with Hostinger tools / `mysql` client against `srv1953.hstgr.io` (not via `hpys-mysql` container).

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Cannot reach srv1953.hstgr.io:3306` | Whitelist Oracle public IP in Hostinger Remote MySQL; check VCN egress |
| Backend unhealthy / DB errors | Check `.env` DB names/users/passwords; `docker compose logs backend` |
| `DB_HOST=mysql` rejected | Leave `COMPOSE_PROFILES` empty for Hostinger |
| Frontend calls wrong API | Fix `VITE_*`, rebuild (`./deploy.sh`) |
| `hpys-mysql` still running | `./deploy.sh` stops it in external mode; or `docker rm -f hpys-mysql` |
| Upload EACCES | `sudo chown -R 1001:1001 /opt/hpys/data/uploads` |

```bash
docker compose ps
docker inspect --format='{{.State.Health.Status}}' hpys-backend
docker compose logs -f backend
```

---

## Security notes

- Secrets only in `/opt/hpys/.env` (`chmod 600`)
- App ports bound to `127.0.0.1`
- Backend non-root uid `1001`
- `read_only` rootfs + `cap_drop` on app containers
- Local `mysql` service requires explicit `COMPOSE_PROFILES=local-mysql`
