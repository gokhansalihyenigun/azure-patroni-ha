#!/bin/bash
# Update Patroni cluster parameters via API (writes to etcd DCS)

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[UPDATE] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

# Find leader
say "Finding cluster leader..."
LEADER_IP=""
for host in "${DB_NODES[@]}"; do
  leader_check=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role' || echo ''")
  if [[ "$leader_check" == "leader" ]]; then
    LEADER_IP="$host"
    say "Leader found: $LEADER_IP"
    break
  fi
done

if [[ -z "$LEADER_IP" ]]; then
  say "No leader found, trying any node..."
  LEADER_IP="${DB_NODES[0]}"
fi

# Get current cluster config
say "Getting current cluster configuration..."
current_config=$(ssh_cmd "$LEADER_IP" "curl -fsS http://127.0.0.1:8008/config 2>/dev/null" || echo "")

if [[ -z "$current_config" ]]; then
  say "Could not get cluster config, trying alternative method..."
  # Try to update via etcd directly or Patroni API
else
  say "Current config retrieved"
  echo "$current_config" | jq -r '.postgresql.parameters.max_connections // "not set"' || true
fi

# Update via Patroni API PATCH method
say "Updating cluster parameters via Patroni API..."
update_result=$(ssh_cmd "$LEADER_IP" <<'EOF'
# Get current config
CURRENT=$(curl -fsS http://127.0.0.1:8008/config 2>/dev/null)

if [[ -z "$CURRENT" ]]; then
  echo "✗ Failed to get current config"
  # Try alternative: direct JSON payload
  PAYLOAD='{"postgresql":{"parameters":{"max_connections":500}}}'
  RESULT=$(curl -fsS -X PATCH http://127.0.0.1:8008/config \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>&1)
  echo "Update result: $RESULT"
else
  # Update max_connections in the config
  UPDATED=$(echo "$CURRENT" | jq '.postgresql.parameters.max_connections = 500' 2>/dev/null)
  
  if [[ -z "$UPDATED" ]]; then
    # If jq fails, create minimal payload
    PAYLOAD='{"postgresql":{"parameters":{"max_connections":500}}}'
  else
    PAYLOAD="$UPDATED"
  fi
  
  # Patch the config
  RESULT=$(curl -fsS -X PATCH http://127.0.0.1:8008/config \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>&1)
  
  if echo "$RESULT" | grep -qE "200|201|204|\"max_connections\": 500"; then
    echo "✓ Config updated successfully"
  else
    echo "✗ Update failed or partial: $RESULT"
    echo "   Trying with minimal payload..."
    MIN_PAYLOAD='{"postgresql":{"parameters":{"max_connections":500}}}'
    curl -fsS -X PATCH http://127.0.0.1:8008/config \
      -H "Content-Type: application/json" \
      -d "$MIN_PAYLOAD" 2>&1
  fi
fi
EOF
)

say "Update result: ${update_result:-unknown}"

# Wait and restart PostgreSQL
say "Waiting 10 seconds, then restarting PostgreSQL..."
sleep 10

for host in "${DB_NODES[@]}"; do
  say "Restarting PostgreSQL on $host..."
  ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1 || true"
done

say "Waiting 90 seconds for PostgreSQL restart..."
sleep 90

# Check results
say ""
say "Checking max_connections after update..."

for host in "${DB_NODES[@]}"; do
  max_conn_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  
  say "Node $host: max_connections=${max_conn_value:-unknown}, source=${source_info:-unknown}"
  
  if [[ "${max_conn_value:-}" == "500" ]]; then
    echo "✓ PASSED: max_connections is 500 on $host"
  else
    echo "✗ FAILED: max_connections is ${max_conn_value:-unknown} on $host"
  fi
done

