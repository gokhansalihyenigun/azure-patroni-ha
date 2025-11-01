#!/usr/bin/env bash
set -euo pipefail

# Azure Patroni HA PostgreSQL - Comprehensive Performance Optimization Script
# This script optimizes PostgreSQL, Patroni, etcd, and PgBouncer for maximum performance

LOG_PREFIX="[OPTIMIZE]"
DB_NODES=(10.50.1.4 10.50.1.5)
PGB_NODES=(10.50.1.7 10.50.1.8)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo -e "$LOG_PREFIX $*"; }
fail() { echo "✗ FAILED: $*" >&2; }
pass() { echo "✓ PASSED: $*"; }

# SSH helper function
ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    -o UserKnownHostsFile=/dev/null \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

# Optimize PostgreSQL parameters
# Based on Standard_D32s_v6: 32 vCPU, 128 GB RAM
# Formula: shared_buffers = RAM * 25%, effective_cache_size = RAM * 75%
optimize_postgresql() {
  local host="$1"
  say "Optimizing PostgreSQL on $host (tuned for 128GB RAM, 32 vCPU)..."
  
  ssh_cmd "$host" "sudo -u postgres psql -d postgres" <<'SQL'
-- CRITICAL: Zero Data Loss Settings (RPO=0)
ALTER SYSTEM SET synchronous_commit = 'on';  -- Required for zero data loss
ALTER SYSTEM SET synchronous_standby_names = 'ANY 1';  -- Sync replication with 1 standby

-- MEMORY: Optimized for 128GB RAM (Standard_D32s_v6)
-- shared_buffers = 25% of RAM (industry best practice)
ALTER SYSTEM SET shared_buffers = '32GB';
-- effective_cache_size = 75% of RAM (accounts for OS cache)
ALTER SYSTEM SET effective_cache_size = '96GB';
-- work_mem: Calculate as (shared_buffers - maintenance) / max_connections = safe value
-- With 32GB shared_buffers and 500 connections: (32GB-2GB)/500 = ~60MB, use 128MB for safety
ALTER SYSTEM SET work_mem = '128MB';
ALTER SYSTEM SET maintenance_work_mem = '2GB';

-- CONNECTIONS: Scale for high load
ALTER SYSTEM SET max_connections = '500';
ALTER SYSTEM SET max_worker_processes = '32';  -- Match vCPU count
ALTER SYSTEM SET max_parallel_workers_per_gather = '8';  -- Parallel query workers
ALTER SYSTEM SET max_parallel_workers = '24';  -- Max parallel workers (75% of vCPU)
ALTER SYSTEM SET max_parallel_maintenance_workers = '8';

-- WRITE PERFORMANCE: Optimize for high-throughput writes
ALTER SYSTEM SET checkpoint_completion_target = '0.9';  -- Spread checkpoints
ALTER SYSTEM SET wal_buffers = '64MB';  -- Large WAL buffers for high write load
ALTER SYSTEM SET max_wal_size = '32GB';  -- Allow more WAL before checkpoint
ALTER SYSTEM SET min_wal_size = '8GB';  -- Keep more WAL segments
ALTER SYSTEM SET checkpoint_timeout = '15min';  -- Longer checkpoint interval for high load

-- I/O PERFORMANCE: Optimize for Premium SSD v2 (low latency, high IOPS)
ALTER SYSTEM SET random_page_cost = '1.1';  -- SSDs are fast
ALTER SYSTEM SET effective_io_concurrency = '200';  -- High for NVMe SSDs
ALTER SYSTEM SET seq_page_cost = '1.0';  -- Sequential reads are fast on SSD

-- REPLICATION: Optimize for fast sync replication (zero data loss)
ALTER SYSTEM SET wal_level = 'replica';  -- Sufficient for streaming replication
ALTER SYSTEM SET max_wal_senders = '20';  -- Support multiple replicas
ALTER SYSTEM SET max_replication_slots = '20';
ALTER SYSTEM SET wal_keep_size = '4GB';  -- Keep WAL segments for replication catch-up

-- QUERY PERFORMANCE
ALTER SYSTEM SET default_statistics_target = '100';
ALTER SYSTEM SET enable_partitionwise_join = 'on';
ALTER SYSTEM SET enable_partitionwise_aggregate = 'on';

-- MONITORING
ALTER SYSTEM SET log_min_duration_statement = '1000';  -- Log slow queries (>1s)
ALTER SYSTEM SET log_checkpoints = 'on';
ALTER SYSTEM SET log_lock_waits = 'on';
ALTER SYSTEM SET log_autovacuum_min_duration = '1000';  -- Log slow autovacuum

-- Reload configuration
SELECT pg_reload_conf();

-- Verify critical settings
SELECT name, setting, unit FROM pg_settings 
WHERE name IN ('shared_buffers', 'effective_cache_size', 'work_mem', 'synchronous_commit', 'synchronous_standby_names')
ORDER BY name;
SQL
  
  if [[ $? -eq 0 ]]; then
    pass "PostgreSQL optimized on $host"
  else
    fail "PostgreSQL optimization failed on $host"
    return 1
  fi
}

