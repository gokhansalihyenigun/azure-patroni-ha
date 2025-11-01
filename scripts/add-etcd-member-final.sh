#!/bin/bash
# Add pgpatroni-1 to etcd cluster from primary

set -eo pipefail

PRIMARY_NODE="10.50.1.5"
REPLICA_NODE="10.50.1.4"
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo "[ADD] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Adding pgpatroni-1 to etcd cluster from primary..."
say ""

# Step 1: Check current members
say "Step 1: Current etcd members on primary..."
current_members=$(ssh_cmd "$PRIMARY_NODE" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1" || echo "")
say "$current_members"

# Step 2: Add member
say ""
say "Step 2: Adding pgpatroni-1 to cluster..."
add_result=$(ssh_cmd "$PRIMARY_NODE" "sudo ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member add pgpatroni-1 --peer-urls=http://10.50.1.4:2380 2>&1" || echo "failed")

if echo "$add_result" | grep -qi "added\|member.*added"; then
  say "  ✓ Member added successfully!"
  echo "$add_result" | sed 's/^/    /'
  
  # Check if initial-cluster info was provided
  if echo "$add_result" | grep -q "ETCD_INITIAL_CLUSTER"; then
    initial_cluster=$(echo "$add_result" | grep "ETCD_INITIAL_CLUSTER" | sed 's/.*ETCD_INITIAL_CLUSTER=//' | tr -d '"')
    say ""
    say "Step 3: Updating etcd config on replica with new initial-cluster..."
    ssh_cmd "$REPLICA_NODE" "sudo sed -i 's|^ETCD_INITIAL_CLUSTER=.*|ETCD_INITIAL_CLUSTER=\"$initial_cluster\"|' /etc/default/etcd" || say "  Warning: Could not update config"
  fi
else
  if echo "$add_result" | grep -qi "already\|exists"; then
    say "  ℹ Member already exists in cluster"
  else
    say "  ✗ Failed to add member"
    echo "$add_result" | sed 's/^/    /'
    exit 1
  fi
fi

say ""
say "Step 4: Verifying member list after add..."
new_members=$(ssh_cmd "$PRIMARY_NODE" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1" || echo "")
say "$new_members"

member_count=$(echo "$new_members" | grep -c "started\|unstarted" || echo "0")
if [[ "$member_count" == "2" ]]; then
  say "  ✓✓✓ Cluster now has 2 members! ✓✓✓"
else
  say "  ✗ Still only $member_count member(s)"
fi

say ""
say "Step 5: Restarting etcd on replica to join cluster..."
ssh_cmd "$REPLICA_NODE" "sudo systemctl restart etcd" || say "  Warning: etcd restart failed"
sleep 10

say ""
say "Step 6: Verifying etcd health on both nodes..."
for host in "$PRIMARY_NODE" "$REPLICA_NODE"; do
  health=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:2379/health 2>/dev/null | jq -r '.health // \"unknown\"' || echo 'unknown'")
  say "  $host etcd health: $health"
done

say ""
say "Step 7: Restarting Patroni on replica..."
ssh_cmd "$REPLICA_NODE" "sudo systemctl restart patroni" || say "  Warning: Patroni restart failed"

say ""
say "Waiting 60 seconds for Patroni to rebuild cluster view..."
sleep 60

say ""
say "Step 8: Final verification - Patroni cluster view..."
for host in "$PRIMARY_NODE" "$REPLICA_NODE"; do
  say "=== Node: $host ==="
  members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
  say "  Members: $members"
  if [[ "$members" == "2" ]]; then
    say "  ✓✓✓ Complete cluster view!"
    ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '.members[] | {name, role, state}'" || true
  else
    say "  ✗ Still incomplete"
  fi
  echo ""
done

