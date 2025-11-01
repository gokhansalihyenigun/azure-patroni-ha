#!/bin/bash
# Fix incomplete cluster view - ensure both nodes see each other

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

say "Fixing incomplete cluster view..."
say ""

# Step 1: Check current state
say "Step 1: Current cluster view from each node"
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
  say "  Members seen: $members"
  ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '.members[] | {name, role, state}' || echo 'Failed'" || true
done

say ""
say "Step 2: Checking etcd connectivity"
for host in "${DB_NODES[@]}"; do
  for other_host in "${DB_NODES[@]}"; do
    if [[ "$host" != "$other_host" ]]; then
      reachable=$(ssh_cmd "$host" "curl -fsS http://$other_host:2379/health 2>/dev/null | jq -r '.health // \"failed\"' || echo 'failed'")
      if [[ "$reachable" == "true" ]]; then
        say "  ✓ $host can reach etcd on $other_host"
      else
        say "  ✗ $host CANNOT reach etcd on $other_host"
      fi
    fi
  done
done

say ""
say "Step 3: Checking Patroni config (etcd hosts)"
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  etcd_hosts=$(ssh_cmd "$host" "sudo grep -A1 'etcd:' /etc/patroni/patroni.yml | grep 'hosts:' | sed 's/.*hosts://' | tr -d ' ' || echo 'not found'")
  say "  etcd hosts: $etcd_hosts"
done

say ""
say "Step 4: Restarting Patroni services (to refresh cluster view)"
say "This will cause a brief switchover but should fix the cluster view"
for host in "${DB_NODES[@]}"; do
  say "Restarting Patroni on $host..."
  ssh_cmd "$host" "sudo systemctl restart patroni" || say "  Warning: Restart may have failed"
done

say ""
say "Waiting 60 seconds for Patroni to reconnect and rebuild cluster view..."
sleep 60

say ""
say "Step 5: Verifying cluster view after restart"
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
  say "  Members seen: $members"
  if [[ "$members" == "2" ]]; then
    say "  ✓ Cluster view is complete!"
  else
    say "  ✗ Cluster view still incomplete (expected 2, got $members)"
  fi
  ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '.members[] | {name, role, state}' || echo 'Failed'" || true
done

say ""
say "Step 6: Final verification"
say "Checking if both nodes can see each other..."
all_good=true
for host in "${DB_NODES[@]}"; do
  members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
  if [[ "$members" != "2" ]]; then
    say "  ✗ $host still sees only $members member(s)"
    all_good=false
  fi
done

if [[ "$all_good" == "true" ]]; then
  say ""
  say "✓✓✓ SUCCESS: Cluster view is complete on all nodes! ✓✓✓"
else
  say ""
  say "✗✗✗ WARNING: Cluster view is still incomplete ✗✗✗"
  say "This might indicate:"
  say "  - etcd cluster connectivity issues"
  say "  - Network firewall/NSG blocking etcd ports (2379, 2380)"
  say "  - Patroni config mismatch"
  say "  - etcd data corruption"
  say ""
  say "Next steps:"
  say "  1. Check etcd logs: sudo journalctl -u etcd -n 50"
  say "  2. Check Patroni logs: sudo journalctl -u patroni -n 50"
  say "  3. Verify network connectivity between nodes"
  say "  4. Check etcd cluster members: etcdctl member list"
fi

