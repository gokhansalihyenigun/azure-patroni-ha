#!/bin/bash
# Final fix for max_connections - update via Patroni API directly

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

# Find working node (any node with Patroni API)
say "Finding working Patroni node..."
WORKING_NODE=""
for host in "${DB_NODES[@]}"; do
  if ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/health >/dev/null 2>&1"; then
    WORKING_NODE="$host"
    say "Found working node: $WORKING_NODE"
    break
  fi
done

if [[ -z "$WORKING_NODE" ]]; then
  say "No working Patroni node found, trying cluster endpoint..."
  for host in "${DB_NODES[@]}"; do
    if ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster >/dev/null 2>&1"; then
      WORKING_NODE="$host"
      break
    fi
  done
fi

if [[ -z "$WORKING_NODE" ]]; then
  say "No working node found, using first node..."
  WORKING_NODE="${DB_NODES[0]}"
fi

say "Using node: $WORKING_NODE"

# Update cluster config via Patroni API
say "Updating cluster config via Patroni API..."
update_result=$(ssh_cmd "$WORKING_NODE" <<'EOF'
# Try to update config
RESULT=$(curl -fsS -X PATCH http://127.0.0.1:8008/config \
  -H "Content-Type: application/json" \
  -d '{"postgresql":{"parameters":{"max_connections":500}}}' 2>&1)

if echo "$RESULT" | grep -qE "200|201|204|\"max_connections\""; then
  echo "✓ Config updated: $RESULT"
  exit 0
else
  echo "✗ Update failed: $RESULT"
  # Try GET first to see current config
  CURRENT=$(curl -fsS http://127.0.0.1:8008/config 2>/dev/null)
  if [[ -n "$CURRENT" ]]; then
    echo "Current config max_connections:"
    echo "$CURRENT" | jq -r '.postgresql.parameters.max_connections // "not set"' 2>/dev/null || echo "  (could not parse)"
    
    # Try updating with full config
    UPDATED=$(echo "$CURRENT" | jq '.postgresql.parameters.max_connections = 500' 2>/dev/null)
    if [[ -n "$UPDATED" ]]; then
      RESULT2=$(curl -fsS -X PATCH http://127.0.0.1:8008/config \
        -H "Content-Type: application/json" \
        -d "$UPDATED" 2>&1)
      echo "Update result 2: $RESULT2"
    fi
  fi
  exit 1
fi
EOF
)

say "Update result: ${update_result:-unknown}"

# Restart PostgreSQL on all nodes
say "Restarting PostgreSQL on all nodes..."
for host in "${DB_NODES[@]}"; do
  say "Restarting $host..."
  ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1 || echo 'Restart failed'"
done

say "Waiting 90 seconds for PostgreSQL restart..."
sleep 90

# Check results
say ""
say "Checking max_connections..."

for host in "${DB_NODES[@]}"; do
  max_conn_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  
  if [[ "${max_conn_value:-}" == "500" ]]; then
    echo "✓ PASSED: max_connections is 500 on $host"
  else
    echo "✗ FAILED: max_connections is ${max_conn_value:-unknown} on $host (source: ${source_info:-unknown})"
  fi
done