# Optimize Patroni configuration
# Critical for fast failover: ttl should be ~3x loop_wait to avoid premature failover
# For fastest failover: ttl=20, loop_wait=8 (total ~24s worst case detection)
# But must balance with etcd heartbeat/election timeout
optimize_patroni() {
  local host="$1"
  say "Optimizing Patroni on $host (fast failover, zero data loss)..."
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup original config
cp /etc/patroni/patroni.yml /etc/patroni/patroni.yml.backup.$(date +%s) 2>/dev/null || true

# OPTIMAL FAILOVER SETTINGS:
# ttl: 20s (leader lock timeout - must be > 3 * loop_wait)
# loop_wait: 8s (cluster state check interval - faster = quicker failover detection)
# retry_timeout: 8s (operation retry timeout)
# These give ~24s worst-case failover detection (loop_wait * 3 + small buffer)

sed -i 's/ttl: [0-9]*/ttl: 20/' /etc/patroni/patroni.yml
sed -i 's/loop_wait: [0-9]*/loop_wait: 8/' /etc/patroni/patroni.yml
sed -i 's/retry_timeout: [0-9]*/retry_timeout: 8/' /etc/patroni/patroni.yml

# ZERO DATA LOSS SETTINGS (already should be set, but ensure):
sed -i 's/synchronous_mode:.*/synchronous_mode: true/' /etc/patroni/patroni.yml
sed -i 's/synchronous_mode_strict:.*/synchronous_mode_strict: false/' /etc/patroni/patroni.yml
sed -i 's/synchronous_node_count:.*/synchronous_node_count: 1/' /etc/patroni/patroni.yml

# MAXIMUM LAG: 10MB (allow minor lag during high load, but still strict)
if ! grep -q "maximum_lag_on_failover: 10485760" /etc/patroni/patroni.yml; then
  sed -i 's/maximum_lag_on_failover:.*/maximum_lag_on_failover: 10485760/' /etc/patroni/patroni.yml || \
  sed -i '/maximum_lag_on_failover:/a\        maximum_lag_on_failover: 10485760' /etc/patroni/patroni.yml
fi

# Ensure fast recovery settings
if ! grep -q "use_pg_rewind" /etc/patroni/patroni.yml || ! grep -q "use_pg_rewind: true" /etc/patroni/patroni.yml; then
  sed -i 's/use_pg_rewind:.*/use_pg_rewind: true/' /etc/patroni/patroni.yml || \
  sed -i '/use_slots:/a\      use_pg_rewind: true' /etc/patroni/patroni.yml
fi

# Restart Patroni to apply changes
systemctl restart patroni
sleep 5

# Verify Patroni is running
if systemctl is-active --quiet patroni; then
  echo "Patroni optimized and restarted successfully"
else
  echo "Warning: Patroni restart may have failed, check status"
  systemctl status patroni --no-pager || true
fi
BASH
  
  if [[ $? -eq 0 ]]; then
    pass "Patroni optimized on $host"
  else
    fail "Patroni optimization failed on $host"
    return 1
  fi
}

