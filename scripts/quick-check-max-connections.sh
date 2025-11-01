#!/bin/bash
# Quick check for max_connections - no waiting

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

echo "=== Quick Check: max_connections ==="
echo ""

for host in "${DB_NODES[@]}"; do
  echo "Node: $host"
  
  max_conn=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  role=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role // \"unknown\"'" || echo "unknown")
  state=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.state // \"unknown\"'" || echo "unknown")
  
  if [[ "${max_conn:-}" == "500" ]]; then
    echo "  ✓ SUCCESS: max_connections = 500 (source: ${source_info})"
  else
    echo "  ✗ FAILED: max_connections = ${max_conn} (source: ${source_info})"
  fi
  echo "  Role: ${role}, State: ${state}"
  echo ""
done

