#!/bin/bash
# Quick cluster status check

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo "[CHECK] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Checking cluster status..."

for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  
  # Patroni service status
  echo "Patroni service:"
  ssh_cmd "$host" "sudo systemctl status patroni --no-pager | head -5" || echo "  Could not check service"
  
  # Patroni API
  echo "Patroni API:"
  patroni_state=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.state' || echo 'unavailable'")
  echo "  State: ${patroni_state:-unavailable}"
  
  # PostgreSQL process
  echo "PostgreSQL process:"
  pg_process=$(ssh_cmd "$host" "pgrep -f postgres | wc -l")
  echo "  Processes: ${pg_process:-0}"
  
  # Recent Patroni logs
  echo "Recent Patroni logs (last 5 lines):"
  ssh_cmd "$host" "sudo journalctl -u patroni -n 5 --no-pager 2>/dev/null | tail -3" || echo "  Could not read logs"
  
  echo ""
done

# Try to get cluster info
say "Cluster info:"
for host in "${DB_NODES[@]}"; do
  cluster_info=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null" || echo "")
  if [[ -n "$cluster_info" ]]; then
    echo "Cluster from $host:"
    echo "$cluster_info" | jq -r '.members[] | "  \(.name): role=\(.role), state=\(.state)"' 2>/dev/null || echo "$cluster_info"
    break
  fi
done

