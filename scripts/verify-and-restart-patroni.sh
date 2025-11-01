#!/bin/bash
# Verify Patroni config and restart to apply max_connections

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

say "Verifying Patroni config and restarting PostgreSQL..."

for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  
  # Check Patroni config
  say "Checking Patroni config for max_connections..."
  max_conn_in_config=$(ssh_cmd "$host" "sudo grep -A10 'postgresql:' /etc/patroni/patroni.yml | grep -A5 'parameters:' | grep 'max_connections' || echo ''")
  
  if [[ -z "$max_conn_in_config" ]]; then
    say "max_connections not found in Patroni config, adding..."
    ssh_cmd "$host" "sudo python3" <<'PYTHON'
import yaml

with open('/etc/patroni/patroni.yml', 'r') as f:
    config = yaml.safe_load(f)

if 'postgresql' not in config:
    config['postgresql'] = {}
if 'parameters' not in config['postgresql']:
    config['postgresql']['parameters'] = {}

config['postgresql']['parameters']['max_connections'] = 500

with open('/etc/patroni/patroni.yml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("✓ Added max_connections: 500")
PYTHON
  else
    say "✓ max_connections found in config: $max_conn_in_config"
  fi
  
  # Show config
  say "Patroni config (postgresql.parameters):"
  ssh_cmd "$host" "sudo grep -A10 'postgresql:' /etc/patroni/patroni.yml | grep -A10 'parameters:' | head -15" || true
  
  # Restart PostgreSQL via Patroni API to apply config changes
  say "Restarting PostgreSQL via Patroni API..."
  ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1 || curl -fsS -X POST 'http://127.0.0.1:8008/reload' >/dev/null 2>&1 || true"
  
  say "Waiting 60 seconds for PostgreSQL restart..."
  sleep 60
  
  # Check max_connections
  say "Checking max_connections value..."
  max_conn_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  
  say "max_connections: ${max_conn_value:-unknown}, source: ${source_info:-unknown}"
  
  if [[ "${max_conn_value:-}" == "500" ]]; then
    echo "✓ PASSED: max_connections is 500 on $host"
  else
    echo "✗ FAILED: max_connections is ${max_conn_value:-unknown} on $host (expected 500)"
    say "   Source: ${source_info:-unknown}"
  fi
  
  echo ""
done

