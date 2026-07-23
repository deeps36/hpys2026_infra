# File Browser init — root cause & supported method (v2.32.0)

## Root cause of CLI hang

```text
docker exec hpys-filebrowser /filebrowser users ls --database=/database.db
→ Using database: /database.db
→ timeout
```

File Browser does **not** use SQLite for `database.db`. It uses **BoltDB**.

BoltDB allows **only one process** to open the DB for writing. The running server holds an exclusive lock for its lifetime. A second process (`users ls`, `users add`, `users update`, `config cat`, …) waits for the lock and then fails with **`timeout`**.

This is documented behaviour in upstream issues ([#846](https://github.com/filebrowser/filebrowser/issues/846), [#3013](https://github.com/filebrowser/filebrowser/issues/3013), [#2456](https://github.com/filebrowser/filebrowser/issues/2456)). It is **not** a PATH bug and **not** a wrong `--database` path.

So:

| Situation | CLI against `/database.db` |
|-----------|----------------------------|
| Server running (`hpys-filebrowser` up) | **Hangs / timeout** |
| Server stopped | Supported |
| Ephemeral `docker run` mounting DB while server still up | **Hangs** (same host file) |

## Are `users ls|add|update` still supported on v2.32.0?

**Yes.** Official CLI docs still list:

- https://filebrowser.org/cli/filebrowser-users
- https://filebrowser.org/cli/filebrowser-users-add

They are intended for offline / stopped-server administration, not for concurrent use with a live server.

## Supported initialization (HPYS)

| Phase | Method |
|-------|--------|
| First run (no `filebrowser/database.db`) | Stop container → CLI `config init` + `users add` (timeout-wrapped) |
| Subsequent deploys (DB exists) | **No CLI** — skip user recreate |
| After healthy | REST `POST /api/login` to verify `.env` admin (warn-only on mismatch) |
| Password reset | Web UI, or **stop** service then CLI `users update` |

## Deploy policy

- Init / admin mismatch → **warning**, deploy continues
- File Browser container **unhealthy** or HTTP UI not serving → **fail** deploy

## Files

- `scripts/init-filebrowser.sh` — first-run CLI only; skip if DB exists
- `scripts/ensure-filebrowser-admin.sh` — REST login check
- `deploy.sh` — soft-fail init + login smoke; hard-fail only if service unhealthy
- `docs/FILE_BROWSER.md` — ops notes
