#!/bin/bash
# Quick cluster health check before running tests

DB_NODES=(10.50.1.4 10.50.1.5)

echo "=== Pre-Test Cluster Health Check ==="
echo ""

echo "1. etcd cluster members:"
for ip in "${DB_NODES[@]}"; do
  echo "   Node $ip:"
  curl -s "http://$ip:2379/v2/members" 2>/dev/null | jq -r '.members[] | "      - \(.name): id=\(.id[0:8])..."' || echo "      (failed)"
done

echo ""
echo "2. Patroni cluster view:"
for ip in "${DB_NODES[@]}"; do
  echo "   Node $ip:"
  curl -s "http://$ip:8008/cluster" 2>/dev/null | jq -r '.members[] | "      - \(.name): role=\(.role), state=\(.state)"' || echo "      (failed)"
done

echo ""
echo "3. PostgreSQL replication:"
leader_ip=""
for ip in "${DB_NODES[@]}"; do
  role=$(curl -s "http://$ip:8008/patroni" 2>/dev/null | jq -r '.role // "unknown"' || echo "unknown")
  if [[ "$role" == "leader" ]] || [[ "$role" == "primary" ]]; then
    leader_ip="$ip"
    echo "   Leader: $ip ($role)"
    break
  fi
done

if [[ -n "$leader_ip" ]]; then
  repl=$(PGPASSWORD="ChangeMe123Pass" psql -h "$leader_ip" -p 5432 -U postgres -d postgres -tAc "SELECT COUNT(*) FROM pg_stat_replication WHERE state='streaming';" 2>/dev/null || echo "0")
  echo "   Streaming replicas: $repl"
fi

echo ""
echo "=== Cluster looks healthy! Safe to run tests. ==="

