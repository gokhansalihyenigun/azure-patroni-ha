#!/bin/bash
# Manual split-brain fix - run commands step by step
# This is a simpler version that shows what needs to be done

NODE1_IP="10.50.1.4"
NODE2_IP="10.50.1.5"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

echo "======================================"
echo "MANUAL SPLIT-BRAIN FIX GUIDE"
echo "======================================"
echo ""
echo "Follow these steps to fix split-brain:"
echo ""

echo "=== Step 1: SSH to replica node (pgpatroni-2) ==="
echo "Run: ssh azureuser@$NODE2_IP"
echo "Password: $ADMIN_PASS"
echo ""

echo "=== Step 2: On replica node, stop Patroni ==="
echo "sudo systemctl stop patroni"
echo ""

echo "=== Step 3: Clear data directories ==="
echo "sudo rm -rf /pgdata/* /pgwal/*"
echo ""

echo "=== Step 4: Ensure etcd is running ==="
echo "sudo systemctl restart etcd"
echo "sleep 3"
echo "curl -fsS http://localhost:2379/health"
echo ""

echo "=== Step 5: Start Patroni ==="
echo "sudo systemctl start patroni"
echo ""

echo "=== Step 6: Wait and verify (from any node) ==="
echo "sleep 30"
echo "curl -s http://$NODE1_IP:8008/cluster | jq '.members[]'"
echo ""

echo "=== OR: Quick one-liner (from testvm2) ==="
echo ""
echo "sshpass -p '$ADMIN_PASS' ssh -o StrictHostKeyChecking=no azureuser@$NODE2_IP 'sudo systemctl stop patroni && sudo rm -rf /pgdata/* /pgwal/* && sudo systemctl restart etcd && sleep 3 && sudo systemctl start patroni'"
echo ""
echo "Then wait 30 seconds and check:"
echo "curl -s http://$NODE1_IP:8008/cluster | jq '.members[]'"

