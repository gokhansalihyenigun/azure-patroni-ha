#!/bin/bash
# Quick check for max_connections value

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[CHECK] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Checking max_connections on all nodes..."
say ""

for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  
  # Check PostgreSQL setting
  max_conn_value=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  source_info=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT source FROM pg_settings WHERE name='max_connections';\" 2>/dev/null" || echo "unknown")
  
  # Check Patroni config file
  patroni_config=$(ssh_cmd "$host" "sudo grep -A5 'parameters:' /etc/patroni/patroni.yml | grep 'max_connections' || echo 'not found'" || echo "config check failed")
  
  # Check Patroni API config
  api_config=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/config 2>/dev/null | jq -r '.postgresql.parameters.max_connections // \"not set\"'" || echo "API check failed")
  
  say "  PostgreSQL max_connections: ${max_conn_value:-unknown} (source: ${source_info:-unknown})"
  say "  Patroni config file: ${patroni_config}"
  say "  Patroni API config: ${api_config}"
  
  if [[ "${max_conn_value:-}" == "500" ]]; then
    say "  ✓ PASSED"
  else
    say "  ✗ FAILED (expected 500)"
  fi
  
  echo ""
done

