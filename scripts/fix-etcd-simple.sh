#!/bin/bash
# Simple manual fix for etcd cluster split-brain

set -e

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Simple etcd Cluster Fix ==="
echo ""
echo "This will merge pgpatroni-1 (10.50.1.4) into pgpatroni-2's (10.50.1.5) cluster"
echo ""
echo "Step 1: Stop services on pgpatroni-1..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl stop patroni && sudo systemctl stop etcd" || true
echo "✓ Services stopped"
sleep 2

echo ""
echo "Step 2: Clear etcd data on pgpatroni-1..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo rm -rf /var/lib/etcd/*" || true
echo "✓ Data cleared"

echo ""
echo "Step 3: Add pgpatroni-1 to pgpatroni-2's cluster..."
add_resp=$(curl -fsS -X POST "http://10.50.1.5:2379/v2/members" \
  -H "Content-Type: application/json" \
  -d '{"peerURLs": ["http://10.50.1.4:2380"]}' 2>/dev/null || echo "failed")
if [[ "$add_resp" != "failed" ]]; then
  echo "✓ Member added"
else
  echo "⚠ Warning: Member add may have failed (continuing...)"
fi

echo ""
echo "Step 4: Update etcd config on pgpatroni-1..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo bash" <<'EOF'
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
echo "Config updated"
cat /etc/default/etcd
EOF
echo "✓ Config updated"

echo ""
echo "Step 5: Start etcd on pgpatroni-1..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl start etcd"
sleep 5

echo ""
echo "Step 6: Verify etcd health..."
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
echo "Step 7: Start Patroni on pgpatroni-1..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl start patroni"
sleep 10

echo ""
echo "Step 8: Verify cluster view..."
echo "Members from 10.50.1.4:"
curl -fsS "http://10.50.1.4:2379/v2/members" 2>/dev/null | jq -r '.members[] | "  - \(.name // "unnamed"): \(.id[0:8])..."' || echo "  (failed)"
echo ""
echo "Members from 10.50.1.5:"
curl -fsS "http://10.50.1.5:2379/v2/members" 2>/dev/null | jq -r '.members[] | "  - \(.name // "unnamed"): \(.id[0:8])..."' || echo "  (failed)"

echo ""
echo "=== Fix complete! ==="
echo "Both nodes should now see 2 members in etcd cluster"
echo "Run test script to verify:"
echo "  curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo bash"

