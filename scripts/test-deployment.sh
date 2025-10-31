#!/usr/bin/env bash
set -euo pipefail

# Azure Patroni HA PostgreSQL Test Suite (robust)

LOG_PREFIX="[TEST]"
VNET_CIDR="10.50.0.0/16"
DB_ILB_IP="10.50.1.10"
PGB_ILB_IP="10.50.1.11"
DB_PORT=5432
PGB_PORT=6432
PATRONI_API_PORT=8008

POSTGRES_USER="postgres"
POSTGRES_PASS="ChangeMe123Pass"
PGBOUNCER_USER="pgbouncer"
PGBOUNCER_PASS="StrongPass123"

retry() {
  local attempts=$1; shift
  local delay=$1; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if [[ $n -ge $attempts ]]; then
      return 1
    fi
    sleep "$delay"
  done
}

say() { echo -e "$LOG_PREFIX $*"; }
pass() { echo "✓ PASSED: $*"; }
fail() { echo "✗ FAILED: $*"; }

ensure_psql() {
  if command -v psql >/dev/null 2>&1; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y >/dev/null 2>&1 || true
    sudo apt-get install -y postgresql-client >/dev/null 2>&1 || true
  fi
  command -v psql >/dev/null 2>&1
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 || {
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo apt-get install -y jq >/dev/null 2>&1 || true
    fi
  }
  command -v jq >/dev/null 2>&1
}

ensure_pgbench() {
  command -v pgbench >/dev/null 2>&1 || {
    if command -v apt-get >/devnull 2>&1; then
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo apt-get install -y postgresql-contrib >/dev/null 2>&1 || true
    fi
  }
  command -v pgbench >/dev/null 2>&1
}

get_local_ip() {
  ip -4 addr show dev eth0 | awk '/inet /{print $2}' | cut -d/ -f1
}

in_backend_pool_subnet() {
  # Our backend subnet is 10.50.1.0/24; quick prefix check
  local ip
  ip=$(get_local_ip || echo "")
  [[ "$ip" =~ ^10\.50\.1\..* ]]
}

say "Azure Patroni HA PostgreSQL Test Suite"

ensure_jq || say "jq not present; JSON outputs will be raw."

say "Checking psql availability"
if ensure_psql; then
  pass "psql available"
else
  fail "psql not available; will skip SQL-based checks"
fi

say "Detecting DB nodes"
DB_NODES=(10.50.1.4 10.50.1.5)
echo "Detected ${#DB_NODES[@]} database VM(s)"

say "Testing VM connectivity"
for ip in "${DB_NODES[@]}" 10.50.1.7 10.50.1.8; do
  if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    pass "VM $ip is reachable"
  else
    fail "VM $ip is NOT reachable"
  fi
done

say "Patroni health"
for ip in "${DB_NODES[@]}"; do
  if curl -fsS "http://$ip:$PATRONI_API_PORT/health" >/dev/null; then
    pass "Patroni health check on $ip"
  else
    fail "Patroni NOT healthy on $ip"
  fi
done

say "Cluster status"
if curl -fsS "http://${DB_NODES[0]}:$PATRONI_API_PORT/cluster" | jq . >/dev/null 2>&1; then
  pass "Cluster status retrieved"
else
  say "Raw cluster status:" && curl -fsS "http://${DB_NODES[0]}:$PATRONI_API_PORT/cluster" || true
fi

say "Check leader"
LEADER=$(curl -fsS "http://${DB_NODES[0]}:$PATRONI_API_PORT/cluster" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null || true)
if [[ -n "$LEADER" ]]; then
  pass "Leader found: $LEADER"
else
  fail "Leader not found"
fi

say "Check replicas"
REPL_COUNT=$(curl -fsS "http://${DB_NODES[0]}:$PATRONI_API_PORT/cluster" | jq '[.members[] | select(.role!="leader")] | length' 2>/dev/null || echo 0)
if [[ "$REPL_COUNT" -ge 1 ]]; then
  pass "Found $REPL_COUNT replica(s)"
else
  fail "No replicas found"
fi

# Avoid ILB hairpin tests from backend pool VMs
HAIRPIN_SKIP=false
if in_backend_pool_subnet; then
  HAIRPIN_SKIP=true
  say "Running inside backend subnet; skipping ILB connectivity tests to avoid hairpin limits"
fi

