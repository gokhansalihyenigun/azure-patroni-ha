#!/bin/bash
# Script to help diagnose and fix replica joining issues

set -euo pipefail

LEADER_IP="${1:-10.50.1.4}"
REPLICA_IP="${2:-10.50.1.5}"
REPLICA_NAME="pgpatroni-2"
POSTGRES_PASS="ChangeMe123Pass"

echo "======================================"
echo "REPLICA JOIN DIAGNOSTIC & FIX SCRIPT"
echo "======================================"
echo ""
echo "Leader: $LEADER_IP"
echo "Replica: $REPLICA_IP ($REPLICA_NAME)"
echo ""

# Step 1: Check leader status
echo "=== Step 1: Checking Leader Status ==="
cluster_json=$(curl -fsS "http://$LEADER_IP:8008/cluster" 2>/dev/null || echo "{}")
if [[ "$cluster_json" == "{}" ]]; then
  echo "✗ Cannot reach leader Patroni API"
  exit 1
fi

leader_name=$(echo "$cluster_json" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null || echo "")
if [[ -z "$leader_name" ]]; then
  echo "✗ No leader found"
  exit 1
fi
echo "✓ Leader found: $leader_name"
echo ""

# Step 2: Check replica status
echo "=== Step 2: Checking Replica Status ==="
replica_info=$(echo "$cluster_json" | jq -r ".members[] | select(.name==\"$REPLICA_NAME\") | \"\(.name): \(.role) - \(.state)\"" 2>/dev/null || echo "")
if [[ -z "$replica_info" ]]; then
  echo "✗ Replica $REPLICA_NAME not found in cluster"
else
  echo "Current status: $replica_info"
fi
echo ""

# Step 3: Check PostgreSQL connection limits on leader
echo "=== Step 3: Checking Connection Limits on Leader ==="
limits=$(PGPASSWORD="$POSTGRES_PASS" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres \
  -t -c "SELECT 'max_connections=' || setting FROM pg_settings WHERE name='max_connections' UNION ALL SELECT 'max_wal_senders=' || setting FROM pg_settings WHERE name='max_wal_senders' UNION ALL SELECT 'max_replication_slots=' || setting FROM pg_settings WHERE name='max_replication_slots';" 2>/dev/null || echo "")

if [[ -n "$limits" ]]; then
  echo "$limits"
else
  echo "✗ Cannot query connection limits"
fi

# Check replication slots
echo ""
echo "Replication slots:"
slot_info=$(PGPASSWORD="$POSTGRES_PASS" psql -h "$LEADER_IP" -p 5432 -U postgres -d postgres \
  -t -c "SELECT slot_name, slot_type, active FROM pg_replication_slots;" 2>/dev/null || echo "")
if [[ -n "$slot_info" ]]; then
  echo "$slot_info"
else
  echo "  (no slots found or cannot query)"
fi
echo ""

# Step 4: Check replica VM
echo "=== Step 4: Checking Replica VM ($REPLICA_IP) ==="
echo "SSH'ing to replica VM..."
echo ""
echo "Commands to run on replica VM:"
echo ""
echo "1. Check Patroni status:"
echo "   sudo systemctl status patroni --no-pager | head -20"
echo ""
echo "2. Check Patroni logs:"
echo "   sudo journalctl -u patroni -n 50 --no-pager"
echo ""
echo "3. Check etcd connectivity:"
echo "   curl -fsS http://$LEADER_IP:2379/health"
echo "   curl -fsS http://$REPLICA_IP:2379/health"
echo ""
echo "4. Check Patroni config:"
echo "   sudo cat /etc/patroni/patroni.yml | grep -E 'scope|name|hosts'"
echo ""
echo "5. If replica is stuck, try reinitialize:"
echo "   # First, check cluster status from leader:"
echo "   curl -fsS http://$LEADER_IP:8008/cluster | jq '.members[]'"
echo ""
echo "   # If replica exists but is stuck, force reinitialize:"
echo "   curl -X POST \"http://$REPLICA_IP:8008/reinitialize?force=1\""
echo ""
echo "6. Check PostgreSQL data directory:"
echo "   sudo ls -la /pgdata/"
echo "   sudo ls -la /pgwal/"
echo ""

# Step 5: Manual fix commands
echo "=== Step 5: Manual Fix Commands ==="
echo ""
echo "If replica is not joining, try these steps:"
echo ""
echo "On REPLICA VM ($REPLICA_IP):"
echo "1. Stop Patroni:"
echo "   sudo systemctl stop patroni"
echo ""
echo "2. Clear data directories (if needed):"
echo "   sudo rm -rf /pgdata/* /pgwal/*"
echo ""
echo "3. Ensure etcd is running:"
echo "   sudo systemctl restart etcd"
echo "   sleep 3"
echo "   curl -fsS http://localhost:2379/health"
echo ""
echo "4. Start Patroni:"
echo "   sudo systemctl start patroni"
echo "   sleep 10"
echo ""
echo "5. Check status:"
echo "   curl -fsS http://localhost:8008/cluster | jq '.members[]'"
echo ""
echo "On LEADER VM ($LEADER_IP):"
echo "1. Check replication status:"
echo "   PGPASSWORD='$POSTGRES_PASS' psql -h localhost -U postgres -c \"SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;\""
echo ""
echo "2. If replication slots are full, increase limits:"
echo "   PGPASSWORD='$POSTGRES_PASS' psql -h localhost -U postgres -c \"ALTER SYSTEM SET max_replication_slots = 30;\""
echo "   sudo systemctl restart patroni"
echo ""

echo "Script complete. Review the diagnostic information above."

