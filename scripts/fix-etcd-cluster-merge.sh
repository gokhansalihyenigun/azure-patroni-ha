#!/bin/bash
# Fix etcd cluster - merge two separate clusters into one

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

say "Fixing etcd cluster - merging two separate clusters"
say "Strategy: Keep pgpatroni-2 (primary) as existing cluster, rejoin pgpatroni-1"
say ""

# Step 1: Identify which node is primary/leader (should be pgpatroni-2)
PRIMARY_NODE="10.50.1.5"
REPLICA_NODE="10.50.1.4"

say "Step 1: Identifying primary node (to keep existing cluster)..."
primary_role=$(ssh_cmd "$PRIMARY_NODE" "timeout 5 curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role // \"unknown\"' 2>/dev/null || echo 'unknown'" || echo "unknown")
if [[ "$primary_role" == "primary" ]] || [[ "$primary_role" == "leader" ]]; then
  say "  ✓ Primary identified: $PRIMARY_NODE (role: $primary_role)"
elif [[ "$primary_role" == "unknown" ]]; then
  say "  Warning: Could not determine role, but proceeding (assuming $PRIMARY_NODE is primary)"
else
  say "  Warning: $PRIMARY_NODE role is $primary_role, but proceeding anyway"
fi

say ""
say "Step 2: Stopping Patroni on replica node ($REPLICA_NODE) to safely fix etcd..."
ssh_cmd "$REPLICA_NODE" "sudo systemctl stop patroni" || say "  Warning: Patroni stop may have failed"

say ""
say "Step 3: Stopping etcd on replica node..."
ssh_cmd "$REPLICA_NODE" "sudo systemctl stop etcd" || say "  Warning: etcd stop may have failed"
sleep 3

say ""
say "Step 4: Checking primary node's etcd cluster members (to get correct cluster config)..."
primary_members=$(ssh_cmd "$PRIMARY_NODE" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1" || echo "")
say "  Primary etcd members:"
echo "$primary_members" | sed 's/^/    /' || echo "    (could not retrieve)"

# Get primary node's etcd ID and peer URL
primary_etcd_id=$(echo "$primary_members" | grep "pgpatroni-2" | cut -d',' -f1 || echo "")
say "  Primary etcd ID: ${primary_etcd_id:-unknown}"

say ""
say "Step 5: Clearing etcd data on replica node and setting correct cluster state..."
ssh_cmd "$REPLICA_NODE" "sudo bash" <<'BASH'
# Backup etcd data
sudo mkdir -p /var/lib/etcd.backup.$(date +%s) 2>/dev/null || true
sudo cp -r /var/lib/etcd/* /var/lib/etcd.backup.$(date +%s)/ 2>/dev/null || true

# Clear etcd data directory
sudo rm -rf /var/lib/etcd/*

# Update etcd config to join existing cluster
sudo sed -i 's/^ETCD_INITIAL_CLUSTER_STATE=.*/ETCD_INITIAL_CLUSTER_STATE="existing"/' /etc/default/etcd

# Verify the change
echo "ETCD_INITIAL_CLUSTER_STATE after update:"
sudo grep "^ETCD_INITIAL_CLUSTER_STATE" /etc/default/etcd || echo "  (not found)"
BASH

say ""
say "Step 6: Starting etcd on replica node (should join existing cluster)..."
ssh_cmd "$REPLICA_NODE" "sudo systemctl start etcd" || say "  Error: etcd start failed"

say ""
say "Waiting 10 seconds for etcd to join cluster..."
sleep 10

say ""
say "Step 7: Verifying etcd cluster membership..."
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  members=$(ssh_cmd "$host" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1" || echo "failed")
  member_count=$(echo "$members" | grep -c "started" || echo "0")
  say "  Cluster members: $member_count"
  if [[ "$member_count" == "2" ]]; then
    say "  ✓ Cluster has both members!"
  else
    say "  ✗ Cluster still incomplete"
  fi
  echo "$members" | sed 's/^/    /' || echo "    (could not retrieve)"
done

say ""
say "Step 8: Starting Patroni on replica node..."
ssh_cmd "$REPLICA_NODE" "sudo systemctl start patroni" || say "  Error: Patroni start failed"

say ""
say "Waiting 60 seconds for Patroni to reconnect and rebuild cluster view..."
sleep 60

say ""
say "Step 9: Verifying cluster view from both nodes..."
all_good=true
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
  say "  Patroni cluster members: $members"
  if [[ "$members" == "2" ]]; then
    say "  ✓✓✓ Complete cluster view!"
    ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '.members[] | {name, role, state}'" || true
  else
    say "  ✗ Still incomplete (expected 2, got $members)"
    all_good=false
  fi
  echo ""
done

if [[ "$all_good" == "true" ]]; then
  say ""
  say "✓✓✓ SUCCESS: etcd cluster merged and Patroni cluster view is complete! ✓✓✓"
else
  say ""
  say "✗✗✗ WARNING: Cluster view still incomplete ✗✗✗"
  say "You may need to:"
  say "  1. Check etcd logs: sudo journalctl -u etcd -n 50"
  say "  2. Check Patroni logs: sudo journalctl -u patroni -n 50"
  say "  3. Manually restart both Patroni services"
fi

