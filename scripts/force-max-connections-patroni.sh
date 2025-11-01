#!/bin/bash
# Force max_connections by updating both config and etcd DCS

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[FORCE] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Force updating max_connections in Patroni config and DCS..."

for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  
  # Step 1: Update Patroni config file
  say "Step 1: Updating Patroni config file..."
  ssh_cmd "$host" "sudo python3" <<'PYTHON'
import yaml

with open('/etc/patroni/patroni.yml', 'r') as f:
    config = yaml.safe_load(f)

# Update postgresql.parameters (runtime)
if 'postgresql' not in config:
    config['postgresql'] = {}
if 'parameters' not in config['postgresql']:
    config['postgresql']['parameters'] = {}
config['postgresql']['parameters']['max_connections'] = 500

# Update bootstrap.dcs.postgresql.parameters (if exists)
if 'bootstrap' in config and 'dcs' in config['bootstrap']:
    if 'postgresql' not in config['bootstrap']['dcs']:
        config['bootstrap']['dcs']['postgresql'] = {}
    if 'parameters' not in config['bootstrap']['dcs']['postgresql']:
        config['bootstrap']['dcs']['postgresql']['parameters'] = {}
    config['bootstrap']['dcs']['postgresql']['parameters']['max_connections'] = 500

with open('/etc/patroni/patroni.yml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("✓ Config updated")
PYTHON
  
  # Step 2: Restart Patroni service (critical!)
  say "Step 2: Restarting Patroni service..."
  ssh_cmd "$host" "sudo systemctl stop patroni"
  sleep 5
  ssh_cmd "$host" "sudo systemctl start patroni"
  say "Waiting 20 seconds for Patroni to start..."
  sleep 20
  
  # Step 3: Verify Patroni is running
  say "Step 3: Verifying Patroni is running..."
  patroni_state=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.state' || echo 'unavailable'")
  say "Patroni state: ${patroni_state:-unavailable}"
  
  if [[ "${patroni_state:-}" != "running" ]]; then
    say "Warning: Patroni may not be ready yet, checking logs..."
    ssh_cmd "$host" "sudo journalctl -u patroni -n 10 --no-pager | tail -5" || true
  fi
  
  # Step 4: Restart PostgreSQL via Patroni API
  say "Step 4: Restarting PostgreSQL via Patroni API..."
  ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1 || echo 'Restart API failed'"
  
  say "Waiting 90 seconds for PostgreSQL to fully restart..."
  sleep 90
  
  # Step 5: Check max_connections
  say "Step 5: Checking max_connections..."
  max_conn_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  
  say "Result: max_connections=${max_conn_value:-unknown}, source=${source_info:-unknown}"
  
  if [[ "${max_conn_value:-}" == "500" ]]; then
    echo "✓ PASSED: max_connections is 500 on $host"
  else
    echo "✗ FAILED: max_connections is ${max_conn_value:-unknown} on $host (expected 500)"
    say "   This may require manual intervention or Patroni DCS update"
  fi
  
  echo ""
done

say ""
say "If max_connections is still 100, Patroni may be reading from etcd/DCS."
say "You may need to update the cluster configuration via Patroni API or etcd directly."

