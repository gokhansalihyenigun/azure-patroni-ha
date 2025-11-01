#!/bin/bash
# Direct etcd start bypassing systemd

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Direct etcd Start (bypassing systemd) ==="
echo ""

echo "Step 1: Check etcd systemd service file..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "cat /lib/systemd/system/etcd.service || cat /etc/systemd/system/etcd.service || echo 'Service file not found'"

echo ""
echo "Step 2: Check etcd binary location..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "which etcd || find /usr -name etcd -type f 2>/dev/null | head -1"

echo ""
echo "Step 3: Kill any existing etcd processes..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo pkill -9 etcd 2>/dev/null || true; sleep 2"

echo ""
echo "Step 4: Check recent etcd errors..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo journalctl -u etcd -n 30 --no-pager | tail -20"

echo ""
echo "Step 5: Try starting etcd directly (will show errors)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 "sudo bash" <<'EOF'
# Source environment from /etc/default/etcd
set -a
. /etc/default/etcd
set +a

# Ensure data directory exists
mkdir -p "$ETCD_DATA_DIR" 2>/dev/null || mkdir -p /var/lib/etcd/default.etcd
chmod 755 /var/lib/etcd/default.etcd 2>/dev/null || true

# Try to start etcd directly
echo "Starting etcd with:"
echo "  NAME: $ETCD_NAME"
echo "  DATA_DIR: ${ETCD_DATA_DIR:-/var/lib/etcd/default.etcd}"
echo "  CLUSTER: $ETCD_INITIAL_CLUSTER"
echo "  STATE: $ETCD_INITIAL_CLUSTER_STATE"

timeout 15 /usr/bin/etcd \
  --name "$ETCD_NAME" \
  --initial-cluster-token "$ETCD_INITIAL_CLUSTER_TOKEN" \
  --initial-cluster "$ETCD_INITIAL_CLUSTER" \
  --initial-cluster-state "$ETCD_INITIAL_CLUSTER_STATE" \
  --initial-advertise-peer-urls "$ETCD_INITIAL_ADVERTISE_PEER_URLS" \
  --advertise-client-urls "$ETCD_ADVERTISE_CLIENT_URLS" \
  --listen-peer-urls "$ETCD_LISTEN_PEER_URLS" \
  --listen-client-urls "$ETCD_LISTEN_CLIENT_URLS" \
  --data-dir "${ETCD_DATA_DIR:-/var/lib/etcd/default.etcd}" 2>&1 | head -30 || \
  echo "Direct start failed or timed out"
EOF

echo ""
echo "=== If direct start worked, we can configure systemd service ==="
echo "Check if etcd is running:"
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "ps aux | grep etcd | grep -v grep || echo 'No etcd process'"

echo ""
echo "Check if etcd is listening:"
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "ss -lntp | grep -E '2379|2380' || echo 'No etcd ports listening'"

