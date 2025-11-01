#!/bin/bash
# Deep check for max_connections issue

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[CHECK] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

for host in "${DB_NODES[@]}"; do
  say "=== Deep Check: $host ==="
  
  ssh_cmd "$host" "sudo -u postgres bash" <<'BASH'
echo "1. Checking postgresql.conf:"
grep -i max_connection /pgdata/postgresql.conf 2>/dev/null || echo "  ✓ Not found"

echo ""
echo "2. Checking postgresql.auto.conf:"
cat /pgdata/postgresql.auto.conf | grep -i max_connection || echo "  ✗ Not found"

echo ""
echo "3. Checking Patroni config:"
grep -A10 "parameters:" /etc/patroni/patroni.yml | grep -i max_connection || echo "  Not found in Patroni"

echo ""
echo "4. Checking include files in postgresql.conf:"
if grep -q "^include" /pgdata/postgresql.conf 2>/dev/null; then
  for inc in $(grep "^include" /pgdata/postgresql.conf | awk '{print $NF}' | tr -d "'\""); do
    echo "  Checking /pgdata/$inc"
    grep -i max_connection "/pgdata/$inc" 2>/dev/null || echo "    Not found"
  done
fi

echo ""
echo "5. PostgreSQL config file location:"
PGPASSWORD='ChangeMe123Pass' psql -h 127.0.0.1 -U postgres -d postgres -tAc "SHOW config_file;" 2>/dev/null || echo "  Could not connect"

echo ""
echo "6. Current max_connections value:"
PGPASSWORD='ChangeMe123Pass' psql -h 127.0.0.1 -U postgres -d postgres -tAc "SELECT name, setting, source FROM pg_settings WHERE name='max_connections';" 2>/dev/null || echo "  Could not query"

echo ""
echo "7. All config files being used:"
PGPASSWORD='ChangeMe123Pass' psql -h 127.0.0.1 -U postgres -d postgres -tAc "SELECT name, setting, source, sourcefile FROM pg_settings WHERE name='max_connections';" 2>/dev/null || echo "  Could not query"

echo ""
echo "8. PostgreSQL last restart time:"
systemctl status patroni --no-pager | grep -i "active\|since" | head -2

BASH
  
  echo ""
done