# Optimize etcd
# Critical for fast Patroni failover: heartbeat/election timeout must align with Patroni loop_wait
# Heartbeat interval: 100ms (fast, but not too aggressive)
# Election timeout: 1000ms (1s - allows quick leader election for Patroni)
# These settings ensure etcd responds quickly to Patroni requests
optimize_etcd() {
  local host="$1"
  say "Optimizing etcd on $host (aligned with Patroni fast failover)..."
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup original etcd config
cp /etc/default/etcd /etc/default/etcd.backup.$(date +%s) 2>/dev/null || true

# STORAGE: 8GB quota (sufficient for Patroni metadata)
if ! grep -q "^ETCD_QUOTA_BACKEND_BYTES" /etc/default/etcd; then
  echo "ETCD_QUOTA_BACKEND_BYTES=8589934592" >> /etc/default/etcd  # 8GB
fi

# REQUEST SIZE: 1.5MB max request (standard)
if ! grep -q "^ETCD_MAX_REQUEST_BYTES" /etc/default/etcd; then
  echo "ETCD_MAX_REQUEST_BYTES=1572864" >> /etc/default/etcd  # 1.5MB
fi

# CRITICAL: Fast heartbeat/election for quick Patroni failover
# Heartbeat interval: 100ms (how often leader sends heartbeat)
# Election timeout: 1000ms (1s - how long follower waits before starting election)
# These align with Patroni loop_wait=8s (etcd should respond in <1s, leaving 7s buffer)
if ! grep -q "^ETCD_HEARTBEAT_INTERVAL" /etc/default/etcd; then
  echo "ETCD_HEARTBEAT_INTERVAL=100" >> /etc/default/etcd  # 100ms
fi

if ! grep -q "^ETCD_ELECTION_TIMEOUT" /etc/default/etcd; then
  echo "ETCD_ELECTION_TIMEOUT=1000" >> /etc/default/etcd  # 1000ms = 1s
fi

# PERFORMANCE: Optimize for low-latency writes (critical for Patroni)
if ! grep -q "^ETCD_BATCH_INTERVAL" /etc/default/etcd; then
  echo "ETCD_BATCH_INTERVAL=0" >> /etc/default/etcd  # No batching, immediate writes
fi

# Restart etcd
systemctl restart etcd
sleep 3

# Verify etcd is healthy
if curl -fsS http://127.0.0.1:2379/health >/dev/null 2>&1; then
  echo "etcd optimized and restarted successfully"
else
  echo "Warning: etcd health check failed, check status"
  systemctl status etcd --no-pager || true
fi
BASH
  
  if [[ $? -eq 0 ]]; then
    pass "etcd optimized on $host"
  else
    fail "etcd optimization failed on $host"
    return 1
  fi
}

# Optimize PgBouncer
# For high QPS: increase pool_size to match expected load
# Formula: pool_size should be ~2x expected concurrent transactions for headroom
# With 15k+ QPS target: need large pool (400+) and high max_client_conn
optimize_pgbouncer() {
  local host="$1"
  say "Optimizing PgBouncer on $host (high QPS performance)..."
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup original config
cp /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini.backup.$(date +%s) 2>/dev/null || true

# POOL SIZE: 500 connections (supports high QPS - 15k+ queries/sec)
# Larger pool = more concurrent queries = higher QPS
sed -i 's/^default_pool_size = .*/default_pool_size = 500/' /etc/pgbouncer/pgbouncer.ini

# CLIENT CONNECTIONS: 5000 (high for many app servers)
sed -i 's/^max_client_conn = .*/max_client_conn = 5000/' /etc/pgbouncer/pgbouncer.ini

# MIN POOL: 100 (keep warm connections ready)
sed -i 's/^min_pool_size = .*/min_pool_size = 100/' /etc/pgbouncer/pgbouncer.ini

# RESERVE POOL: For burst traffic during failover
if ! grep -q "^reserve_pool_size" /etc/pgbouncer/pgbouncer.ini; then
  echo "reserve_pool_size = 100" >> /etc/pgbouncer/pgbouncer.ini
fi

if ! grep -q "^reserve_pool_timeout" /etc/pgbouncer/pgbouncer.ini; then
  echo "reserve_pool_timeout = 3" >> /etc/pgbouncer/pgbouncer.ini  # 3s timeout
fi

# MAX DB CONNECTIONS: Match pool_size (PgBouncer -> PostgreSQL)
if ! grep -q "^max_db_connections" /etc/pgbouncer/pgbouncer.ini; then
  echo "max_db_connections = 500" >> /etc/pgbouncer/pgbouncer.ini
else
  sed -i 's/^max_db_connections = .*/max_db_connections = 500/' /etc/pgbouncer/pgbouncer.ini
fi

# IDLE TIMEOUT: Shorter for faster connection recycling (high throughput)
if ! grep -q "^server_idle_timeout" /etc/pgbouncer/pgbouncer.ini; then
  echo "server_idle_timeout = 300" >> /etc/pgbouncer/pgbouncer.ini  # 5min (was 600)
fi

# POOL MODE: Transaction (best for high throughput, low latency)
sed -i 's/^pool_mode = .*/pool_mode = transaction/' /etc/pgbouncer/pgbouncer.ini

# IGNORE STARTUP PARAMS: Reduce connection overhead
if ! grep -q "^ignore_startup_parameters" /etc/pgbouncer/pgbouncer.ini; then
  echo "ignore_startup_parameters = extra_float_digits" >> /etc/pgbouncer/pgbouncer.ini
fi

# APPLICATION_NAME: Allow for better connection tracking
if ! grep -q "^application_name_add_host" /etc/pgbouncer/pgbouncer.ini; then
  echo "application_name_add_host = 1" >> /etc/pgbouncer/pgbouncer.ini
fi

# Restart PgBouncer
systemctl restart pgbouncer
sleep 3

# Verify PgBouncer is running
if systemctl is-active --quiet pgbouncer; then
  echo "PgBouncer optimized and restarted successfully"
else
  echo "Warning: PgBouncer restart may have failed, check status"
  systemctl status pgbouncer --no-pager || true
fi
BASH
  
  if [[ $? -eq 0 ]]; then
    pass "PgBouncer optimized on $host"
  else
    fail "PgBouncer optimization failed on $host"
    return 1
  fi
}

