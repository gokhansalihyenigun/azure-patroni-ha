#!/bin/bash
# Complete fix for max_connections - update both config file AND etcd DCS, restart Patroni service

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

say "Complete fix for max_connections: 500"
say "This will:"
say "  1. Update Patroni config file (patroni.yml)"
say "  2. Update etcd DCS (cluster config via API)"
say "  3. Restart Patroni service on all nodes"
say "  4. Restart PostgreSQL via Patroni API"
say ""

for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  
  # Step 1: Update Patroni config file
  say "Step 1: Updating Patroni config file..."
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup
cp /etc/patroni/patroni.yml /etc/patroni/patroni.yml.backup.$(date +%s) 2>/dev/null || true

python3 <<'PYTHON'
import yaml

with open('/etc/patroni/patroni.yml', 'r') as f:
    config = yaml.safe_load(f)

# Ensure postgresql.parameters.max_connections = 500
if 'postgresql' not in config:
    config['postgresql'] = {}
if 'parameters' not in config['postgresql']:
    config['postgresql']['parameters'] = {}
config['postgresql']['parameters']['max_connections'] = 500

# Also in bootstrap section
if 'bootstrap' in config and 'dcs' in config['bootstrap']:
    if 'postgresql' not in config['bootstrap']['dcs']:
        config['bootstrap']['dcs']['postgresql'] = {}
    if 'parameters' not in config['bootstrap']['dcs']['postgresql']:
        config['bootstrap']['dcs']['postgresql']['parameters'] = {}
    config['bootstrap']['dcs']['postgresql']['parameters']['max_connections'] = 500

with open('/etc/patroni/patroni.yml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, sort_keys=False)

print("✓ Config file updated")
PYTHON
BASH
  
  # Step 2: Update etcd DCS via Patroni API
  say "Step 2: Updating etcd DCS via Patroni API..."
  api_result=$(ssh_cmd "$host" "curl -fsS -X PATCH http://127.0.0.1:8008/config \
    -H 'Content-Type: application/json' \
    -d '{\"postgresql\":{\"parameters\":{\"max_connections\":500}}}' 2>&1" || echo "API update failed")
  
  if echo "$api_result" | grep -qE "200|201|\"max_connections\"" || [[ -z "$api_result" ]]; then
    say "✓ DCS updated via API"
  else
    say "Warning: API update may have failed: ${api_result:0:100}"
  fi
  
  # Step 3: Restart Patroni service (to reload config)
  say "Step 3: Restarting Patroni service (to load new config)..."
  ssh_cmd "$host" "sudo systemctl restart patroni" || say "Warning: Patroni restart may have failed"
  sleep 5
  
  # Wait for Patroni to be ready
  for i in {1..12}; do
    if ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/health >/dev/null 2>&1"; then
      say "✓ Patroni is ready"
      break
    fi
    if [[ $i -eq 12 ]]; then
      say "Warning: Patroni taking longer than expected"
    fi
    sleep 5
  done
  
  # Step 4: Restart PostgreSQL via Patroni API
  say "Step 4: Restarting PostgreSQL via Patroni API..."
  ssh_cmd "$host" "curl -fsS -X POST http://127.0.0.1:8008/restart >/dev/null 2>&1" || say "Warning: PostgreSQL restart via API may have failed"
  
  echo ""
done

say ""
say "Waiting 90 seconds for PostgreSQL to fully restart..."
sleep 90

say ""
say "=== Verification ==="
for host in "${DB_NODES[@]}"; do
  max_conn_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  
  if [[ "${max_conn_value:-}" == "500" ]]; then
    say "✓ PASSED: max_connections is 500 on $host (source: ${source_info:-unknown})"
  else
    say "✗ FAILED: max_connections is ${max_conn_value:-unknown} on $host (source: ${source_info:-unknown})"
  fi
done

