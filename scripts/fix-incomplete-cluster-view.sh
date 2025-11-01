#!/bin/bash
# Fix incomplete cluster view - ensure both nodes see each other in etcd

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo "[FIX] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Diagnosing cluster view problem..."
say ""

# Check cluster view from both nodes
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
  say "  Cluster members seen: $members"
  
  # Show all members
  ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '.members[] | {name, role, state, host}' || echo 'Failed'" || true
  
  # Check Patroni role
  role=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role // \"unknown\"' || echo 'unknown'")
  say "  Local role: $role"
  echo ""
done

say "Checking etcd cluster health..."
for host in "${DB_NODES[@]}"; do
  etcd_health=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:2379/health 2>/dev/null | jq -r '.health // \"unknown\"' || echo 'unknown'")
  say "  $host etcd health: $etcd_health"
done

say ""
say "Checking Patroni config (etcd hosts)..."
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  etcd_hosts=$(ssh_cmd "$host" "sudo grep -A1 'etcd:' /etc/patroni/patroni.yml | grep 'hosts:' | sed 's/.*hosts://' | tr -d ' ' || echo 'not found'")
  say "  etcd hosts in config: $etcd_hosts"
done

say ""
say "Checking if Patroni can reach etcd on other nodes..."
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  for other_host in "${DB_NODES[@]}"; do
    if [[ "$host" != "$other_host" ]]; then
      reachable=$(ssh_cmd "$host" "curl -fsS http://$other_host:2379/health 2>/dev/null | jq -r '.health // \"failed\"' || echo 'failed'")
      say "  Can reach etcd on $other_host: $reachable"
    fi
  done
done

say ""
say "Checking Patroni service status..."
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  patroni_status=$(ssh_cmd "$host" "sudo systemctl status patroni --no-pager 2>&1 | head -5 | tail -1 || echo 'unknown'")
  say "  Patroni status: $patroni_status"
done

say ""
say "=== Recommendations ==="
say "If cluster view is incomplete, possible causes:"
say "1. etcd cluster not fully connected"
say "2. Patroni can't reach etcd on other nodes"
say "3. Patroni config has wrong etcd hosts"
say "4. Network connectivity issues"
say ""
say "Try restarting Patroni services on both nodes:"
say "  for host in 10.50.1.4 10.50.1.5; do"
say "    ssh azureuser@\$host 'sudo systemctl restart patroni'"
say "  done"
say "  sleep 30"
say "  # Then check again"

