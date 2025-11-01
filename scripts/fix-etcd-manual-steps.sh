#!/bin/bash
# Manual fix steps for etcd split-brain with member cleanup

set -e

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Step 1: Stop services on pgpatroni-1 ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 \
  "sudo systemctl stop patroni && sudo systemctl stop etcd" || true
echo "✓ Services stopped"

echo ""
echo "=== Step 2: Clear etcd data on pgpatroni-1 ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 \
  "sudo rm -rf /var/lib/etcd/*" || true
echo "✓ Data cleared"

echo ""
echo "=== Step 3: Check and remove broken member from pgpatroni-2 cluster ==="
members=$(curl -s http://10.50.1.5:2379/v2/members | jq -r '.members[] | select(.name == "" or .name == null) | .id' || echo "")
if [[ -n "$members" ]]; then
  echo "Found broken/unnamed member(s), removing..."
  for member_id in $members; do
    echo "Removing member: $member_id"
    curl -X DELETE "http://10.50.1.5:2379/v2/members/$member_id" || echo "Failed to remove (may not exist)"
  done
  sleep 2
fi

# Also check for any member with peerURL pointing to 10.50.1.4
existing_member=$(curl -s http://10.50.1.5:2379/v2/members | jq -r '.members[] | select(.peerURLs[] == "http://10.50.1.4:2380") | .id' || echo "")
if [[ -n "$existing_member" ]]; then
  echo "Found existing member for 10.50.1.4, removing first..."
  curl -X DELETE "http://10.50.1.5:2379/v2/members/$existing_member" || echo "Failed to remove"
  sleep 2
fi

echo "✓ Member cleanup done"

echo ""
echo "=== Step 4: Add pgpatroni-1 as new member to pgpatroni-2's cluster ==="
add_resp=$(curl -fsS -X POST "http://10.50.1.5:2379/v2/members" \
  -H "Content-Type: application/json" \
  -d '{"peerURLs": ["http://10.50.1.4:2380"]}' 2>&1 || echo "failed")

if [[ "$add_resp" == *"failed"* ]] || [[ "$add_resp" == *"Error"* ]]; then
  echo "⚠ Member add failed: $add_resp"
  echo "Checking current members..."
  curl -s http://10.50.1.5:2379/v2/members | jq '.members[] | {name, id, peerURLs}'
  exit 1
else
  echo "✓ Member added successfully"
  echo "$add_resp" | jq '.' || echo "$add_resp"
fi

echo ""
echo "=== Step 5: Update etcd config on pgpatroni-1 ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 "sudo bash" <<'EOF'
cp /etc/default/etcd /etc/default/etcd.backup.$(date +%s) 2>/dev/null || true
cat > /etc/default/etcd <<'CFG'
ETCD_NAME="pgpatroni-1"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
ETCD_INITIAL_CLUSTER_STATE="existing"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.50.1.4:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.50.1.4:2379"
ETCD_LISTEN_PEER_URLS="http://10.50.1.4:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://10.50.1.4:2379"
CFG
echo "✓ Config updated"
cat /etc/default/etcd
EOF

echo ""
echo "=== Step 6: Start etcd on pgpatroni-1 ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 \
  "sudo systemctl start etcd"
sleep 5

echo ""
echo "=== Step 7: Verify etcd health ==="
for i in {1..10}; do
  health=$(curl -fsS "http://10.50.1.4:2379/health" 2>/dev/null | jq -r '.health' || echo "unknown")
  if [[ "$health" == "true" ]]; then
    echo "✓ etcd is healthy"
    break
  fi
  if [[ $i -eq 10 ]]; then
    echo "⚠ Warning: etcd health check failed"
  fi
  sleep 2
done

echo ""
echo "=== Step 8: Start Patroni on pgpatroni-1 ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 \
  "sudo systemctl start patroni"
sleep 10

echo ""
echo "=== Step 9: Verify cluster view ==="
echo "Members from 10.50.1.4:"
curl -s http://10.50.1.4:2379/v2/members | jq -r '.members[] | "  - \(.name // "unnamed"): id=\(.id[0:8])... peerURLs=\(.peerURLs[0])"' || echo "  (failed)"
echo ""
echo "Members from 10.50.1.5:"
curl -s http://10.50.1.5:2379/v2/members | jq -r '.members[] | "  - \(.name // "unnamed"): id=\(.id[0:8])... peerURLs=\(.peerURLs[0])"' || echo "  (failed)"

echo ""
echo "=== Fix complete! ==="
echo "Both nodes should now see 2 members with proper names"
echo ""
echo "Test cluster:"
echo "  curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo bash"

