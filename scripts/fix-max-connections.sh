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
  local current=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null")
  say "Current max_connections: ${current:-unknown}"
  
  # If still 100, force update
  if [[ "$current" == "100" ]]; then
    say "max_connections is still 100, forcing update..."
    
    # Ensure it's in postgresql.auto.conf
    ssh_cmd "$host" "sudo -u postgres bash" <<'BASH'
# Remove old max_connections from auto.conf if exists
sed -i '/^max_connections/d' /pgdata/postgresql.auto.conf 2>/dev/null || true

# Add new value
echo "max_connections = '500'" >> /pgdata/postgresql.auto.conf

# Verify
grep max_connections /pgdata/postgresql.auto.conf
BASH
    
    # Restart PostgreSQL via Patroni
    say "Triggering PostgreSQL restart..."
    ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1 || true"
    say "Waiting 40 seconds for restart..."
    sleep 40
    
    # Check again
    local new_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null")
    say "New max_connections: ${new_value:-unknown}"
    
    if [[ "$new_value" == "500" ]]; then
      echo "✓ PASSED: max_connections is now 500"
    else
      echo "✗ FAILED: max_connections is still ${new_value:-unknown}"
    fi
  else
    echo "✓ PASSED: max_connections is already ${current}"
  fi
  
  echo ""
done

