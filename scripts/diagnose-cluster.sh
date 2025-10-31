#!/bin/bash
# Comprehensive cluster diagnostic script

set -euo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
PGB_NODES=(10.50.1.7 10.50.1.8)
PATRONI_API_PORT=8008
ETCD_PORT=2379

echo "======================================"
echo "CLUSTER DIAGNOSTICS"
echo "======================================"
echo ""

echo "=== 1. PATRONI CLUSTER STATUS ==="
for ip in "${DB_NODES[@]}"; do
  echo ""
  echo "--- Node: $ip ---"
  cluster_json=$(curl -fsS "http://$ip:$PATRONI_API_PORT/cluster" 2>/dev/null || echo "{}")
  if [[ "$cluster_json" == "{}" ]]; then
    echo "✗ Cannot reach Patroni API"
    continue
  fi
  
  echo "Members:"
  echo "$cluster_json" | jq -r '.members[] | "  \(.name): \(.role) - \(.state) - Timeline: \(.timeline // "unknown")"' 2>/dev/null || echo "  (Error parsing)"
  
  echo "Leader:"
  leader=$(echo "$cluster_json" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null || echo "none")
  echo "  $leader"
  
  echo "Replicas:"
  replicas=$(echo "$cluster_json" | jq -r '.members[] | select(.role!="leader") | "  \(.name): \(.role) - \(.state)"' 2>/dev/null || echo "  none")
  echo "$replicas"
done

echo ""
echo "=== 2. ETSD CLUSTER STATUS ==="
for ip in "${DB_NODES[@]}"; do
  echo ""
  echo "--- etcd at $ip:$ETCD_PORT ---"
  health=$(curl -fsS "http://$ip:$ETCD_PORT/health" 2>/dev/null || echo "{}")
  if [[ "$health" == "{}" ]]; then
    echo "✗ Cannot reach etcd"
  else
    echo "$health"
  fi
done

echo ""
echo "=== 3. POSTGRESQL REPLICATION STATUS ==="
leader_ip=""
for ip in "${DB_NODES[@]}"; do
  cluster_json=$(curl -fsS "http://$ip:$PATRONI_API_PORT/cluster" 2>/dev/null || echo "{}")
  leader_name=$(echo "$cluster_json" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null || echo "")
  if [[ -n "$leader_name" ]]; then
    [[ "$leader_name" == "pgpatroni-1" ]] && leader_ip="10.50.1.4"
    [[ "$leader_name" == "pgpatroni-2" ]] && leader_ip="10.50.1.5"
    break
  fi
done

if [[ -z "$leader_ip" ]]; then
  echo "✗ Cannot determine leader IP"
else
  echo "Leader IP: $leader_ip"
  echo ""
  echo "Replication status from leader:"
  PGPASSWORD='ChangeMe123Pass' psql -h "$leader_ip" -p 5432 -U postgres -d postgres \
    -c "SELECT application_name, client_addr, state, sync_state, sync_priority, replay_lag FROM pg_stat_replication;" 2>/dev/null || echo "✗ Cannot query replication"
fi

echo ""
echo "=== 4. PGBOUNCER STATUS ==="
for ip in "${PGB_NODES[@]}"; do
  echo ""
  echo "--- PgBouncer VM: $ip ---"
  # Check if PgBouncer service is running
  sshpass -p 'Azure123!@#' ssh -o StrictHostKeyChecking=no azureuser@"$ip" \
    "sudo systemctl status pgbouncer --no-pager 2>&1 | head -10 || echo 'Service check failed'" 2>/dev/null || echo "✗ Cannot SSH to $ip"
  
  # Check if port 6432 is listening
  if timeout 2 bash -c "echo > /dev/tcp/$ip/6432" 2>/dev/null; then
    echo "✓ Port 6432 is listening"
  else
    echo "✗ Port 6432 is NOT listening"
  fi
done

echo ""
echo "=== 5. PGBOUNCER ILB CONNECTIVITY ==="
PGB_ILB_IP="10.50.1.11"
if timeout 2 bash -c "echo > /dev/tcp/$PGB_ILB_IP/6432" 2>/dev/null; then
  echo "✓ ILB port 6432 is reachable"
  echo "Testing connection..."
  if PGPASSWORD='ChangeMe123Pass' timeout 5 psql -h "$PGB_ILB_IP" -p 6432 -U postgres -d postgres -c "SELECT 1;" 2>/dev/null; then
    echo "✓ PgBouncer ILB connection successful"
  else
    echo "✗ PgBouncer ILB connection failed"
  fi
else
  echo "✗ ILB port 6432 is NOT reachable"
fi

echo ""
echo "=== 6. RECOMMENDATIONS ==="
echo ""
# Check if we have replicas
has_replicas=false
for ip in "${DB_NODES[@]}"; do
  cluster_json=$(curl -fsS "http://$ip:$PATRONI_API_PORT/cluster" 2>/dev/null || echo "{}")
  replica_count=$(echo "$cluster_json" | jq '[.members[] | select(.role!="leader")] | length' 2>/dev/null || echo 0)
  if [[ "$replica_count" -ge 1 ]]; then
    has_replicas=true
    break
  fi
done

if [[ "$has_replicas" == "false" ]]; then
  echo "⚠ No replicas found. Possible causes:"
  echo "  1. Second node (pgpatroni-2) may still be initializing"
  echo "  2. Replication slot limit may be reached on leader"
  echo "  3. Network connectivity issues between nodes"
  echo "  4. etcd cluster not properly formed"
  echo ""
  echo "Recommended actions:"
  echo "  1. Check Patroni logs on pgpatroni-2:"
  echo "     ssh azureuser@10.50.1.5 'sudo journalctl -u patroni -n 50'"
  echo ""
  echo "  2. Check PostgreSQL connection limits on leader:"
  echo "     ssh azureuser@10.50.1.4 'PGPASSWORD=ChangeMe123Pass psql -h localhost -U postgres -c \"SHOW max_connections; SHOW max_wal_senders; SHOW max_replication_slots;\"'"
  echo ""
  echo "  3. Check etcd cluster health:"
  echo "     ssh azureuser@10.50.1.4 'curl -s http://localhost:2379/health'"
fi

echo ""
echo "Diagnostics complete."
