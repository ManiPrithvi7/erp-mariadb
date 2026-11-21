# Deploying this on Render

Deploy **second**: `erpnext-redis` should already exist, and `erpnext-app` needs this service's
hostname to be created at all. Same project, same region as the other two — private networking is
same-project, same-region only.

## 1. Create the service

Dashboard → New → **Blueprint** → connect `ManiPrithvi7/erpnext-db`. Two secrets are prompted
(`sync: false` in `render.yaml`):

| variable | notes |
|---|---|
| `MARIADB_PASSWORD` | what the app connects as. Changeable later — see §5 |
| `MARIADB_ROOT_PASSWORD` | used only while the datadir is empty; nothing needs it afterwards, and the reconciler deliberately does not depend on it |

`MARIADB_DATABASE=erpnext` and `MARIADB_USER=erpnext` are plain values in the file.

## 2. Why the database has to own port 10000 (X9)

A `pserv` has no `ports:` field in the [Blueprint spec](https://render.com/docs/blueprint-spec)
and its health check is **TCP connect to the primary port** — there is no HTTP path to probe and
no way to say "check 3306". So MariaDB listens on `$PORT`, i.e. 10000, via
`--port=10000` in `dockerCommand`. The app reaches it at `erpnext-db-<4char>:10000`.

`dockerCommand` replaces the image `CMD`; the `ENTRYPOINT` in the Dockerfile stays, which is what
lets our script see the server flags, prepend `mariadbd` when the first token starts with `-`
(exactly like upstream does) and append `--init-file=…`. Overriding `dockerCommand` with
something like `mariadbd --skip-grant-tables` would still go through the entrypoint, so keep any
dashboard edits to real server flags.

## 3. The flags

```
--port=10000
--character-set-server=utf8mb4
--collation-server=utf8mb4_unicode_ci
--skip-character-set-client-handshake
--skip-innodb-read-only-compressed
--innodb-buffer-pool-size=768M
```

The charset trio is what ERPNext expects (and what the parent project's compose used) —
`skip-character-set-client-handshake` forces it regardless of what a client asks for, which is the
only reliable way to stop a `bench` invocation from creating latin1 columns.
`skip-innodb-read-only-compressed` is needed because Frappe ships migrations that create
`ROW_FORMAT=COMPRESSED` tables and MariaDB 10.6 defaults `innodb_read_only_compressed=ON`.

`--innodb-buffer-pool-size` is the one number worth tuning: the default 128 MB is too small for
`bench migrate`, and a 2 GB instance cannot hold much more than ~768 MB with the OS and
connections. **X8** is the experiment that measures the OOM threshold and the wall-clock effect
instead of guessing; until it reports, treat 768M as a starting point, not a result.

Note there is no `${...}` in this file on purpose: Blueprint values are **literal** (only
`{fromEnv}`, `{fromService}`, `{fromDatabase}` interpolate), so the buffer pool is edited here and
redeployed, not overridden from the env.

## 4. The disk

- **Must exist on the first deploy.** Adding it later mounts an empty volume over
  `/var/lib/mysql`; the entrypoint then sees no `mysql` system schema, treats it as a fresh
  datadir and *helpfully* re-creates everything from env — which looks like a successful boot and
  is actually an empty database where your data used to be.
- Grow-only, no shrink. Snapshotted daily with 7-day retention; those snapshots are **not
  exportable** and die with the service.
- **Deleting the service deletes the disk.** There is no detach step and no recycle bin.
- A disk disables zero-downtime deploys, hence `autoDeployTrigger: off`.
- `numInstances: 1`, no autoscaling: a second instance gets its own empty disk, which is
  split-brain, not a replica.

`maxShutdownDelaySeconds: 300` matters more here than anywhere else in the stack. Render sends
SIGTERM and then waits; `docker/entrypoint.sh` forwards that signal to `mariadbd` (the upstream
script `exec`s it, so the pid we track really is the server), which is what turns a planned
restart into a clean InnoDB shutdown instead of a crash-recovery boot.

## 5. Rotating the application password

This is the flow the reconciling entrypoint exists to make safe:

1. Dashboard → `erpnext-db` → edit `MARIADB_PASSWORD` → save.
2. **Restart the database service.** The reconcile only runs at mariadbd startup — that is what
   `--init-file` means.
3. Then restart `erpnext-app`.

Order is not optional. If you change the secret and restart only the app, the app is holding a
credential the database has never seen. The database's log will not show anything, because it
never restarted.

What a correct run looks like:

```
[db-entrypoint] existing datadir - MARIADB_* would normally be ignored; handing them to mariadbd via --init-file
[db-entrypoint] verified: 'erpnext' authenticates with the password from env
```

`verified` is the entrypoint connecting as the app user with the env password over the socket —
the only test that answers the question the app is about to ask. `./scripts/rotate-test.sh`
automates the whole sequence locally, including the assertion that the *old* password stops
working.

Root is deliberately left out of the reconcile. Rotating `MARIADB_ROOT_PASSWORD` in the dashboard
changes nothing in a surviving datadir, and nothing in this stack needs root.

## 6. Copy the internal hostname, then verify

`erpnext-db-<4char>` on port `10000` goes into `proof-erpnext-app` as `DB_HOST`. From the app
service's **Shell** tab (`pymysql` is in the Frappe venv):

```python
import os, pymysql
c = pymysql.connect(host=os.environ["DB_HOST"], port=10000, user=os.environ["DB_USER"],
                    password=os.environ["DB_PASSWORD"], database=os.environ["DB_NAME"],
                    connect_timeout=5)
cur = c.cursor(); cur.execute("SELECT VERSION(), @@innodb_buffer_pool_size, @@character_set_server")
print(cur.fetchone())
```

## 7. Backups — the honest version

Render gives you daily disk snapshots that you cannot download and that vanish with the service,
so durability rests on dumps you pull yourself:

```bash
./scripts/backup.sh                    # mariadb-dump --single-transaction | gzip, written INTO the disk
./scripts/backup.sh --pull             # …and copy it off the container to ./backups
./scripts/restore.sh backups/erpnext-….sql.gz
```

Writing the dump inside `/var/lib/mysql/backups/` survives restarts and redeploys but not service
deletion or disk loss — which is the whole point of `--pull`. `restore.sh` also covers the
"restore into a brand-new service whose disk is empty" runbook, because that is the only path that
matters.

One cross-repo trap: Frappe's `encryption_key` — the symmetric key for every stored API secret and
OAuth token — lives in `sites/common_site_config.json` on the **app's** disk, not in the database.
A database-only restore into a fresh site therefore cannot decrypt the API keys it just restored,
unless `FRAPPE_ENCRYPTION_KEY` was pinned as a secret in `erpnext-app`. Pin it from the first
deploy; see [proof-erpnext-app/RENDER_DEPLOY.md](../proof-erpnext-app/RENDER_DEPLOY.md).

## 8. Swapping to a managed MariaDB

Render has no managed MariaDB and Frappe v16 has no PostgreSQL support, which is exactly why this
repo exists as a container. The swap is a `render.yaml` deletion, not a redesign: the app only
consumes `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` (plus the same values in
`sites/common_site_config.json`). Two things change: an external server needs TLS
(`rediss`-equivalent for MySQL — set `ssl_mode` in the site config), and the reconciling entrypoint
becomes someone else's problem, i.e. you are back to running `ALTER USER` by hand after a rotation.

## 9. Version changes

`FROM mariadb:10.6` is a moving minor-version target. A `docker compose build --pull` (or a Render
rebuild) can hand the same datadir to a newer 10.6.x, and upstream's entrypoint runs
`mariadb-upgrade` when it detects that the server is newer than the datadir — which is a
long, non-zero-downtime boot on a disk that also happens to be your only backup. Bump deliberately,
take a `--pull` backup first, and pin a digest if you want the build to be reproducible.
