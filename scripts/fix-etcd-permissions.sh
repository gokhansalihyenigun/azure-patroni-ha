#!/bin/bash
# Fix etcd permissions and data directory

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Fixing etcd Permissions ==="
echo ""

echo "Step 1: Ensure etcd user exists..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo id etcd 2>/dev/null || sudo useradd -r -s /bin/false -d /var/lib/etcd etcd 2>/dev/null || echo 'etcd user exists or created'"

echo ""
echo "Step 2: Stop etcd..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo systemctl stop etcd && sudo pkill -9 etcd 2>/dev/null || true"
sleep 2

echo ""
echo "Step 3: Remove old data and create with correct permissions..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 "sudo bash" <<'EOF'
# Remove old data
rm -rf /var/lib/etcd/* /var/lib/etcd/default /var/lib/etcd/default.etcd 2>/dev/null || true

# Create directory with correct owner
mkdir -p /var/lib/etcd/default
chown etcd:etcd /var/lib/etcd/default
chmod 700 /var/lib/etcd/default

echo "✓ Data directory created with correct permissions"
ls -la /var/lib/etcd/
EOF

echo ""
echo "Step 4: Update etcd config (using default directory, not default.etcd)..."
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
ETCD_DATA_DIR="/var/lib/etcd/default"
CFG
echo "✓ Config updated"
cat /etc/default/etcd
EOF

echo ""
echo "Step 5: Start etcd..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo systemctl start etcd"
sleep 8

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

if [[ "$health" == "true" ]]; then
  echo ""
  echo "Step 8: Check members..."
  curl -s http://10.50.1.5:2379/v2/members | jq '.members[] | {name, id}'
  
  echo ""
  echo "✓✓✓ etcd is working! Now you can add pgpatroni-1 ==="
  echo ""
  echo "Next steps:"
  echo "1. Add pgpatroni-1: curl -X POST http://10.50.1.5:2379/v2/members -H 'Content-Type: application/json' -d '{\"peerURLs\": [\"http://10.50.1.4:2380\"]}'"
  echo "2. Update configs on both nodes"
  echo "3. Start etcd on pgpatroni-1"
  echo "4. Start Patroni on both nodes"
else
  echo "✗ etcd health check failed"
  echo "Recent logs:"
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
    "sudo journalctl -u etcd -n 20 --no-pager" || true
fi

