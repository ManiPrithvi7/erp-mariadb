# proof-erpnext-db

MariaDB 10.6 as a Render **private service**, with one file added to the official image: an
entrypoint that keeps the application password in sync with the environment on every boot
instead of only on the first one.

Second of the three sibling repos to deploy — after
[`proof-erpnext-redis`](../proof-erpnext-redis), before
[`proof-erpnext-app`](../proof-erpnext-app). Stack-wide findings are in
[proof-erpnext-app/LIMITATIONS.md](../proof-erpnext-app/LIMITATIONS.md).

## The problem, in one paragraph

The official image honours `MARIADB_USER` / `MARIADB_PASSWORD` / `MARIADB_DATABASE` **only while
it is creating an empty datadir**. Once `/var/lib/mysql/mysql` exists it execs the server and
never reads them again. On a PaaS where the secret lives in a dashboard, that means editing
`DB_PASSWORD` re-points the app at a credential the database has never been told about, and the
next restart of either service is an `Access denied for user 'erpnext'@'10.x.x.x'` outage with the
data perfectly intact. This is `X11`, and it is the entire reason this repo is not just
`image: mariadb:10.6`.

## The fix, and why it is not the obvious one

The obvious implementation — start the server, connect over the unix socket as root, run the
`ALTER USER`s — does not work in this image:

- the image runs `mariadb-install-db --auth-root-authentication-method=normal`, so
  `root@localhost` is plain `mysql_native_password`. There is no `unix_socket` auth to lean on,
  only the password chosen at the very first initdb — i.e. the credential a rotation may have
  just staled;
- the socket-auth account the image *does* support (`mysql@localhost IDENTIFIED VIA unix_socket`)
  is created only when `MARIADB_MYSQL_LOCALHOST_USER` was set during initdb, so it cannot be
  introduced into a datadir that already exists;
- every remaining path wants a password, which would make the reconciler depend on the thing it
  exists to repair.

So `docker/entrypoint.sh` generates an idempotent SQL script from the env and passes it as
**`mariadbd --init-file=…`**, which MariaDB executes as superuser without authentication, during
startup, before it accepts a connection. Two properties of `--init-file` were measured before
committing to it (both reproducible; see `RENDER_DEPLOY.md` §4):

| probe | result | consequence |
|---|---|---|
| a statement in the file fails | `[ERROR] 1146 …` in the log, server reaches `ready for connections`, earlier statements stay applied | the reconcile can never brick the database, so it stays unconditional |
| the file is not openable by the daemon | `[ERROR] Can't create/write to file … [ERROR] Aborting` — server does **not** start | ownership/mode are load-bearing; the entrypoint falls back to "start without the flag" on any staging failure |

The file lives in `/run/mysqld` (tmpfs, `mysql:mysql`, `0600`) so it never touches the disk and
never contains anything the dashboard does not already have.

## Local

```bash
docker compose up -d          # fresh volume: the stock image does the creating
./scripts/rotate-test.sh      # X11 in isolation - currently 5 passed, 0 failed
./scripts/backup.sh           # mariadb-dump --single-transaction into the disk
./scripts/restore.sh <file>   # restore, including into a brand-new empty service
```

`rotate-test.sh` rotates `DB_PASSWORD` in `.env`, force-recreates the container, and asserts the
new secret authenticates, the **old one is rejected** (which is what proves the `ALTER USER`
actually ran rather than the password having coincidentally matched), and a second no-op restart
still recognises the datadir.

## Files

| path | what it is |
|---|---|
| `Dockerfile` | `FROM mariadb:10.6` + the entrypoint + `MARIADB_DATA_DIR` |
| `docker/entrypoint.sh` | fresh-vs-existing datadir branch, `--init-file` reconcile, SIGTERM forwarding, post-boot verification |
| `docker-compose.yml` | same image, same server flags, port 10000, named volume |
| `render.yaml` | `pserv`, `1c-2g`, 10 GB disk at `/var/lib/mysql`, `dockerCommand` with the utf8mb4/buffer-pool flags |
| `scripts/rotate-test.sh` | X11 |
| `scripts/backup.sh` / `scripts/restore.sh` | the only real backup story, since Render's snapshots die with the service |
| `RENDER_DEPLOY.md` | deploy order, port 10000, disk rules, the two probes above, swap-to-managed-MariaDB |

## Read next

- [RENDER_DEPLOY.md](RENDER_DEPLOY.md)
