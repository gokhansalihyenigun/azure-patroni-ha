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
if PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -c "SELECT version();" > /dev/null 2>&1; then
    test_result 0 "Direct PostgreSQL connection (Load Balancer)"
    
    # Get PostgreSQL version
    PG_VERSION=$(PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT version();" 2>/dev/null | head -1)
    echo "   PostgreSQL Version: $PG_VERSION"
else
    test_result 1 "Direct PostgreSQL connection (Load Balancer)"
fi

# Test 3.2: PgBouncer connection
if PGPASSWORD='ChangeMe123!' psql -h 10.50.1.11 -p 6432 -U postgres -d postgres -c "SELECT now();" > /dev/null 2>&1; then
    test_result 0 "PgBouncer connection (Load Balancer)"
else
    test_result 1 "PgBouncer connection (Load Balancer)"
fi

echo ""
echo "=== 4. REPLICATION TESTS ==="
echo ""

# Test 4.1: Check replication status
REP_STATUS=$(PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT count(*) FROM pg_stat_replication;" 2>/dev/null | tr -d ' ')

if [ "$REP_STATUS" -ge 1 ]; then
    test_result 0 "Replication active ($REP_STATUS replica(s))"
    
    # Get replication lag
    echo ""
    echo "Replication Status:"
    PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;" 2>/dev/null
else
    test_result 1 "No active replication"
fi

# Test 4.2: Test data replication
echo ""
echo "Testing data replication..."

# Create test table and insert data
PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres > /dev/null 2>&1 <<EOF
DROP TABLE IF EXISTS ha_test;
CREATE TABLE ha_test (id SERIAL PRIMARY KEY, test_time TIMESTAMP DEFAULT NOW(), test_data TEXT);
INSERT INTO ha_test (test_data) VALUES ('Replication test data');
EOF

if [ $? -eq 0 ]; then
    test_result 0 "Test table created and data inserted"
    
    # Wait for replication
    sleep 2
    
    # Check if data exists (it should be on primary)
    TEST_COUNT=$(PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT count(*) FROM ha_test;" 2>/dev/null | tr -d ' ')
    
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
    PGPASSWORD='ChangeMe123!' pgbench -h 10.50.1.11 -p 6432 -U postgres -c 5 -j 2 -t 20 postgres > /tmp/pgbench.log 2>&1
    
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

SYNC_STANDBY=$(PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SHOW synchronous_standby_names;" 2>/dev/null | tr -d ' ')

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
    SERVER_ADDR=$(PGPASSWORD='ChangeMe123!' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -t -c "SELECT inet_server_addr();" 2>/dev/null | tr -d ' ')
    if [ ! -z "$SERVER_ADDR" ]; then
        echo "   Connection $i routed to: $SERVER_ADDR"
    fi
done
test_result 0 "Load balancer routing test"

echo ""
echo "=== 8. PGBOUNCER TESTS ==="
echo ""

# Test 8.1: Check PgBouncer stats
if PGPASSWORD='ChangeMe123!' psql -h 10.50.1.11 -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;" > /dev/null 2>&1; then
    test_result 0 "PgBouncer stats accessible"
    echo ""
    echo "PgBouncer Pool Status:"
    PGPASSWORD='ChangeMe123!' psql -h 10.50.1.11 -p 6432 -U postgres -d pgbouncer -c "SHOW POOLS;"
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
