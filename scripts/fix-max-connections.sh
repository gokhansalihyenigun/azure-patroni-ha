#!/bin/bash
# Fix max_connections - ensure it's applied correctly

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[FIX] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Checking max_connections configuration..."

for host in "${DB_NODES[@]}"; do
  say "Node: $host"
  
  # Check postgresql.auto.conf
  say "Checking postgresql.auto.conf..."
  ssh_cmd "$host" "sudo -u postgres grep max_connections /pgdata/postgresql.auto.conf" || say "  max_connections not found in auto.conf"
  
  # Check if max_connections is overridden in postgresql.conf
  say "Checking postgresql.conf for overrides..."
  ssh_cmd "$host" "sudo -u postgres grep -i 'max_connections' /pgdata/postgresql.conf 2>/dev/null | head -3" || say "  No max_connections in postgresql.conf"
  
  # Check Patroni config
  say "Checking Patroni config..."
  ssh_cmd "$host" "sudo grep -A5 'parameters:' /etc/patroni/patroni.yml | grep -i max_connection" || say "  No max_connections in Patroni config"
  
  # Get current value
  current=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null")
  say "Current max_connections: ${current:-unknown}"
  
  # If still 100, force update
  if [[ "${current:-100}" == "100" ]]; then
    say "max_connections is still 100, forcing update..."
    
    # Remove max_connections from postgresql.conf (it overrides auto.conf)
    say "Removing max_connections from postgresql.conf (it overrides auto.conf)..."
    ssh_cmd "$host" "sudo -u postgres bash" <<'BASH'
# Completely remove max_connections from postgresql.conf (including commented versions)
sed -i '/^[[:space:]]*#.*max_connections/d' /pgdata/postgresql.conf 2>/dev/null || true
sed -i '/^[[:space:]]*max_connections/d' /pgdata/postgresql.conf 2>/dev/null || true

# CRITICAL: Also check for include files (postgresql.base.conf is commonly included)
if grep -q "^include" /pgdata/postgresql.conf 2>/dev/null; then
  echo "Found include statements, checking included files..."
  for inc_file in $(grep "^include" /pgdata/postgresql.conf | awk '{print $NF}' | tr -d "'\""); do
    if [[ -f "/pgdata/$inc_file" ]]; then
      echo "Removing max_connections from /pgdata/$inc_file"
      sed -i '/^[[:space:]]*#.*max_connections/d' "/pgdata/$inc_file" 2>/dev/null || true
      sed -i '/^[[:space:]]*max_connections/d' "/pgdata/$inc_file" 2>/dev/null || true
    fi
  done
fi

# Also check common include file names directly
for inc_file in postgresql.base.conf postgresql.conf.base postgresql.conf.default; do
  if [[ -f "/pgdata/$inc_file" ]]; then
    echo "Found /pgdata/$inc_file, removing max_connections..."
    sed -i '/^[[:space:]]*max_connections/d' "/pgdata/$inc_file" 2>/dev/null || true
  fi
done

# Ensure it's in postgresql.auto.conf
sed -i '/^max_connections/d' /pgdata/postgresql.auto.conf 2>/dev/null || true
echo "max_connections = '500'" >> /pgdata/postgresql.auto.conf

# Verify
echo "=== postgresql.conf ==="
grep -i max_connection /pgdata/postgresql.conf 2>/dev/null || echo "  ✓ Not found (good!)"
echo "=== postgresql.base.conf (if exists) ==="
if [[ -f "/pgdata/postgresql.base.conf" ]]; then
  grep -i max_connection /pgdata/postgresql.base.conf 2>/dev/null || echo "  ✓ Not found (good!)"
else
  echo "  (file not found)"
fi
echo "=== postgresql.auto.conf ==="
grep max_connections /pgdata/postgresql.auto.conf 2>/dev/null || echo "  ✗ Not found (error!)"
BASH
    
    # Restart PostgreSQL via Patroni
    say "Triggering PostgreSQL restart..."
    ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1 || true"
    say "Waiting 60 seconds for PostgreSQL to fully restart and apply config..."
    sleep 60
    
    # Double-check that PostgreSQL restarted
    say "Checking PostgreSQL restart status..."
    for i in {1..6}; do
      if ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | grep -q '\"state\":\"running\"'"; then
        say "PostgreSQL is running"
        break
      fi
      say "Waiting for PostgreSQL to be ready... ($i/6)"
      sleep 10
    done
    
    # Check again
    new_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null")
    say "New max_connections: ${new_value:-unknown}"
    
    if [[ "${new_value:-}" == "500" ]]; then
      echo "✓ PASSED: max_connections is now 500"
    else
      echo "✗ FAILED: max_connections is still ${new_value:-unknown}"
    fi
  else
    echo "✓ PASSED: max_connections is already ${current}"
  fi
  
  echo ""
done

