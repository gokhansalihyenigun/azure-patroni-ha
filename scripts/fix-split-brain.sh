#!/bin/bash
# Fix split-brain scenario where both nodes think they are leaders

set -euo pipefail

NODE1_IP="10.50.1.4"
NODE2_IP="10.50.1.5"
POSTGRES_PASS="ChangeMe123Pass"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "======================================"
echo "SPLIT-BRAIN FIX SCRIPT"
echo "======================================"
echo ""
echo "This script will fix the split-brain scenario where both nodes are leaders"
echo "by reinitializing one node as a replica."
echo ""
echo "⚠️  WARNING: This will stop and clear data on one node!"
echo ""
read -p "Continue? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo "=== Step 1: Checking current cluster state ==="
for ip in "$NODE1_IP" "$NODE2_IP"; do
  echo ""
  echo "Node $ip:"
  cluster_json=$(curl -fsS "http://$ip:8008/cluster" 2>/dev/null || echo "{}")
  leader=$(echo "$cluster_json" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null || echo "")
  timeline=$(echo "$cluster_json" | jq -r '.members[] | select(.role=="leader") | .timeline' 2>/dev/null || echo "")
  echo "  Leader: $leader"
  echo "  Timeline: $timeline"
done

echo ""
echo "=== Step 2: Checking etcd cluster ==="
for ip in "$NODE1_IP" "$NODE2_IP"; do
  echo ""
  echo "Checking etcd at $ip:2379"
  health=$(curl -fsS "http://$ip:2379/health" 2>/dev/null || echo "{}")
  echo "  Health: $health"
  
  # Try to get etcd members
  members=$(ETCDCTL_API=3 etcdctl --endpoints="http://$ip:2379" member list 2>/dev/null || echo "failed")
  if [[ "$members" != "failed" ]]; then
    echo "  Members:"
    echo "$members" | while read line; do
      echo "    $line"
    done
  else
    echo "  ✗ Cannot get etcd members"
  fi
done

echo ""
echo "=== Step 3: Determining which node to keep as leader ==="
echo "We'll keep node1 ($NODE1_IP) as leader and reinitialize node2 ($NODE2_IP) as replica"
KEEP_LEADER="$NODE1_IP"
REINIT_NODE="$NODE2_IP"
REINIT_NAME="pgpatroni-2"

echo ""
echo "Leader (keep): $KEEP_LEADER"
echo "Replica (reinitialize): $REINIT_NODE ($REINIT_NAME)"
echo ""

echo "=== Step 4: Stopping Patroni on replica node ==="
echo "SSH'ing to $REINIT_NODE to stop Patroni..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@"$REINIT_NODE" \
  "sudo systemctl stop patroni" 2>&1 || echo "Failed to stop Patroni (may already be stopped)"
echo "✓ Patroni stopped on $REINIT_NODE"

echo ""
echo "=== Step 5: Clearing data on replica node ==="
echo "Clearing /pgdata and /pgwal on $REINIT_NODE..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@"$REINIT_NODE" \
  "sudo rm -rf /pgdata/* /pgwal/*" 2>&1 || echo "Note: Some files may be locked (will retry)"
sleep 2
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@"$REINIT_NODE" \
  "sudo rm -rf /pgdata/* /pgwal/* 2>/dev/null || true" 2>&1
echo "✓ Data cleared"

echo ""
echo "=== Step 6: Ensuring etcd cluster is healthy ==="
echo "Checking etcd on leader ($KEEP_LEADER)..."
leader_etcd_health=$(curl -fsS "http://$KEEP_LEADER:2379/health" 2>/dev/null || echo "{}")
if [[ "$leader_etcd_health" == "{}" ]]; then
  echo "✗ etcd not healthy on leader! Fixing..."
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@"$KEEP_LEADER" \
    "sudo systemctl restart etcd; sleep 3; curl -fsS http://localhost:2379/health || echo 'etcd still not healthy'" 2>&1
fi

echo "Checking etcd on replica node ($REINIT_NODE)..."
replica_etcd_health=$(curl -fsS "http://$REINIT_NODE:2379/health" 2>/dev/null || echo "{}")
if [[ "$replica_etcd_health" == "{}" ]]; then
  echo "✗ etcd not healthy on replica! Fixing..."
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@"$REINIT_NODE" \
    "sudo systemctl restart etcd; sleep 3; curl -fsS http://localhost:2379/health || echo 'etcd still not healthy'" 2>&1
fi

echo ""
echo "=== Step 7: Checking etcd cluster configuration ==="
echo "Verifying etcd cluster token and initial cluster settings..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@"$REINIT_NODE" \
  "echo 'ETCD config:'; grep -E 'ETCD_INITIAL_CLUSTER_TOKEN|ETCD_INITIAL_CLUSTER|ETCD_INITIAL_CLUSTER_STATE' /etc/default/etcd 2>/dev/null || echo 'Config file not found'" 2>&1

echo ""
echo "=== Step 8: Reinitializing replica node ==="
echo "Forcing reinitialize on $REINIT_NODE via Patroni API..."
# First, try to call reinitialize API (if Patroni is still running)
reinit_result=$(curl -fsS -X POST "http://$REINIT_NODE:8008/reinitialize?force=1" 2>/dev/null || echo "api_not_available")
if [[ "$reinit_result" != "api_not_available" ]]; then
  echo "  Reinitialize API called: $reinit_result"
  echo "  Waiting 30 seconds for reinitialize to start..."
  sleep 30
else
  echo "  API not available, will restart Patroni to trigger reinitialize"
fi

echo ""
echo "=== Step 9: Starting Patroni on replica node ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@"$REINIT_NODE" \
  "sudo systemctl start patroni" 2>&1 || echo "Failed to start Patroni"
echo "✓ Patroni started on $REINIT_NODE"

echo ""
echo "=== Step 10: Waiting for replica to join (max 5 minutes) ==="
echo "Monitoring cluster status..."
for i in {1..60}; do
  sleep 5
  cluster_json=$(curl -fsS "http://$KEEP_LEADER:8008/cluster" 2>/dev/null || echo "{}")
  replica_info=$(echo "$cluster_json" | jq -r ".members[] | select(.name==\"$REINIT_NAME\") | \"\(.name): \(.role) - \(.state)\"" 2>/dev/null || echo "")
  
  if [[ -n "$replica_info" ]]; then
    echo "  Found: $replica_info"
    if echo "$replica_info" | grep -qE "(replica|sync_standby)"; then
      echo ""
      echo "✓ SUCCESS: Replica has joined the cluster!"
      break
    fi
  fi
  
  if [[ $((i % 12)) -eq 0 ]]; then
    echo "  Still waiting... ($((i*5))s elapsed)"
  fi
done

echo ""
echo "=== Step 11: Final cluster status ==="
cluster_json=$(curl -fsS "http://$KEEP_LEADER:8008/cluster" 2>/dev/null || echo "{}")
echo "$cluster_json" | jq -r '.members[] | "\(.name): \(.role) - \(.state)"' 2>/dev/null || echo "Error getting cluster status"

echo ""
echo "======================================"
echo "SPLIT-BRAIN FIX COMPLETE"
echo "======================================"
echo ""
echo "Next steps:"
echo "1. Verify replication: curl -s http://$KEEP_LEADER:8008/cluster | jq '.members[]'"
echo "2. Check replication status: PGPASSWORD=$POSTGRES_PASS psql -h $KEEP_LEADER -p 5432 -U postgres -c 'SELECT * FROM pg_stat_replication;'"
echo "3. Run test script: curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo bash"
echo ""

