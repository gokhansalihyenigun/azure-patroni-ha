#!/bin/bash
# Complete etcd reset - kill processes, clean ALL data, restart fresh

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Complete etcd Reset ==="
echo ""

echo "Step 1: Kill all etcd processes..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 "sudo bash" <<'EOF'
systemctl stop etcd 2>/dev/null || true
systemctl stop patroni 2>/dev/null || true
pkill -9 etcd 2>/dev/null || true
sleep 2
ps aux | grep etcd | grep -v grep || echo "No etcd processes"
EOF

echo ""
echo "Step 2: Find and remove ALL etcd data directories..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 "sudo bash" <<'EOF'
# Remove all possible etcd data locations
rm -rf /var/lib/etcd/* 2>/dev/null || true
rm -rf /var/lib/etcd/default.etcd 2>/dev/null || true
find /var/lib/etcd -type f -delete 2>/dev/null || true
find /var/lib/etcd -type d -empty -delete 2>/dev/null || true
echo "✓ All etcd data removed"
ls -la /var/lib/etcd/ 2>/dev/null || echo "Directory is empty/removed"
EOF

echo ""
echo "Step 3: Set fresh config for single-node cluster..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 "sudo bash" <<'EOF'
cat > /etc/default/etcd <<'CFG'
ETCD_NAME="pgpatroni-2"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="pgpatroni-2=http://10.50.1.5:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.50.1.5:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.50.1.5:2379"
ETCD_LISTEN_PEER_URLS="http://10.50.1.5:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://10.50.1.5:2379"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
CFG
echo "✓ Config written"
cat /etc/default/etcd
EOF

echo ""
echo "Step 4: Create etcd data directory..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo mkdir -p /var/lib/etcd/default.etcd && sudo chown etcd:etcd /var/lib/etcd/default.etcd 2>/dev/null || sudo chmod 755 /var/lib/etcd/default.etcd"

echo ""
echo "Step 5: Start etcd (fresh cluster)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo systemctl start etcd"
sleep 10

echo ""
echo "Step 6: Check etcd status..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo systemctl status etcd --no-pager | head -15" || true

echo ""
echo "Step 7: Check etcd health..."
for i in {1..10}; do
  health=$(curl -fsS "http://10.50.1.5:2379/health" 2>/dev/null | jq -r '.health' || echo "unknown")
  if [[ "$health" == "true" ]]; then
    echo "✓ etcd is healthy!"
    break
  fi
  echo "  Attempt $i/10: health=$health"
  sleep 2
done

if [[ "$health" != "true" ]]; then
  echo "✗ etcd health check failed"
  echo "Recent logs:"
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
    "sudo journalctl -u etcd -n 20 --no-pager" || true
  exit 1
fi

echo ""
echo "Step 8: Check members (should be only pgpatroni-2)..."
curl -s http://10.50.1.5:2379/v2/members | jq '.members[] | {name, id}'

echo ""
echo "=== Next steps ==="
echo "1. Add pgpatroni-1 to cluster:"
echo "   curl -X POST http://10.50.1.5:2379/v2/members -H 'Content-Type: application/json' -d '{\"peerURLs\": [\"http://10.50.1.4:2380\"]}'"
echo ""
echo "2. Update both configs to include 2 members"
echo ""
echo "3. Start etcd on pgpatroni-1"
echo ""
echo "4. Start Patroni on both nodes"

