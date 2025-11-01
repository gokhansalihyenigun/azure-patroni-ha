#!/bin/bash
# Check PostgreSQL replication status

DB_NODES=(10.50.1.4 10.50.1.5)
POSTGRES_PASS="ChangeMe123Pass"

echo "=== PostgreSQL Replication Check ==="
echo ""

# Find leader
leader_ip=""
for ip in "${DB_NODES[@]}"; do
  role=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | jq -r '.role // "unknown"' || echo "unknown")
  if [[ "$role" == "leader" ]] || [[ "$role" == "primary" ]]; then
    leader_ip="$ip"
    echo "Leader found: $ip"
    break
  fi
done

if [[ -z "$leader_ip" ]]; then
  echo "✗ No leader found!"
  exit 1
fi

echo ""
echo "=== Replication status from leader ($leader_ip) ==="
PGPASSWORD="$POSTGRES_PASS" psql -h "$leader_ip" -p 5432 -U postgres -d postgres <<'SQL'
SELECT 
  application_name,
  client_addr,
  state,
  sync_state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  sync_priority
FROM pg_stat_replication
ORDER BY application_name;
SQL

echo ""
echo "=== Patroni cluster view ==="
for ip in "${DB_NODES[@]}"; do
  echo "Node $ip:"
  curl -s "http://$ip:8008/cluster" 2>/dev/null | jq -r '.members[] | "  \(.name): role=\(.role), state=\(.state), lag=\(.lag)"' || echo "  (failed)"
done

echo ""
echo "=== If no replicas found, possible causes: ==="
echo "1. Replica not fully started yet (wait a few minutes)"
echo "2. Replication user/password mismatch"
echo "3. Network connectivity issues"
echo "4. Patroni replication slot not created"

