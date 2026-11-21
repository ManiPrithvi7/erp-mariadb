# Deploying this on Render

Deploy **second**: `erpnext-redis` should already exist, and `erpnext-app` needs this service's
hostname to be created at all. Same project, same region as the other two — private networking is
same-project, same-region only.

## 1. Create the service

Dashboard → New → **Blueprint** → connect `ManiPrithvi7/erp-mariadb`. Two secrets are prompted
(`sync: false` in `render.yaml`):

| variable | notes |
|---|---|
| `MARIADB_PASSWORD` | what the app connects as. Changeable later — see §6 |
| `MARIADB_ROOT_PASSWORD` | used only while the datadir is empty; nothing needs it afterwards, and the reconciler deliberately does not depend on it |

`MARIADB_DATABASE=erpnext` and `MARIADB_USER=erpnext` are plain values in the file. If you create
the service by hand instead of from the Blueprint, **set all four** — see §4 for what happens when
you do not.

## 2. Why the database has to own port 10000 (X9)

A `pserv` has no `ports:` field in the [Blueprint spec](https://render.com/docs/blueprint-spec)
and its health check is **TCP connect to the primary port** — there is no HTTP path to probe and
no way to say "check 3306". So MariaDB listens on `$PORT`, i.e. 10000, and the app reaches it at
`erpnext-db-<4char>:10000`.

The port is set in `docker/render.cnf`, which the Dockerfile copies to
`/etc/mysql/conf.d/render.cnf`. Not in `dockerCommand`: the first Render deploy of this repo was a
hand-created service, which inherits no `dockerCommand` at all, and the settings that lived there
silently vanished while the deploy still went green. The official image's `/etc/mysql/my.cnf` ends
with `!includedir /etc/mysql/conf.d/`, so a file there outranks the Debian defaults — and anything
still passed on the command line outranks the file, which keeps `dockerCommand` usable.

`dockerCommand` replaces the image `CMD`; the `ENTRYPOINT` in the Dockerfile stays, which is what
lets our script see the server flags, prepend `mariadbd` when the first token starts with `-`
(exactly like upstream does) and append `--init-file=…`. Overriding `dockerCommand` with
something like `mariadbd --skip-grant-tables` would still go through the entrypoint, so keep any
dashboard edits to real server flags.

## 3. The settings, and where each one lives

In the image (`/etc/mysql/conf.d/render.cnf`), because correctness must not depend on a dashboard
field:

```ini
port = 10000
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
skip-character-set-client-handshake
skip-innodb-read-only-compressed
```

The charset trio is what ERPNext expects (and what the parent project's compose used) —
`skip-character-set-client-handshake` forces it regardless of what a client asks for, which is the
only reliable way to stop a `bench` invocation from creating latin1 columns. Measured against this
image: stock 10.6 gives `utf8mb4` / **`utf8mb4_general_ci`**, so the `collation-server` line is the
one that actually changes something; `port=10000` is likewise not a no-op.

`skip-innodb-read-only-compressed` is a no-op today, and is kept anyway. It matters because Frappe
creates tables with `ROW_FORMAT=COMPRESSED` and this variable makes `ALTER` on one a hard error —
but measured on `mariadb:10.6` (10.6.25/10.6.28) and `mariadb:11.4` (11.4.13), the compiled
default is already `FALSE`, `--verbose --help` agrees, and nothing in `/etc/mysql` sets it. It
stays because `frappe_docker` ships it and a future default flip would break `bench migrate` in a
way nobody would predict. Earlier drafts of this file claimed 10.6 defaults it to `ON`; that was
wrong and is now measured.

In `dockerCommand` (plan-dependent, so it must be editable per service):

```
--innodb-buffer-pool-size=768M
```

The default 128 MB — which is what the first deploy came up with, `total size = 134217728` in its
own log — is too small for `bench migrate`, and a 2 GB instance cannot hold much more than ~768 MB
with the OS and connections. **X8** is the experiment that measures the OOM threshold and the
wall-clock effect instead of guessing; until it reports, treat 768M as a starting point, not a
result.

Note there is no `${...}` in `render.yaml` on purpose: Blueprint values are **literal** (only
`{fromEnv}`, `{fromService}`, `{fromDatabase}` interpolate), so the buffer pool is edited in the
file and redeployed, not overridden from the env.

## 4. Private service — never a web service (X9, measured)

This repo's first Render deploy was created from the dashboard rather than the Blueprint, so it
came out as a **web** service with only `MARIADB_ROOT_PASSWORD` and `REDIS_URL`-style hand-typed
variables. Both problems are visible in its own log, and neither produced a failed deploy:

```
==> Setting WEB_CONCURRENCY=1 by default, based on available CPUs in the instance
[db-entrypoint] fresh datadir at /var/lib/mysql - the image creates '<none>' from env; nothing to reconcile
[Note] InnoDB: Initializing buffer pool, total size = 134217728, chunk size = 134217728
[Note] mariadbd: ready for connections.
Version: '10.6.28-MariaDB-ubu2204'  socket: '/run/mysqld/mysqld.sock'  port: 10000
2026-11-21 11:19:09 3 [Warning] Aborted connection 3 to db: 'unconnected' user: 'unauthenticated' host: '127.0.0.1' (This connection closed normally without authentication)
2026-11-21 11:19:10 4 [Warning] Aborted connection 4 to db: 'unconnected' user: 'unauthenticated' host: '127.0.0.1' (This connection closed normally without authentication)
==> Your service is live 🎉
==> Available at your primary URL https://erp-mariadb.onrender.com
```

- **`'<none>'` is an empty database behind a green deploy.** `MARIADB_USER`/`MARIADB_DATABASE`
  were never set, so the image created a server with no Frappe account and no `erpnext` schema,
  printed "ready for connections", and Render called it live. The app's first request would be
  `Unknown database 'erpnext'` — for the life of that disk, because the image only reads those
  variables while the datadir is empty. `docker/entrypoint.sh` now refuses to start a fresh
  datadir without all three (`FATAL: fresh datadir but the environment has no …`) instead of
  producing this. Rotating `MARIADB_PASSWORD` later is still safe; it is only the *first* boot
  that is unrepeatable.
- **Once a second, forever, from `127.0.0.1`:** that is Render's in-instance HTTP port scanner
  (the same thing that spam-attacked Redis — see
  [proof-erpnext-redis/RENDER_DEPLOY.md](../proof-erpnext-redis/RENDER_DEPLOY.md)). It opens the
  socket, sends nothing MariaDB can parse as a handshake, and closes. Each probe is one
  `Aborted connection … user: 'unauthenticated'` warning. `10.213.27.85` in the same log is the
  platform's TCP health probe from inside the instance network — that one is expected and correct
  on a private service, at ~5 s intervals and in pairs (IPv4 + IPv6).
- A `web` service also gets a public URL for a database. `erp-mariadb.onrender.com` answers
  nothing useful, but it is a real hostname on the internet pointing at 10000.

So: create a **Private Service**, name it `erpnext-db` (the service name, not the repo name), give
it the disk at creation time, and set all four `MARIADB_*` variables. Render will not change a
service's type afterwards — the only way out is to delete the service, which deletes its disk.

### Connection checks are TCP-only, never `ping`

Per the rule above, nothing in this stack authenticates to test reachability:

- **Render** cannot do otherwise — a `pserv` probes by connecting to the primary port.
- **The compose healthcheck** is a bare `/dev/tcp` open
  (`timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/10000'`), which is exactly the same question.
  `mariadb-admin ping` is the obvious command and the wrong one: it authenticates, so it fails for
  reasons that have nothing to do with reachability, and it puts the root password in
  `docker inspect`.
- **The app's own wait** (`proof-erpnext-app/docker/entrypoint.sh` → `wait_tcp`, and `/readyz`'s
  `_tcp_open`) is a socket connect for the same reason. Only after the socket is open does
  Frappe dial it with a real credential.

Consequence to accept rather than alert on: a TCP-only probe is indistinguishable, in the
database's eyes, from a client that gives up mid-handshake. `Aborted_connects` climbs by one per
probe, and the log fills with `closed normally without authentication` warnings. That is the
health check working. It is noise in this design, not a symptom — if you ever watch
`Aborted_connects`, watch it for *bursts beyond* the probe interval, not for being non-zero.

## 5. The disk

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
