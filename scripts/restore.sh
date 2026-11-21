#!/usr/bin/env bash
# Restore a dump produced by scripts/backup.sh.
#
#   ./scripts/restore.sh                       # a dump already inside /var/lib/mysql/backups
#   ./scripts/restore.sh ./backups/erpnext-x.sql.gz   # push a host file in first
#
# The important case is the one Render makes easy to reach: the db service was DELETED (disk
# gone with it), a new one was created, its entrypoint ran a fresh mariadb-install-db, and now
# this dump has to land on top. The dump carries CREATE DATABASE, so the schema the new
# container invented by itself is what gets replaced - point MARIADB_DATABASE at the same name
# or expect both to exist afterwards.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f .env ]] && set -a && . ./.env && set +a

DB="${DB_NAME:-erpnext}"
DEST="/var/lib/mysql/backups"
SRC="${1:-}"

docker compose ps db >/dev/null 2>&1 || { echo "no local db container; docker compose up -d first" >&2; exit 1; }

if [[ -z "$SRC" ]]; then
  SRC="$(docker compose exec -T db sh -c "ls -1t $DEST/*.sql.gz 2>/dev/null | head -n1" | tr -d '\r')"
  [[ -n "$SRC" ]] || { echo "no dump in $DEST - pass a path" >&2; ls -l "$DEST" >&2 || true; exit 1; }
  IN_CONTAINER="$SRC"
else
  [[ -f "$SRC" ]] || { echo "no such host file: $SRC" >&2; exit 1; }
  cid="$(docker compose ps -q db)"
  docker compose exec -T db mkdir -p "$DEST"
  docker cp "$SRC" "$cid:$DEST/$(basename "$SRC")"
  IN_CONTAINER="$DEST/$(basename "$SRC")"
  echo "pushed $SRC -> $IN_CONTAINER"
fi

echo "Restoring $IN_CONTAINER into the running server."
echo "This overwrites everything in the target database. Type yes to continue."
read -r answer
[[ "$answer" == "yes" ]] || { echo "aborted"; exit 1; }

# --force keeps going past "database exists" errors, which is the normal state after a fresh
# mariadb-install-db created an empty schema of the same name.
docker compose exec -T db sh -c "gunzip -c '$IN_CONTAINER' | mariadb --force"
echo "loaded; verifying the tables arrived:"
docker compose exec -T db mariadb -N -B -e \
  "SELECT COUNT(*) AS tables_in_$DB FROM information_schema.tables WHERE table_schema='$DB';"

cat <<'EOF'

Next: ERPNext stores its own per-site db_name in sites/<site>/site_config.json, and Frappe's
own API-secret encryption lives in the sites disk, not here. A restored database with a
different site config means every stored credential reads as garbage - check
proof-erpnext-app/RENDER_DEPLOY.md's X13 recovery notes before declaring victory.
EOF
