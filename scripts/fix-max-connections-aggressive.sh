#!/bin/bash
# Aggressive fix: Stop Patroni, verify all sources of max_connections, update them, restart

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[FIX] $*"; }
err() { echo "[ERROR] $*" >&2; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "AGGRESSIVE FIX: Stopping Patroni, updating all config sources, restarting"
say ""

for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  
  # Step 1: Check current state
  say "Step 1: Checking current state..."
  current_role=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role // \"unknown\"'" || echo "unknown")
  say "  Current role: ${current_role}"
  
  # Step 2: Stop Patroni (so we can safely update config)
  say "Step 2: Stopping Patroni service..."
  ssh_cmd "$host" "sudo systemctl stop patroni" || say "  Warning: Stop may have failed (already stopped?)"
  sleep 3
  
  # Step 3: Remove ALL max_connections from postgresql.conf and postgresql.auto.conf
  say "Step 3: Removing max_connections from PostgreSQL config files..."
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Remove from postgresql.conf
if [ -f /pgdata/postgresql.conf ]; then
  sudo sed -i '/^max_connections/d' /pgdata/postgresql.conf
  sudo sed -i '/^#max_connections/d' /pgdata/postgresql.conf
  echo "  ✓ Removed from postgresql.conf"
fi

# Remove from postgresql.auto.conf
if [ -f /pgdata/postgresql.auto.conf ]; then
  sudo sed -i '/^max_connections/d' /pgdata/postgresql.auto.conf
  echo "  ✓ Removed from postgresql.auto.conf"
fi

# Check for include files
for conf in /pgdata/postgresql*.conf; do
  if [ -f "$conf" ] && grep -q "^include" "$conf"; then
    include_file=$(grep "^include" "$conf" | head -1 | awk '{print $2}' | tr -d "'\"")
    if [ -f "/pgdata/$include_file" ]; then
      sudo sed -i '/^max_connections/d' "/pgdata/$include_file"
      sudo sed -i '/^#max_connections/d' "/pgdata/$include_file"
      echo "  ✓ Removed from $include_file"
    fi
  fi
done
BASH
  
  # Step 4: Update Patroni config file - ensure max_connections=500 in ALL places
  say "Step 4: Updating Patroni config file (all sections)..."
  ssh_cmd "$host" "sudo bash" <<'PYTHON'
python3 <<'PYEOF'
import yaml
import sys

try:
    with open('/etc/patroni/patroni.yml', 'r') as f:
        config = yaml.safe_load(f)
    
    # Backup
    import shutil
    shutil.copy('/etc/patroni/patroni.yml', '/etc/patroni/patroni.yml.backup.aggressive')
    
    # 1. postgresql.parameters (runtime)
    if 'postgresql' not in config:
        config['postgresql'] = {}
    if 'parameters' not in config['postgresql']:
        config['postgresql']['parameters'] = {}
    config['postgresql']['parameters']['max_connections'] = 500
    print("✓ Set postgresql.parameters.max_connections = 500")
    
    # 2. bootstrap.dcs.postgresql.parameters (bootstrap)
    if 'bootstrap' not in config:
        config['bootstrap'] = {}
    if 'dcs' not in config['bootstrap']:
        config['bootstrap']['dcs'] = {}
    if 'postgresql' not in config['bootstrap']['dcs']:
        config['bootstrap']['dcs']['postgresql'] = {}
    if 'parameters' not in config['bootstrap']['dcs']['postgresql']:
        config['bootstrap']['dcs']['postgresql']['parameters'] = {}
    config['bootstrap']['dcs']['postgresql']['parameters']['max_connections'] = 500
    print("✓ Set bootstrap.dcs.postgresql.parameters.max_connections = 500")
    
    # 3. If there's a postgresql section with direct parameters, update it too
    # Sometimes config might have nested structures
    
    # Write back
    with open('/etc/patroni/patroni.yml', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    
    print("✓ Config file written successfully")
    
    # Verify
    with open('/etc/patroni/patroni.yml', 'r') as f:
        verify = yaml.safe_load(f)
    runtime_val = verify.get('postgresql', {}).get('parameters', {}).get('max_connections')
    bootstrap_val = verify.get('bootstrap', {}).get('dcs', {}).get('postgresql', {}).get('parameters', {}).get('max_connections')
    print(f"  Verified: runtime={runtime_val}, bootstrap={bootstrap_val}")
    
except Exception as e:
    print(f"✗ Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
PYTHON
  
  # Step 5: Start Patroni
  say "Step 5: Starting Patroni service..."
  ssh_cmd "$host" "sudo systemctl start patroni" || err "Failed to start Patroni on $host"
  
  # Wait for Patroni to be ready
  say "  Waiting for Patroni to start..."
  for i in {1..20}; do
    if ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/health >/dev/null 2>&1"; then
      say "  ✓ Patroni is ready"
      break
    fi
    if [[ $i -eq 20 ]]; then
      err "Patroni did not start within timeout"
      ssh_cmd "$host" "sudo systemctl status patroni --no-pager | tail -20" || true
    fi
    sleep 3
  done
  
  # Step 6: Update etcd DCS via API
  say "Step 6: Updating etcd DCS via Patroni API..."
  sleep 2
  api_result=$(ssh_cmd "$host" "curl -fsS -X PATCH http://127.0.0.1:8008/config \
    -H 'Content-Type: application/json' \
    -d '{\"postgresql\":{\"parameters\":{\"max_connections\":500}}}' 2>&1" || echo "API call failed")
  
  if echo "$api_result" | grep -qE "200|201|\"max_connections\"" || [[ -z "$api_result" ]] || echo "$api_result" | grep -q "already"; then
    say "  ✓ DCS updated via API"
  else
    say "  Warning: API update response: ${api_result:0:200}"
  fi
  
  # Step 7: Force PostgreSQL restart via API
  say "Step 7: Restarting PostgreSQL via Patroni API..."
  ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1" || say "  Warning: Restart API call failed"
  
  echo ""
done

say ""
say "Waiting 120 seconds for PostgreSQL to fully restart and apply new settings..."
sleep 120

say ""
say "=== FINAL VERIFICATION ==="
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  
  max_conn_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  
  # Also check Patroni config
  patroni_check=$(ssh_cmd "$host" "sudo grep -A2 'max_connections' /etc/patroni/patroni.yml | head -1" || echo "")
  
  say "  PostgreSQL max_connections: ${max_conn_value} (source: ${source_info})"
  say "  Patroni config: ${patroni_check}"
  
  if [[ "${max_conn_value:-}" == "500" ]]; then
    say "  ✓✓✓ SUCCESS: max_connections is 500! ✓✓✓"
  else
    err "  ✗✗✗ FAILED: max_connections is still ${max_conn_value} (source: ${source_info}) ✗✗✗"
    
    # Debug: Show how Patroni is starting PostgreSQL
    say "  DEBUG: Checking Patroni process..."
    patroni_cmd=$(ssh_cmd "$host" "ps aux | grep '[p]atroni' | head -1" || echo "not found")
    say "    Patroni process: ${patroni_cmd:0:150}"
    
    # Debug: Show Patroni logs for PostgreSQL start
    say "  DEBUG: Last Patroni logs..."
    ssh_cmd "$host" "sudo journalctl -u patroni -n 30 --no-pager | grep -i 'max_connection\|postmaster\|starting'" || true
  fi
  
  echo ""
done

