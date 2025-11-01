#!/bin/bash
# Correct etcd fix: Start pgpatroni-2 alone, then add pgpatroni-1

set -eo pipefail

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "=== Correct etcd Cluster Fix ==="
echo ""

echo "Step 1: Stop all services..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl stop patroni etcd 2>&1 || true" || true
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo systemctl stop patroni etcd 2>&1 || true" || true
sleep 2

echo ""
echo "Step 2: Clear etcd data on both nodes..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo rm -rf /var/lib/etcd/* 2>&1 || true" || true
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo rm -rf /var/lib/etcd/* 2>&1 || true" || true
echo "✓ Data cleared"

echo ""
echo "Step 3: Configure pgpatroni-2 as single-node cluster (temporarily)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo bash" <<'EOF'
cat > /etc/default/etcd <<'CFG'
ETCD_NAME="pgpatroni-2"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="pgpatroni-2=http://10.50.1.5:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.50.1.5:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.50.1.5:2379"
ETCD_LISTEN_PEER_URLS="http://10.50.1.5:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://10.50.1.5:2379"
CFG
echo "✓ Config updated"
cat /etc/default/etcd
EOF

echo ""
echo "Step 4: Start etcd on pgpatroni-2 (single node)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo systemctl start etcd"
sleep 8

echo ""
echo "Step 5: Verify pgpatroni-2's etcd is healthy..."
for i in {1..15}; do
  health=$(curl -fsS "http://10.50.1.5:2379/health" 2>/dev/null | jq -r '.health' || echo "unknown")
  if [[ "$health" == "true" ]]; then
    echo "✓ etcd is healthy"
    break
  fi
  if [[ $i -eq 15 ]]; then
    echo "✗ etcd health check failed"
    echo "Checking etcd status..."
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "${ADMIN_USER}@10.50.1.5" "sudo systemctl status etcd --no-pager | head -20" || true
    exit 1
  fi
  sleep 2
done

echo ""
echo "Step 6: Check current members (should be only pgpatroni-2)..."
curl -s http://10.50.1.5:2379/v2/members | jq '.members[] | {name, id}' || echo "Failed to get members"

echo ""
echo "Step 7: Add pgpatroni-1 to cluster..."
add_resp=$(curl -fsS -X POST "http://10.50.1.5:2379/v2/members" \
  -H "Content-Type: application/json" \
  -d '{"peerURLs": ["http://10.50.1.4:2380"]}' 2>&1 || echo "failed")

if echo "$add_resp" | grep -qE "member|id"; then
  echo "✓ Member added successfully"
  echo "$add_resp" | jq '.' || echo "$add_resp"
else
  echo "⚠ Member add response: $add_resp"
  echo "Checking members again..."
  curl -s http://10.50.1.5:2379/v2/members | jq '.members[] | {name, id, peerURLs}' || true
fi

echo ""
echo "Step 8: Update pgpatroni-2's config to include both members..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo bash" <<'EOF'
cat > /etc/default/etcd <<'CFG'
ETCD_NAME="pgpatroni-2"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
ETCD_INITIAL_CLUSTER_STATE="existing"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.50.1.5:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.50.1.5:2379"
ETCD_LISTEN_PEER_URLS="http://10.50.1.5:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://10.50.1.5:2379"
CFG
echo "✓ Config updated"
EOF

echo ""
echo "Step 9: Update pgpatroni-1's config..."
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
echo "Step 10: Restart etcd on pgpatroni-2 (to apply new config)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.5" "sudo systemctl restart etcd"
sleep 5

echo ""
echo "Step 11: Start etcd on pgpatroni-1..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  "${ADMIN_USER}@10.50.1.4" "sudo systemctl start etcd"
sleep 8

echo ""
echo "Step 12: Verify etcd health on both nodes..."
for ip in 10.50.1.4 10.50.1.5; do
  for i in {1..10}; do
    health=$(curl -fsS "http://$ip:2379/health" 2>/dev/null | jq -r '.health' || echo "unknown")
    if [[ "$health" == "true" ]]; then
      echo "✓ $ip: etcd healthy"
      break
    fi
    if [[ $i -eq 10 ]]; then
      echo "⚠ $ip: etcd health check failed"
    fi
    sleep 2
  done
done

echo ""
echo "Step 13: Start Patroni on both nodes..."
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

