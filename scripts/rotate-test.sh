#!/usr/bin/env bash
# X11 in isolation: rotate the application password the way editing MARIADB_PASSWORD in the
# Render dashboard does, restart only the database, and prove the reconciling entrypoint
# re-pointed the surviving datadir.
#
#   ./scripts/rotate-test.sh
#
# The control matters: without docker/entrypoint.sh, step 3 fails with "Access denied" and the
# only way back in is an operator running ALTER USER by hand - which is exactly the outage you
# get on Render after a quiet secret rotation.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[[ -f .env ]] && set -a && . ./.env && set +a

DB="${DB_NAME:-erpnext}"
USER_="${DB_USER:-erpnext}"
OLD="${DB_PASSWORD:-proof-db-password}"
NEW="rotated-$(date +%s)"
PASS=0; FAIL=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
conn() { docker compose exec -T db mariadb -h 127.0.0.1 -P 10000 -u "$USER_" -p"$1" -e "SELECT 1" >/dev/null 2>&1; }

echo "== 1. baseline: the password from .env authenticates"
docker compose up -d >/dev/null 2>&1
for _ in $(seq 1 60); do conn "$OLD" && break; sleep 2; done
conn "$OLD" && ok "connects with the current secret" || { bad "cannot even connect before the test - fix that first"; exit 1; }

echo "== 2. rotate the secret (dashboard edit) and restart the database"
if [[ -f .env ]]; then cp .env .env.bak; sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$NEW/" .env; else printf 'DB_PASSWORD=%s\n' "$NEW" > .env; fi
export DB_PASSWORD="$NEW"
docker compose up -d --force-recreate db >/dev/null 2>&1
sleep 2
echo "  --- entrypoint log ---"
docker compose logs --no-log-prefix db 2>/dev/null | grep -E 'db-entrypoint|ERROR|Access denied' | tail -n 6 | sed 's/^/  /'

echo "== 3. the NEW secret must work, the OLD one must not"
for _ in $(seq 1 40); do conn "$NEW" && break; sleep 2; done
conn "$NEW" && ok "new secret authenticates (ALTER USER ran against the surviving datadir)" || bad "new secret rejected - rotation would brick a Render deploy"
if conn "$OLD"; then bad "the OLD secret still works, so the reconcile did not happen"; else ok "old secret is gone"; fi

echo "== 4. restart again with no env change: must stay healthy and skip the churn"
# Counting the line across the whole log instead of grepping a `--since 1m` window: a restart keeps
# the same container, so the previous boot's lines are still in there, and a time window can match
# either one. Only "did it appear again" is a real assertion.
boots_before="$(docker compose logs --no-log-prefix db 2>/dev/null | grep -c 'existing datadir')"
docker compose restart db >/dev/null 2>&1
sleep 6
conn "$NEW" && ok "second plain restart still authenticates" || bad "broke on a no-op restart"
boots_after="$(docker compose logs --no-log-prefix db 2>/dev/null | grep -c 'existing datadir')"
if [ "${boots_after:-0}" -gt "${boots_before:-0}" ]; then
  ok "entrypoint recognised the existing datadir again ($boots_before -> $boots_after boots)"
else
  bad "no 'existing datadir' line from this restart (count stayed at $boots_after) - either a fresh-disk reinstall or the line moved"
fi

if [[ -f .env.bak ]]; then mv .env.bak .env; echo; echo "(.env restored to DB_PASSWORD=$OLD; on Render you would simply leave the new value)"; fi
printf '\n== %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]] || exit 1
