#!/bin/bash
# Force clean etcd cluster - restart pgpatroni-2's etcd to remove broken member

set -eo pipefail

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Force Clean etcd Cluster ==="
echo ""

echo "Step 1: Ensure pgpatroni-1 services are stopped and data cleared..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl stop patroni etcd 2>&1 || true" || true
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo rm -rf /var/lib/etcd/* 2>&1 || true" || true
echo "✓ pgpatroni-1 prepared"

echo ""
echo "Step 2: Stop pgpatroni-2's etcd to reset cluster state..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo systemctl stop patroni etcd 2>&1" || true
sleep 3

echo ""
echo "Step 3: Clear etcd data on pgpatroni-2 (removes broken member info)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo rm -rf /var/lib/etcd/* 2>&1 || true" || true
echo "✓ pgpatroni-2 etcd data cleared"

echo ""
echo "Step 4: Update pgpatroni-2's etcd config (fresh cluster)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo bash" <<'EOF'
cat > /etc/default/etcd <<'CFG'
ETCD_NAME="pgpatroni-2"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.50.1.5:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.50.1.5:2379"
ETCD_LISTEN_PEER_URLS="http://10.50.1.5:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://10.50.1.5:2379"
CFG
echo "✓ Config updated"
EOF

echo ""
echo "Step 5: Start etcd on pgpatroni-2 (will create new cluster)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo systemctl start etcd"
sleep 5

echo ""
echo "Step 6: Verify pgpatroni-2's etcd is healthy..."
for i in {1..10}; do
  health=$(curl -fsS "http://10.50.1.5:2379/health" 2>/dev/null | jq -r '.health' || echo "unknown")
  if [[ "$health" == "true" ]]; then
    echo "✓ etcd is healthy"
    break
  fi
  sleep 2
done

echo ""
echo "Step 7: Add pgpatroni-1 to cluster..."
add_resp=$(curl -fsS -X POST "http://10.50.1.5:2379/v2/members" \
  -H "Content-Type: application/json" \
  -d '{"peerURLs": ["http://10.50.1.4:2380"]}' 2>&1 || echo "failed")

if echo "$add_resp" | grep -q "member"; then
  echo "✓ Member added successfully"
  echo "$add_resp" | jq '.' || echo "$add_resp"
else
  echo "⚠ Member add response: $add_resp"
fi

echo ""
echo "Step 8: Update pgpatroni-1's etcd config..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo bash" <<'EOF'
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
EOF

echo ""
echo "Step 9: Start etcd on pgpatroni-1..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl start etcd"
sleep 5

echo ""
echo "Step 10: Verify etcd health on both nodes..."
for ip in 10.50.1.4 10.50.1.5; do
  health=$(curl -fsS "http://$ip:2379/health" 2>/dev/null | jq -r '.health' || echo "unknown")
  if [[ "$health" == "true" ]]; then
    echo "✓ $ip: etcd healthy"
  else
    echo "⚠ $ip: etcd health unknown"
  fi
done

echo ""
echo "Step 11: Start Patroni on both nodes..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo systemctl start patroni" || true
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl start patroni" || true
sleep 10

echo ""
echo "=== Final Verification ==="
echo "Members from 10.50.1.4:"
curl -s http://10.50.1.4:2379/v2/members 2>/dev/null | jq -r '.members[] | "  - \(.name // "unnamed"): id=\(.id[0:8])..."' || echo "  (failed)"
echo ""
echo "Members from 10.50.1.5:"
curl -s http://10.50.1.5:2379/v2/members 2>/dev/null | jq -r '.members[] | "  - \(.name // "unnamed"): id=\(.id[0:8])..."' || echo "  (failed)"

echo ""
echo "=== Done! ==="
echo "Test cluster:"
echo "  curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo bash"

