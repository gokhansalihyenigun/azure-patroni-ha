#!/bin/bash
# Direct etcd fix - check logs and start manually if needed

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Checking etcd status and logs on pgpatroni-2 ==="
echo ""
echo "etcd service status:"
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo systemctl status etcd --no-pager | head -30" || true

echo ""
echo "etcd logs (last 30 lines):"
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo journalctl -u etcd -n 30 --no-pager" || true

echo ""
echo "=== Trying to start etcd manually (foreground) to see errors ==="
echo "If this works, we'll set up systemd service correctly"

# Check if etcd config is correct
echo ""
echo "Current etcd config on pgpatroni-2:"
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "cat /etc/default/etcd" || true

echo ""
echo "=== Attempting direct etcd start (will show errors) ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 "sudo bash" <<'EOF'
# Stop systemd service
systemctl stop etcd 2>/dev/null || true

# Try to start etcd directly with timeout to see errors
timeout 10 sudo -u etcd /usr/bin/etcd --config-file /etc/etcd/etcd.conf 2>&1 || \
timeout 10 sudo -u etcd env $(cat /etc/default/etcd | grep -v '^#' | xargs) /usr/bin/etcd 2>&1 || \
timeout 10 /usr/bin/etcd --name pgpatroni-2 \
  --initial-cluster-token pg-ha-token \
  --initial-cluster pgpatroni-2=http://10.50.1.5:2380 \
  --initial-cluster-state new \
  --initial-advertise-peer-urls http://10.50.1.5:2380 \
  --advertise-client-urls http://10.50.1.5:2379 \
  --listen-peer-urls http://10.50.1.5:2380 \
  --listen-client-urls http://127.0.0.1:2379,http://10.50.1.5:2379 \
  --data-dir /var/lib/etcd/default.etcd 2>&1 | head -20 || true
EOF

echo ""
echo "=== Check etcd binary and permissions ==="
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "which etcd || find /usr -name etcd 2>/dev/null | head -3" || true

sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "ls -la /var/lib/etcd/ 2>/dev/null || echo 'Directory missing'" || true

echo ""
echo "=== If etcd can start manually, we'll fix systemd service ==="

