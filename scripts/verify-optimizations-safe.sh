#!/bin/bash
# Safe verification script - checks if optimizations broke anything

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[VERIFY] $*"; }
pass() { echo "✓ PASSED: $*"; }
fail() { echo "✗ FAILED: $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Verifying optimizations are safe and cluster is healthy..."
say ""

all_good=true

# Check 1: etcd health
say "=== Checking etcd health ==="
for host in "${DB_NODES[@]}"; do
  etcd_health=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:2379/health 2>/dev/null | jq -r '.health // \"unknown\"' || echo 'failed'")
  if [[ "$etcd_health" == "true" ]]; then
    pass "etcd healthy on $host"
  else
    fail "etcd unhealthy on $host ($etcd_health)"
    all_good=false
  fi
done

# Check 2: Patroni health and cluster view
say ""
say "=== Checking Patroni health and cluster view ==="
for host in "${DB_NODES[@]}"; do
  patroni_health=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/health 2>/dev/null && echo 'ok' || echo 'failed'")
  if [[ "$patroni_health" == "ok" ]]; then
    pass "Patroni healthy on $host"
    
    # Check cluster view
    members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
    if [[ "$members" == "2" ]]; then
      pass "Cluster view complete on $host ($members members)"
    else
      fail "Cluster view incomplete on $host ($members members, expected 2)"
      all_good=false
    fi
  else
    fail "Patroni unhealthy on $host"
    all_good=false
  fi
done

# Check 3: PostgreSQL running
say ""
say "=== Checking PostgreSQL status ==="
for host in "${DB_NODES[@]}"; do
  pg_running=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT 1;\" 2>/dev/null && echo 'ok' || echo 'failed'")
  if [[ "$pg_running" == "ok" ]]; then
    pass "PostgreSQL accessible on $host"
  else
    fail "PostgreSQL not accessible on $host"
    all_good=false
  fi
done

# Check 4: Replication status
say ""
say "=== Checking replication ==="
leader_ip=""
for host in "${DB_NODES[@]}"; do
  role=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | jq -r '.role // \"unknown\"' || echo 'unknown'")
  if [[ "$role" == "primary" ]] || [[ "$role" == "leader" ]]; then
    leader_ip="$host"
    say "Leader found: $host"
    break
  fi
done

if [[ -n "$leader_ip" ]]; then
  repl_count=$(ssh_cmd "$leader_ip" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT COUNT(*) FROM pg_stat_replication WHERE state='streaming';\" 2>/dev/null || echo '0'")
  if [[ "${repl_count:-0}" == "1" ]]; then
    pass "Replication active (1 replica streaming)"
  else
    fail "Replication issue ($repl_count replicas streaming, expected 1)"
    all_good=false
  fi
else
  fail "No leader found"
  all_good=false
fi

# Check 5: Optimized settings are applied
say ""
say "=== Checking optimized settings ==="
for host in "${DB_NODES[@]}"; do
  say "Node: $host"
  
  # Check Patroni loop_wait
  loop_wait=$(ssh_cmd "$host" "sudo grep 'loop_wait:' /etc/patroni/patroni.yml | awk '{print \$2}' || echo 'unknown'")
  if [[ "$loop_wait" == "5" ]]; then
    pass "loop_wait = 5s (optimized)"
  else
    say "  loop_wait = $loop_wait (expected 5)"
  fi
  
  # Check PostgreSQL max_parallel_workers
  max_par_workers=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_parallel_workers';\" 2>/dev/null || echo 'unknown'")
  if [[ "$max_par_workers" == "30" ]]; then
    pass "max_parallel_workers = 30 (optimized)"
  else
    say "  max_parallel_workers = $max_par_workers (expected 30, may need restart)"
  fi
  
  # Check max_wal_size
  max_wal=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"SELECT setting FROM pg_settings WHERE name='max_wal_size';\" 2>/dev/null || echo 'unknown'")
  if [[ "$max_wal" == "49152" ]] || [[ "$max_wal" == "48GB" ]] || [[ "$max_wal" =~ ^49152 ]]; then
    pass "max_wal_size = 48GB (optimized)"
  else
    say "  max_wal_size = $max_wal (expected 48GB, may need restart)"
  fi
  
  echo ""
done

say ""
if [[ "$all_good" == "true" ]]; then
  say "✓✓✓ ALL CHECKS PASSED - Cluster is healthy after optimization! ✓✓✓"
  exit 0
else
  fail "✗✗✗ SOME CHECKS FAILED - Review above and take action if needed ✗✗✗"
  exit 1
fi

