#!/usr/bin/env bash
# mysqldump written INTO the data directory, because that is the only path Render keeps.
#
#   ./scripts/backup.sh                    # -> /var/lib/mysql/backups/<db>-<stamp>.sql.gz
#   ./scripts/backup.sh --pull ./backups   # also copy it off the box
#
# Why off-box matters (RENDER_DEPLOY.md): Render snapshots disks daily with 7-day retention,
# snapshots are not exportable, and they are deleted with the service. A dump you never pulled
# down is a backup of one disk, not of your data.
#
# --single-transaction keeps InnoDB consistent without a lock, so ERPNext stays writable.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f .env ]] && set -a && . ./.env && set +a

DB="${DB_NAME:-erpnext}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="/var/lib/mysql/backups"
PULL=""
[[ "${1:-}" == "--pull" ]] && PULL="${2:?--pull needs a host directory}"

docker compose ps db >/dev/null 2>&1 || { echo "no local db container; docker compose up -d first" >&2; exit 1; }

# root over the unix socket: works whatever MARIADB_ROOT_PASSWORD currently is inside the
# datadir, which is the same trick docker/entrypoint.sh uses.
docker compose exec -T db sh -c "
  mkdir -p '$DEST'
  mariadb-dump --single-transaction --routines --triggers --events --databases '$DB' \
    | gzip > '$DEST/$DB-$STAMP.sql.gz'
  ls -l '$DEST/$DB-$STAMP.sql.gz'
" | tail -n 2

echo
echo "dumps on the disk:"
docker compose exec -T db ls -lht "$DEST" | head -n 6

if [[ -n "$PULL" ]]; then
  mkdir -p "$PULL"
  cid="$(docker compose ps -q db)"
  docker cp "$cid:$DEST/$DB-$STAMP.sql.gz" "$PULL/"
  echo "copied to $PULL/$DB-$STAMP.sql.gz - this copy is the backup; the one on the disk dies with the service"
fi
