#!/usr/bin/env bash
# Why this file exists (X11): the official MariaDB image only reads MARIADB_USER /
# MARIADB_PASSWORD / MARIADB_DATABASE while it is creating an empty datadir. Once
# $DATADIR/mysql exists it execs the server and never looks at them again. On Render that
# means editing DB_PASSWORD in the dashboard re-points the app at a credential the database
# was never told about, and the next restart of either service is an
# "Access denied for user 'erpnext'@'10.x.x.x'" outage - with the data perfectly intact.
#
# So: on a fresh disk let the image do its job and exec it. On every later boot, hand the server
# a SQL script that re-syncs the account with the env before anything can connect to it.
#
# Kept deliberately narrow: it reconciles the one account Frappe logs in as, and the schema that
# account needs. Root is left alone.
set -eo pipefail

UPSTREAM=/usr/local/bin/docker-entrypoint.sh
DATADIR="${MARIADB_DATA_DIR:-/var/lib/mysql}"
SOCKET="${MARIADB_SOCKET:-/run/mysqld/mysqld.sock}"
RECONCILE_SQL=/run/mysqld/render-reconcile.sql

log() { printf '[db-entrypoint] %s\n' "$*"; }

# Same normalisation upstream does: a leading flag means "these are server arguments".
if [[ "${1:-}" == -* || -z "${1:-}" ]]; then
  set -- mariadbd "$@"
fi

# What arrived on the command line, printed because that is the part a hand-created dashboard
# service silently loses. The port, the character set and the compressed-row flag are in
# /etc/mysql/conf.d/render.cnf instead, which travels inside the image, so plain
# `mariadbd --console` is a correct server rather than a misconfigured one (X9).
log "server args from the command: $*"

if [[ ! -d "$DATADIR/mysql" ]]; then
  # This boot is the only chance to create the account Frappe logs in as and the schema it opens:
  # the image reads MARIADB_USER / MARIADB_PASSWORD / MARIADB_DATABASE while the datadir is empty
  # and never again. Init without them and everything still looks fine - "ready for connections",
  # Render says live - while the app gets "Unknown database 'erpnext'" for the life of the disk.
  # The first Render deploy of this repo did exactly that, so refuse rather than start it.
  # The Dockerfile now supplies the two non-secret names, which leaves only the passwords that
  # genuinely cannot be baked in. (MARIADB_ROOT_PASSWORD is left to the image, which already
  # aborts without it.)
  missing=()
  for v in MARIADB_DATABASE MARIADB_USER MARIADB_PASSWORD; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} )); then
    log "FATAL: fresh datadir but the environment has no ${missing[*]}."
    log "       The database, user and schema are created from env on THIS boot only, and a"
    log "       datadir initialized without them cannot be given them later by the image."
    log "       On Render: dashboard -> this service -> Environment, scope Global (render.yaml"
    log "       sets all three). This disk is still empty, so setting them and redeploying loses"
    log "       nothing - which stops being true after the first successful boot."
    exit 1
  fi
  log "fresh datadir at $DATADIR - the image creates user '${MARIADB_USER}' and database '${MARIADB_DATABASE}' from env; nothing to reconcile"
  exec "$UPSTREAM" "$@"
fi