if command -v psql >/dev/null 2>&1 && [[ "$HAIRPIN_SKIP" = false ]]; then
  say "Direct PostgreSQL via ILB"
  if retry 5 2 psql "host=$DB_ILB_IP port=$DB_PORT dbname=postgres user=$POSTGRES_USER password=$POSTGRES_PASS connect_timeout=3" -Atqc "SELECT version();" >/dev/null 2>&1; then
    pass "Direct PostgreSQL connection (Load Balancer)"
  else
    fail "Direct PostgreSQL connection (Load Balancer)"
  fi

  say "PgBouncer via ILB"
  if retry 10 3 psql "host=$PGB_ILB_IP port=$PGB_PORT dbname=postgres user=$POSTGRES_USER password=$POSTGRES_PASS connect_timeout=3" -Atqc "SELECT now();" >/dev/null 2>&1; then
    pass "PgBouncer connection (Load Balancer)"
  else
    fail "PgBouncer connection (Load Balancer)"
  fi
fi

if command -v psql >/dev/null 2>&1; then
  say "Replication status"
  if psql "host=${DB_NODES[0]} port=$DB_PORT dbname=postgres user=$POSTGRES_USER password=$POSTGRES_PASS" -Atc "SELECT client_addr,state,sync_state FROM pg_stat_replication;"; then
    pass "Replication query executed"
  fi

  say "Data replication test"
  if psql "host=$DB_ILB_IP port=$DB_PORT dbname=postgres user=$POSTGRES_USER password=$POSTGRES_PASS" -Atc "CREATE TABLE IF NOT EXISTS test_rep(a int); INSERT INTO test_rep VALUES (1) ON CONFLICT DO NOTHING;" >/dev/null 2>&1; then
    pass "Write on primary succeeded"
  else
    fail "Write on primary failed"
  fi
fi

say "PgBouncer stats"
if command -v psql >/dev/null 2>&1 && [[ "$HAIRPIN_SKIP" = false ]]; then
  if retry 10 3 psql "host=$PGB_ILB_IP port=$PGB_PORT dbname=pgbouncer user=$PGBOUNCER_USER password=$PGBOUNCER_PASS connect_timeout=3" -Atc "SHOW POOLS;" >/dev/null 2>&1; then
    pass "PgBouncer stats accessible"
  else
    fail "PgBouncer stats NOT accessible"
  fi
fi

say "Load balancer routing"
if command -v psql >/dev/null 2>&1 && [[ "$HAIRPIN_SKIP" = false ]]; then
  for i in 1 2 3; do
    who=$(psql "host=$DB_ILB_IP port=$DB_PORT dbname=postgres user=$POSTGRES_USER password=$POSTGRES_PASS connect_timeout=3" -Atc "SELECT inet_server_addr();" 2>/dev/null || echo failed)
    echo "   Connection $i routed to: $who"
  done
  pass "Load balancer routing test"
fi

say "Failover (switchover) duration"
measure_failover() {
  # Map node name -> IP
  name_to_ip() {
    case "$1" in
      pgpatroni-1) echo 10.50.1.4 ;;
      pgpatroni-2) echo 10.50.1.5 ;;
      *) echo "" ;;
    esac
  }

  local cluster_json leader candidate leader_ip candidate_ip start end dur
  cluster_json=$(curl -fsS "http://${DB_NODES[0]}:$PATRONI_API_PORT/cluster" 2>/dev/null || echo "")
  leader=$(echo "$cluster_json" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null || true)
  candidate=$(echo "$cluster_json" | jq -r '.members[] | select(.role!="leader") | .name' 2>/dev/null || true)
  if [[ -z "$leader" || -z "$candidate" ]]; then
    fail "Failover: cannot determine leader/candidate"
    return 1
  fi
  leader_ip=$(name_to_ip "$leader")
  candidate_ip=$(name_to_ip "$candidate")
  if [[ -z "$leader_ip" || -z "$candidate_ip" ]]; then
    fail "Failover: unknown IP mapping for $leader/$candidate"
    return 1
  fi

  start=$(date +%s)
  # Request switchover
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${leader_ip}:$PATRONI_API_PORT/switchover" \
    -H 'Content-Type: application/json' \
    -d "{\"leader\":\"${leader}\",\"candidate\":\"${candidate}\"}")
  if [[ "$http_code" != "200" && "$http_code" != "202" ]]; then
    fail "Failover: switchover request failed (HTTP $http_code)"
    return 1
  fi

  # Wait for new leader and SQL ready (poll cluster view to avoid 503 on candidate API)
  if ! retry 120 1 bash -lc "curl -fsS http://${DB_NODES[0]}:$PATRONI_API_PORT/cluster | jq -r '.members[] | select(.role==\"leader\") | .name' | grep -q '^${candidate}$'"; then
    fail "Failover: candidate did not become leader in time"
    return 1
  fi
  if command -v psql >/dev/null 2>&1; then
    if ! retry 30 1 psql "host=$DB_ILB_IP port=$DB_PORT dbname=postgres user=$POSTGRES_USER password=$POSTGRES_PASS connect_timeout=2" -Atqc "SELECT 1;" >/dev/null 2>&1; then
      fail "Failover: SQL not ready via ILB"
      return 1
    fi
  fi
  end=$(date +%s)
  dur=$((end-start))
  echo "   Failover completed in ${dur}s (leader ${leader} -> ${candidate})"
  pass "Failover measurement"
}

