# HPYS File Browser

Production web file manager for shared media under `/opt/hpys/uploads`.

## URL

| Item | Value |
|------|--------|
| Public URL | **https://files.hpys.in** |
| Local (server) | `http://127.0.0.1:8081` |
| Container | `hpys-filebrowser` |

## Login

| Field | Value |
|-------|--------|
| Username | `admin` (or `FILEBROWSER_USERNAME` from `/opt/hpys/.env`) |
| Password | `FILEBROWSER_PASSWORD` from `/opt/hpys/.env` |

`deploy.sh` prints the username/password at the end of a successful deploy.

**Never use File Browser’s default `admin`/`admin` password.** On first deploy, init creates the admin from `.env`. Later deploys do **not** rewrite the password via CLI (BoltDB lock); change it in the UI or stop the service and use CLI (below).

## BoltDB lock (why CLI prints `timeout`)

`database.db` is **BoltDB**, not SQLite. Only one process may open it. While `hpys-filebrowser` is running:

```bash
docker exec hpys-filebrowser /filebrowser users ls --database=/database.db
# → Using database: /database.db
# → timeout
```

That is expected. Official `users ls|add|update` commands are still supported on **v2.32.0**, but **only with the server stopped** (or against a DB copy). See `docs/FILEBROWSER_INIT.md`.

## Folder structure

Host path (also mounted into the HPYS backend as `/app/uploads`):

```
/opt/hpys/uploads/
├── reels/      ← app reel videos (NEW uploads; streamed by Express)
├── users/
├── profile/
└── temp/
```

**Reels:** metadata stays in MySQL (`reels_metadata`); video files for new uploads are on disk under `reels/`. Legacy BLOB rows in shard DBs still play until migrated/deleted.

File Browser root is `/srv` → `/opt/hpys/uploads`. The app cannot browse outside this tree.

Config / state:

```
/opt/hpys/filebrowser/
├── database.db      # users & settings (Git-ignored)
├── settings.json    # from Git
└── branding.json    # from Git
```

## Nginx / TLS

Host Nginx vhost for `files.hpys.in` is in `nginx/hpys-host.conf`:

- HTTPS redirect
- `client_max_body_size` from `.env` **`UPLOAD_MAX_SIZE`** (default **`20G`**; `0` = unlimited)
- Proxies to `127.0.0.1:8081` (compose binds loopback only)

Install / refresh:

```bash
sudo cp /opt/hpys/nginx/hpys-host.conf /etc/nginx/sites-available/hpys
sudo ln -sf /etc/nginx/sites-available/hpys /etc/nginx/sites-enabled/hpys
# Point DNS files.hpys.in → Oracle public IP (Cloudflare orange/grey cloud as preferred)
sudo nginx -t && sudo systemctl reload nginx
```

Optional dedicated Let's Encrypt cert:

```bash
sudo certbot certonly --nginx -d files.hpys.in
# then edit the files.hpys.in server block to use
# /etc/letsencrypt/live/files.hpys.in/fullchain.pem + privkey.pem
```

## Backup

```bash
# Config + user DB
sudo tar -C /opt/hpys -czf "/opt/hpys/data/backups/filebrowser-$(date +%Y%m%d).tgz" filebrowser

# Media tree (large)
sudo tar -C /opt/hpys -czf "/opt/hpys/data/backups/uploads-$(date +%Y%m%d).tgz" uploads
```

Keep backups off-box (object storage / another region).

## Restore

```bash
cd /opt/hpys
docker compose stop filebrowser
sudo tar -C /opt/hpys -xzf /opt/hpys/data/backups/filebrowser-YYYYMMDD.tgz
sudo tar -C /opt/hpys -xzf /opt/hpys/data/backups/uploads-YYYYMMDD.tgz
sudo chown -R 1001:33 /opt/hpys/uploads /opt/hpys/filebrowser
docker compose up -d filebrowser
```

## Add users

**Stop File Browser first** (releases BoltDB lock), then use an ephemeral CLI container — never `docker exec` on the live server:

```bash
cd /opt/hpys
docker compose stop filebrowser
docker run --rm --user 1001:33 \
  -v /opt/hpys/filebrowser:/config \
  filebrowser/filebrowser:v2.32.0 \
  users add NEWUSER 'StrongPasswordHere' --perm.admin --database /config/database.db
docker compose up -d filebrowser
```

Or use **Settings → User Management** in the web UI while logged in as admin (preferred while the service is up).

## Change password

1. Prefer the web UI (Settings → User Management), **or**
2. Update `FILEBROWSER_PASSWORD` in `/opt/hpys/.env` for documentation, then:

```bash
cd /opt/hpys
docker compose stop filebrowser
docker run --rm --user 1001:33 \
  -v /opt/hpys/filebrowser:/config \
  filebrowser/filebrowser:v2.32.0 \
  users update admin -p 'NewStrongPassword' --database /config/database.db
docker compose up -d filebrowser
```

`./deploy.sh` verifies login via REST after start; a password mismatch is a **warning**, not a deploy failure (as long as the File Browser service is healthy).

## Upgrade

1. Bump `FILEBROWSER_IMAGE` in `.env` (e.g. `filebrowser/filebrowser:v2.32.0`)
2. `cd /opt/hpys && ./deploy.sh`

Compose pulls the new image. First-run CLI init runs only if `database.db` is missing; existing DBs are left alone. Admin is checked via REST after the service is healthy.

## Security notes

- Login required (`signup: false`)
- HTTPS only via host Nginx + HSTS
- Root jailed to `/opt/hpys/uploads` (`--root=/srv`)
- Command/shell execution disabled at init (`--commands=""`)
- No public publish: container port bound to `127.0.0.1:8081` only
- `no-new-privileges`, dropped capabilities

## Permissions

Deploy sets ownership `1001:33` (backend user : `www-data`) with group write + setgid on directories so Docker and the host can write without EACCES.
