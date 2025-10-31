#!/bin/bash
# Check replica status and troubleshoot

NODE1_IP="10.50.1.4"
NODE2_IP="10.50.1.5"
POSTGRES_PASS="ChangeMe123Pass"

echo "=== Checking Cluster Status ==="
echo ""
curl -s http://$NODE1_IP:8008/cluster | jq '.members[]'
echo ""

echo "=== Checking Patroni Status on pgpatroni-2 ==="
echo ""
ssh -o StrictHostKeyChecking=no azureuser@$NODE2_IP 'sudo systemctl status patroni --no-pager | head -20' 2>&1 || echo "SSH failed"
echo ""

echo "=== Checking Patroni Logs on pgpatroni-2 (last 30 lines) ==="
echo ""
ssh -o StrictHostKeyChecking=no azureuser@$NODE2_IP 'sudo journalctl -u patroni -n 30 --no-pager' 2>&1 || echo "SSH failed"
echo ""

echo "=== Checking etcd on both nodes ==="
echo ""
echo "etcd on $NODE1_IP:"
curl -s http://$NODE1_IP:2379/health || echo "Failed"
echo ""
echo "etcd on $NODE2_IP:"
curl -s http://$NODE2_IP:2379/health || echo "Failed"
echo ""

echo "=== Checking Replication Status from Leader ==="
echo ""
PGPASSWORD="$POSTGRES_PASS" psql -h $NODE1_IP -p 5432 -U postgres -d postgres \
  -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;" 2>/dev/null || echo "Query failed"