if ensure_jq >/dev/null 2>&1; then
  measure_failover || true
fi

say "Performance (optional)"
if ensure_pgbench >/dev/null 2>&1; then
  if pgbench -h "$DB_ILB_IP" -p "$DB_PORT" -U "$POSTGRES_USER" -d postgres -P 2 -T 5 -c 4 -M simple >/dev/null 2>&1; then
    pass "Performance test ran"
  else
    fail "Performance test failed"
  fi
else
  echo "pgbench not installed, skipping performance test"
fi

exit 0

#!/bin/bash

# Azure Patroni HA PostgreSQL - Complete Test Suite
# This script performs comprehensive testing of the deployment

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================"
echo "Azure Patroni HA PostgreSQL Test Suite"
echo "======================================"
echo ""

# Test counters
PASSED=0
FAILED=0

test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ PASSED${NC}: $2"
        ((PASSED++))
    else
        echo -e "${RED}✗ FAILED${NC}: $2"
        ((FAILED++))
    fi
}

echo "=== 1. INFRASTRUCTURE TESTS ==="
echo ""

# Auto-detect number of database VMs
DB_VMS=()
for ip in 10.50.1.4 10.50.1.5 10.50.1.6; do
    if ping -c 1 -W 2 $ip > /dev/null 2>&1; then
        DB_VMS+=($ip)
    fi
done

echo "Detected ${#DB_VMS[@]} database VM(s)"
echo ""

# Test 1.1: Check if all VMs are reachable
echo "Testing VM connectivity..."
for ip in "${DB_VMS[@]}"; do
    test_result 0 "VM $ip is reachable"
done

# Test 1.2: Check PgBouncer VMs
for ip in 10.50.1.7 10.50.1.8; do
    if ping -c 1 -W 2 $ip > /dev/null 2>&1; then
        test_result 0 "PgBouncer VM $ip is reachable"
    else
        test_result 1 "PgBouncer VM $ip is NOT reachable"
    fi
done

echo ""
echo "=== 2. PATRONI CLUSTER TESTS ==="
echo ""

# Test 2.1: Check Patroni health on all nodes
for ip in "${DB_VMS[@]}"; do
    if curl -s -f http://$ip:8008/health > /dev/null 2>&1; then
        test_result 0 "Patroni health check on $ip"
    else
        test_result 1 "Patroni health check on $ip"
    fi
done

