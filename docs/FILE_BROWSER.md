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

**Never use File Browser’s default `admin`/`admin` password.** Init always sets the password from `.env`.

## Folder structure

Host path (also mounted into the HPYS backend as `/app/uploads`):

```
/opt/hpys/uploads/
├── reels/
├── users/
├── profile/
└── temp/
```

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

```bash
docker run --rm --user 1001:33 \
  -v /opt/hpys/filebrowser:/config \
  filebrowser/filebrowser:v2.31.3 \
  users add NEWUSER 'StrongPasswordHere' --database /config/database.db
```

Grant admin:

```bash
docker run --rm --user 1001:33 \
  -v /opt/hpys/filebrowser:/config \
  filebrowser/filebrowser:v2.31.3 \
  users update NEWUSER --perm.admin --database /config/database.db
```

Or use **Settings → User Management** in the web UI while logged in as admin.

## Change password

1. Update `FILEBROWSER_PASSWORD` in `/opt/hpys/.env`
2. Re-run `./deploy.sh` (init syncs the admin password), **or**:

```bash
docker run --rm --user 1001:33 \
  -v /opt/hpys/filebrowser:/config \
  filebrowser/filebrowser:v2.31.3 \
  users update admin -p 'NewStrongPassword' --database /config/database.db
```

## Upgrade

1. Bump `FILEBROWSER_IMAGE` in `.env` (e.g. `filebrowser/filebrowser:v2.32.0`)
2. `cd /opt/hpys && ./deploy.sh`

Compose pulls the new image, reinits/syncs admin, and recreates `hpys-filebrowser`.

## Security notes

- Login required (`signup: false`)
- HTTPS only via host Nginx + HSTS
- Root jailed to `/opt/hpys/uploads` (`--root=/srv`)
- Command/shell execution disabled at init (`--commands=""`)
- No public publish: container port bound to `127.0.0.1:8081` only
- `no-new-privileges`, dropped capabilities

## Permissions

Deploy sets ownership `1001:33` (backend user : `www-data`) with group write + setgid on directories so Docker and the host can write without EACCES.
