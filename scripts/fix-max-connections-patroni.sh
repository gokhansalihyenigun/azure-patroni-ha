#!/bin/bash
# Fix max_connections by adding it to Patroni config (highest priority)

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[FIX] $*"; }
pass() { echo "✓ PASSED: $*"; }
fail() { echo "✗ FAILED: $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Adding max_connections to Patroni config (command line source fix)..."

for host in "${DB_NODES[@]}"; do
  say "Node: $host"
  
  # Check current value
  current=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null")
  say "Current max_connections: ${current:-unknown}"
  
  # Add max_connections to Patroni config's postgresql.parameters section
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup Patroni config
cp /etc/patroni/patroni.yml /etc/patroni/patroni.yml.backup.$(date +%s) 2>/dev/null || true

# Use Python for safe YAML editing (more reliable than sed)
python3 <<'PYTHON'
import yaml
import sys
import shutil

try:
    with open('/etc/patroni/patroni.yml', 'r') as f:
        config = yaml.safe_load(f)
    
    # Fix postgresql.parameters section
    if 'postgresql' not in config:
        config['postgresql'] = {}
    if 'parameters' not in config['postgresql']:
        config['postgresql']['parameters'] = {}
    
    # Set max_connections
    config['postgresql']['parameters']['max_connections'] = 500
    
    # Also update bootstrap.dcs.postgresql.parameters if exists
    if 'bootstrap' in config and 'dcs' in config['bootstrap']:
        if 'postgresql' not in config['bootstrap']['dcs']:
            config['bootstrap']['dcs']['postgresql'] = {}
        if 'parameters' not in config['bootstrap']['dcs']['postgresql']:
            config['bootstrap']['dcs']['postgresql']['parameters'] = {}
        config['bootstrap']['dcs']['postgresql']['parameters']['max_connections'] = 500
    
    # Write back
    with open('/etc/patroni/patroni.yml', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    
    print("✓ Config updated successfully")
except Exception as e:
    print(f"✗ Error: {e}")
    sys.exit(1)
PYTHON

# Verify YAML syntax
python3 -c "import yaml; yaml.safe_load(open('/etc/patroni/patroni.yml'))" && echo "✓ YAML syntax valid" || echo "✗ YAML syntax error!"

# Verify
echo "=== Patroni config (postgresql.parameters section) ==="
grep -A10 "postgresql:" /etc/patroni/patroni.yml | grep -A5 "parameters:" || echo "  Not found"
echo ""
echo "=== Patroni config (bootstrap.dcs.postgresql.parameters section) ==="
grep -A20 "bootstrap:" /etc/patroni/patroni.yml | grep -A10 "parameters:" | grep max_connection || echo "  Not found"

# Restart Patroni to apply changes
systemctl restart patroni
sleep 10

# Wait for PostgreSQL to restart and check logs if needed
echo "Waiting for PostgreSQL to restart..."
for i in {1..18}; do
  patroni_state=$(curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 || echo "")
  if echo "$patroni_state" | grep -q '"state":"running"'; then
    echo "✓ PostgreSQL is running"
    break
  fi
  if [[ $i -eq 12 ]]; then
    echo "Warning: PostgreSQL taking longer than expected. Checking logs..."
    journalctl -u patroni -n 20 --no-pager | tail -10 || true
  fi
  echo "Waiting for PostgreSQL... ($i/18) - State: ${patroni_state:-unknown}"
  sleep 10
done

# Final check
patroni_state=$(curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | grep -o '"state":"[^"]*"' | head -1 || echo "")
if ! echo "$patroni_state" | grep -q '"state":"running"'; then
  echo "ERROR: PostgreSQL may not have restarted properly. State: ${patroni_state:-unknown}"
  echo "Check logs: journalctl -u patroni -n 50"
fi
BASH
  
  if [[ $? -eq 0 ]]; then
    # Check new value
    sleep 5
    new_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null")
    
    if [[ "${new_value:-}" == "500" ]]; then
      pass "max_connections is now 500 on $host"
    else
      say "New max_connections: ${new_value:-unknown}"
      say "Checking source..."
      source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null")
      say "Source: ${source_info:-unknown}"
      
      if [[ "${new_value:-}" != "500" ]]; then
        fail "max_connections is still ${new_value:-unknown} on $host (source: ${source_info:-unknown})"
      fi
    fi
  else
    fail "Failed to update Patroni config on $host"
  fi
  
  echo ""
done

say ""
say "Summary:"
say "  Added max_connections: 500 to Patroni config"
say "  Patroni will pass this as command line parameter when starting PostgreSQL"
say "  This should override all config file values"