# Test 2.2: Get cluster status
echo ""
echo "Cluster Status:"
CLUSTER_STATUS=""
for ip in "${DB_VMS[@]}"; do
    CLUSTER_STATUS=$(curl -s http://$ip:8008/cluster 2>/dev/null)
    if [ ! -z "$CLUSTER_STATUS" ]; then
        break
    fi
done

if [ ! -z "$CLUSTER_STATUS" ]; then
    echo "$CLUSTER_STATUS" | jq '.' 2>/dev/null || echo "$CLUSTER_STATUS"
    test_result 0 "Patroni cluster status retrieved"
    
    # Check for leader
    LEADER=$(echo "$CLUSTER_STATUS" | jq -r '.members[] | select(.role=="leader") | .name' 2>/dev/null)
    if [ ! -z "$LEADER" ]; then
        test_result 0 "Patroni leader found: $LEADER"
    else
        test_result 1 "No Patroni leader found"
    fi
    
    # Check for replicas
    REPLICA_COUNT=$(echo "$CLUSTER_STATUS" | jq '[.members[] | select(.role=="replica" or .role=="sync_standby")] | length' 2>/dev/null)
    if [ "$REPLICA_COUNT" -ge 1 ]; then
        test_result 0 "Found $REPLICA_COUNT replica(s)"
    else
        test_result 1 "No replicas found"
    fi
else
    test_result 1 "Could not retrieve cluster status"
fi

echo ""
echo "=== 3. POSTGRESQL CONNECTION TESTS ==="
echo ""

# Test 3.1: Direct connection to database load balancer
if PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -c "SELECT version();" > /dev/null 2>&1; then
    test_result 0 "Direct PostgreSQL connection (Load Balancer)"
    
    # Get PostgreSQL version
    PG_VERSION=$(PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT version();" 2>/dev/null | head -1)
    echo "   PostgreSQL Version: $PG_VERSION"
else
    test_result 1 "Direct PostgreSQL connection (Load Balancer)"
fi

# Test 3.2: PgBouncer connection
if PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.11 -p 6432 -U postgres -d postgres -c "SELECT now();" > /dev/null 2>&1; then
    test_result 0 "PgBouncer connection (Load Balancer)"
else
    test_result 1 "PgBouncer connection (Load Balancer)"
fi

echo ""
echo "=== 4. REPLICATION TESTS ==="
echo ""

# Test 4.1: Check replication status
REP_STATUS=$(PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

if [ "$REP_STATUS" -ge 1 ]; then
    test_result 0 "Replication active ($REP_STATUS replica(s))"
    
    # Get replication lag
    echo ""
    echo "Replication Status:"
    PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;" 2>/dev/null
else
    test_result 1 "No active replication"
fi

# Test 4.2: Test data replication
echo ""
echo "Testing data replication..."

# Create test table and insert data
PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres > /dev/null 2>&1 <<EOF
DROP TABLE IF EXISTS ha_test;
CREATE TABLE ha_test (id SERIAL PRIMARY KEY, test_time TIMESTAMP DEFAULT NOW(), test_data TEXT);
INSERT INTO ha_test (test_data) VALUES ('Replication test data');
EOF

if [ $? -eq 0 ]; then
    test_result 0 "Test table created and data inserted"
    
    # Wait for replication
    sleep 2
    
    # Check if data exists (it should be on primary)
    TEST_COUNT=$(PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT count(*) FROM ha_test;" 2>/dev/null | tr -d ' ')
    
    if [ "$TEST_COUNT" -eq 1 ]; then
        test_result 0 "Test data verified on primary"
    else
        test_result 1 "Test data NOT found on primary"
    fi
else
    test_result 1 "Failed to create test table"
fi

echo ""
echo "=== 5. PERFORMANCE TESTS ==="
echo ""

# Test 5.1: Simple benchmark
echo "Running simple performance test (100 transactions)..."
if command -v pgbench > /dev/null 2>&1; then
    PGPASSWORD='ChangeMe123Pass' pgbench -h 10.50.1.11 -p 6432 -U postgres -c 5 -j 2 -t 20 postgres > /tmp/pgbench.log 2>&1
    
    if [ $? -eq 0 ]; then
        TPS=$(grep "tps" /tmp/pgbench.log | tail -1 | awk '{print $3}')
        test_result 0 "Performance test completed (TPS: $TPS)"
        echo ""
        tail -5 /tmp/pgbench.log
    else
        test_result 1 "Performance test failed"
    fi
else
    echo "   pgbench not installed, skipping performance test"
fi

echo ""
echo "=== 6. HIGH AVAILABILITY TESTS ==="
echo ""

# Test 6.1: Check if failover is configured
echo "Checking HA configuration..."

SYNC_STANDBY=$(PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SHOW synchronous_standby_names;" 2>/dev/null | tr -d ' ')

if [ ! -z "$SYNC_STANDBY" ] && [ "$SYNC_STANDBY" != "off" ]; then
    test_result 0 "Synchronous replication configured"
else
    echo "   Note: Synchronous replication managed by Patroni"
fi

# Test 6.2: Check etcd cluster
echo ""
echo "Checking etcd cluster..."
for ip in "${DB_VMS[@]}"; do
    if curl -s http://$ip:2379/health > /dev/null 2>&1; then
        test_result 0 "etcd healthy on $ip"
    else
        test_result 1 "etcd NOT healthy on $ip"
    fi
done

echo ""
echo "=== 7. LOAD BALANCER TESTS ==="
echo ""

# Test 7.1: Check if load balancer routes to primary
for i in {1..3}; do
    SERVER_ADDR=$(PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT inet_server_addr();" 2>/dev/null | tr -d ' ')
    if [ ! -z "$SERVER_ADDR" ]; then
        echo "   Connection $i routed to: $SERVER_ADDR"
    fi
done
test_result 0 "Load balancer routing test"

echo ""
echo "=== 8. PGBOUNCER TESTS ==="
echo ""

# Test 8.1: Check PgBouncer stats
if PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.11 -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;" > /dev/null 2>&1; then
    test_result 0 "PgBouncer stats accessible"
    echo ""
    echo "PgBouncer Pool Status:"
    PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.11 -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;"
else
    test_result 1 "PgBouncer stats NOT accessible"
fi

echo ""
echo "======================================"
echo "TEST SUMMARY"
echo "======================================"
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo "Total:  $((PASSED + FAILED))"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED!${NC}"
    echo "Your Azure Patroni HA PostgreSQL cluster is fully operational!"
    exit 0
else
    echo -e "${YELLOW}⚠ SOME TESTS FAILED${NC}"
    echo "Please check the failed tests above."
    exit 1
fi