# Escape a value for use inside a single-quoted SQL string literal (backslash stays an escape
# character unless NO_BACKSLASH_ESCAPES is set, so it has to be doubled first).
sql_str() { local s=${1//\\/\\\\}; printf "%s" "${s//\'/\'\'}"; }

write_reconcile_sql() {
  local user pass db h
  user="$(sql_str "${MARIADB_USER:?}")"; pass="$(sql_str "${MARIADB_PASSWORD:?}")"
  db="${MARIADB_DATABASE:-}"

  printf '%s\n' "-- generated at boot from MARIADB_*; lives in tmpfs, never on the disk"
  if [ -n "$db" ]; then
    printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$(sql_str "$db")"
  fi
  # '%' is where Frappe connects from - another service on the private network - so it has to
  # exist even if this datadir was initialised with a different DB_USER, or only ever had
  # localhost. CREATE IF NOT EXISTS then ALTER IF EXISTS rather than CREATE OR REPLACE USER,
  # which MariaDB implements as DROP + CREATE and would take the grants with it.
  printf "CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\n" "$user" "$pass"
  printf "ALTER USER IF EXISTS '%s'@'%%' IDENTIFIED BY '%s';\n" "$user" "$pass"
  # Then the fixed-host accounts, so a stale password cannot survive on a path this container
  # is still reachable through. Listed instead of queried: with no credentials we cannot read
  # mysql.user from here, and these are the hosts the image ever creates.
  for h in localhost 127.0.0.1 ::1; do
    printf "ALTER USER IF EXISTS '%s'@'%s' IDENTIFIED BY '%s';\n" "$user" "$h" "$pass"
  done
  if [ -n "$db" ]; then
    printf "GRANT ALL PRIVILEGES ON \`%s\`.* TO '%s'@'%%';\n" "$(sql_str "$db")" "$user"
  fi
  printf 'FLUSH PRIVILEGES;\n'
}

# The obvious implementation was "start the server, then connect over the unix socket as root
# and run the ALTERs". It cannot work, and measuring it is part of X11:
#   * this image inits root with --auth-root-authentication-method=normal, so root@localhost is
#     plain mysql_native_password - there is no unix_socket plugin to lean on, only the password
#     chosen at the very first initdb, i.e. the credential a rotation may have just staled;
#   * the socket-auth account the image does support (mysql@localhost IDENTIFIED VIA
#     unix_socket) is only created when MARIADB_MYSQL_LOCALHOST_USER was set during initdb, so
#     it cannot be introduced into a datadir that is already built;
#   * every remaining path wants a password, which would make the reconciler depend on the very
#     thing it exists to repair.
# mariadbd --init-file is the one path that runs as superuser without authentication, during
# startup, before the server accepts a single connection. Two properties were probed locally
# before committing to it:
#   * a statement that fails is logged ("ERROR: 1146 ...") and the server still reaches
#     "ready for connections", with the statements before it applied - so a wrong guess cannot
#     turn a credential mismatch into an outage and the pass can stay unconditional;
#   * a file the server cannot open DOES abort startup ("Can't create/write to file ...
#     Aborting"), so who owns it and with what mode is load-bearing, not tidiness: upstream
#     re-execs through gosu, so mariadbd runs as the mysql user and opens it read/write.
# Skipping the pass is always safe - that is simply the stock image's behaviour. Aborting the
# server would not be, hence every failure below falls back to "start without --init-file".
stage_reconcile_sql() {
  local f="${RECONCILE_SQL}.$$"
  mkdir -p "${RECONCILE_SQL%/*}" 2>/dev/null || return 1
  write_reconcile_sql > "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  if [ "$(id -u)" = 0 ]; then
    chown mysql:mysql "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  elif [ "$(id -u)" != "$(id -u mysql 2>/dev/null || echo none)" ]; then
    rm -f "$f"; return 1
  fi
  chmod 600 "$f" 2>/dev/null || { rm -f "$f"; return 1; }
  mv -f "$f" "$RECONCILE_SQL" 2>/dev/null || { rm -f "$f"; return 1; }
  printf '%s' "$RECONCILE_SQL"
}

if [ -z "${MARIADB_USER:-}" ] || [ -z "${MARIADB_PASSWORD:-}" ]; then
  log "MARIADB_USER/MARIADB_PASSWORD are not both set - starting without a reconcile pass"
elif sql=$(stage_reconcile_sql); then
  set -- "$@" "--init-file=$sql"
  log "existing datadir - MARIADB_* would normally be ignored; handing them to mariadbd via --init-file"
else
  log "WARN: could not stage a mysql-owned $RECONCILE_SQL as uid $(id -u); starting unreconciled"
fi

"$UPSTREAM" "$@" &
server=$!

# Render stops with SIGTERM and waits maxShutdownDelaySeconds. Forwarding it is what buys a
# clean InnoDB shutdown; without it the disk only ever comes back through crash recovery.
# Upstream ends in `exec "$@"`, so this pid really is mariadbd.
trap 'kill -TERM "$server" 2>/dev/null || true' TERM INT

# Proof that the init-file did its job, using the only credential that matters: connect as the
# app user with the password from env. A file mariadbd could not open already said "Aborting" in
# the log; this catches the quieter failure, where the server came up and a statement inside the
# reconcile did not apply.
verify() {
  [ -n "${MARIADB_USER:-}" ] && [ -n "${MARIADB_PASSWORD:-}" ] || return 0
  local waited=0
  while [ ! -S "$SOCKET" ] && [ "$waited" -lt 180 ]; do sleep 1; waited=$((waited + 1)); done
  if [ ! -S "$SOCKET" ]; then
    log "WARN: no socket after ${waited}s; cannot verify the reconcile"
    return 0
  fi
  waited=0
  until mariadb --protocol=socket -S "$SOCKET" -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
        -e 'SELECT 1' >/dev/null 2>&1; do
    sleep 1; waited=$((waited + 1))
    if [ "$waited" -ge 30 ]; then
      log "WARN: '${MARIADB_USER}' still cannot connect with the password from env - the app will report Access denied until the secrets agree"
      return 0
    fi
  done
  log "verified: '${MARIADB_USER}' authenticates with the password from env"
}
verify

wait "$server"
