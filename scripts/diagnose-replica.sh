#!/bin/bash
# Diagnose why replica is not replicating

ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="ChangeMe123Pass"

echo "=== Diagnosing Replica Issue ==="
echo ""

echo "1. Check pgpatroni-1 Patroni status..."
curl -s http://10.50.1.4:8008/patroni | jq '{role, state, postgresql_state, timeline}' || echo "Failed"

echo ""
echo "2. Check pgpatroni-1 PostgreSQL process..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 \
  "sudo systemctl status postgresql --no-pager | head -15 || ps aux | grep postgres | grep -v grep | head -3" || true

echo ""
echo "3. Check pgpatroni-1 PostgreSQL connection..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 \
  "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc 'SELECT 1;' 2>&1 || echo 'PostgreSQL not accessible locally'"

echo ""
echo "4. Check pgpatroni-1 Patroni logs (recent errors)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.4 \
  "sudo journalctl -u patroni -n 50 --no-pager | grep -iE 'error|fail|replica|replication' | tail -20" || true

echo ""
echo "5. Check replication slot from leader..."
PGPASSWORD="$POSTGRES_PASS" psql -h 10.50.1.5 -p 5432 -U postgres -d postgres <<'SQL'
SELECT 
  slot_name,
  plugin,
  slot_type,
  active,
  database,
  restart_lsn
FROM pg_replication_slots
ORDER BY slot_name;
SQL

echo ""
echo "6. Check pg_hba.conf on leader (replication access)..."
sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no azureuser@10.50.1.5 \
  "sudo grep -E 'replication|replicator' /pgdata/pg_hba.conf 2>/dev/null | head -5 || echo 'pg_hba.conf not found or no replication rules'"

echo ""
echo "=== Possible fixes ==="
echo "If PostgreSQL is not running on pgpatroni-1, try:"
echo "  sshpass -p '$ADMIN_PASS' ssh azureuser@10.50.1.4 'sudo systemctl restart patroni'"
echo ""
echo "If replication slot missing, Patroni should create it automatically."
echo "Wait a few minutes and check again."