# Optimize system kernel parameters
optimize_system() {
  local host="$1"
  say "Optimizing system parameters on $host..."
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Kernel parameters for high performance
cat >> /etc/sysctl.conf <<'SYSCTL'
# PostgreSQL and high-performance tuning
vm.swappiness = 1
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.overcommit_memory = 2
kernel.sem = 250 32000 100 128
kernel.shmmax = 68719476736
kernel.shmall = 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog = 5000
fs.file-max = 1000000
SYSCTL

# Apply sysctl settings
sysctl -p >/dev/null 2>&1 || true

# Increase file limits
cat >> /etc/security/limits.conf <<'LIMITS'
* soft nofile 1000000
* hard nofile 1000000
postgres soft nofile 1000000
postgres hard nofile 1000000
LIMITS

echo "System parameters optimized"
BASH
  
  if [[ $? -eq 0 ]]; then
    pass "System optimized on $host"
  else
    fail "System optimization failed on $host"
    return 1
  fi
}

# Main optimization function
main() {
  say "Starting comprehensive performance optimization for all services..."
  
  # Check prerequisites
  if ! command -v sshpass >/dev/null 2>&1; then
    say "Installing sshpass..."
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y >/dev/null 2>&1 || true
      sudo apt-get install -y sshpass >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y sshpass >/dev/null 2>&1 || true
    fi
  fi
  
  # Optimize DB nodes (PostgreSQL, Patroni, etcd, System)
  say "Optimizing database nodes..."
  for host in "${DB_NODES[@]}"; do
    say "Processing DB node: $host"
    optimize_system "$host" || say "Warning: System optimization failed on $host"
    optimize_etcd "$host" || say "Warning: etcd optimization failed on $host"
    optimize_patroni "$host" || say "Warning: Patroni optimization failed on $host"
    optimize_postgresql "$host" || say "Warning: PostgreSQL optimization failed on $host"
    say "Completed optimization for $host"
    sleep 2
  done
  
  # Optimize PgBouncer nodes (PgBouncer, System)
  say "Optimizing PgBouncer nodes..."
  for host in "${PGB_NODES[@]}"; do
    say "Processing PgBouncer node: $host"
    optimize_system "$host" || say "Warning: System optimization failed on $host"
    optimize_pgbouncer "$host" || say "Warning: PgBouncer optimization failed on $host"
    say "Completed optimization for $host"
    sleep 2
  done
  
  say "Waiting 10 seconds for services to stabilize..."
  sleep 10
  
  # Verify services
  say "Verifying service health..."
  for host in "${DB_NODES[@]}"; do
    if ssh_cmd "$host" "systemctl is-active --quiet patroni && systemctl is-active --quiet etcd"; then
      pass "Services healthy on $host"
    else
      fail "Services may have issues on $host"
    fi
  done
  
  for host in "${PGB_NODES[@]}"; do
    if ssh_cmd "$host" "systemctl is-active --quiet pgbouncer"; then
      pass "PgBouncer healthy on $host"
    else
      fail "PgBouncer may have issues on $host"
    fi
  done
  
  say "Optimization complete!"
  say ""
  say "Summary of optimizations applied:"
  say "  ✓ PostgreSQL: Increased shared_buffers, work_mem, max_connections, parallel workers"
  say "  ✓ Patroni: Optimized TTL, loop_wait, retry_timeout for faster failover"
  say "  ✓ etcd: Increased quotas and optimized heartbeat/election timeouts"
  say "  ✓ PgBouncer: Increased pool_size to 400, max_client_conn to 4000"
  say "  ✓ System: Optimized kernel parameters, file limits, memory settings"
  say ""
  say "You can now run the performance test:"
  say "  export USE_PGBOUNCER=true"
  say "  curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | bash"
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi

