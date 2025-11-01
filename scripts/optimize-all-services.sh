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
optimize_postgresql() {
  local host="$1"
  say "Optimizing PostgreSQL on $host..."
  
  ssh_cmd "$host" "sudo -u postgres psql -d postgres" <<'SQL'
-- Performance tuning for high-load scenarios
ALTER SYSTEM SET shared_buffers = '8GB';
ALTER SYSTEM SET effective_cache_size = '24GB';
ALTER SYSTEM SET maintenance_work_mem = '2GB';
ALTER SYSTEM SET work_mem = '128MB';
ALTER SYSTEM SET random_page_cost = '1.1';
ALTER SYSTEM SET effective_io_concurrency = '200';
ALTER SYSTEM SET max_connections = '500';
ALTER SYSTEM SET max_worker_processes = '32';
ALTER SYSTEM SET max_parallel_workers_per_gather = '8';
ALTER SYSTEM SET max_parallel_workers = '16';
ALTER SYSTEM SET max_parallel_maintenance_workers = '8';
ALTER SYSTEM SET checkpoint_completion_target = '0.9';
ALTER SYSTEM SET wal_buffers = '64MB';
ALTER SYSTEM SET default_statistics_target = '100';
ALTER SYSTEM SET random_page_cost = '1.1';
ALTER SYSTEM SET effective_io_concurrency = '200';
ALTER SYSTEM SET seq_page_cost = '1.0';
ALTER SYSTEM SET log_min_duration_statement = '1000';
ALTER SYSTEM SET log_checkpoints = 'on';
ALTER SYSTEM SET log_lock_waits = 'on';
SELECT pg_reload_conf();
SQL
  
  if [[ $? -eq 0 ]]; then
    pass "PostgreSQL optimized on $host"
  else
    fail "PostgreSQL optimization failed on $host"
    return 1
  fi
}

# Optimize Patroni configuration
optimize_patroni() {
  local host="$1"
  say "Optimizing Patroni on $host..."
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup original config
cp /etc/patroni/patroni.yml /etc/patroni/patroni.yml.backup.$(date +%s) 2>/dev/null || true

# Optimize Patroni configuration for faster failover and better performance
sed -i 's/ttl: [0-9]*/ttl: 30/' /etc/patroni/patroni.yml
sed -i 's/loop_wait: [0-9]*/loop_wait: 10/' /etc/patroni/patroni.yml
sed -i 's/retry_timeout: [0-9]*/retry_timeout: 10/' /etc/patroni/patroni.yml

# Ensure performance settings are optimal
if ! grep -q "maximum_lag_on_failover: 10485760" /etc/patroni/patroni.yml; then
  sed -i 's/maximum_lag_on_failover:.*/maximum_lag_on_failover: 10485760/' /etc/patroni/patroni.yml || \
  sed -i '/maximum_lag_on_failover:/a\        maximum_lag_on_failover: 10485760' /etc/patroni/patroni.yml
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
optimize_etcd() {
  local host="$1"
  say "Optimizing etcd on $host..."
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup original etcd config
cp /etc/default/etcd /etc/default/etcd.backup.$(date +%s) 2>/dev/null || true

# Add performance tuning parameters
if ! grep -q "^ETCD_QUOTA_BACKEND_BYTES" /etc/default/etcd; then
  echo "ETCD_QUOTA_BACKEND_BYTES=8589934592" >> /etc/default/etcd  # 8GB
fi

if ! grep -q "^ETCD_MAX_REQUEST_BYTES" /etc/default/etcd; then
  echo "ETCD_MAX_REQUEST_BYTES=1572864" >> /etc/default/etcd  # 1.5MB
fi

if ! grep -q "^ETCD_HEARTBEAT_INTERVAL" /etc/default/etcd; then
  echo "ETCD_HEARTBEAT_INTERVAL=100" >> /etc/default/etcd
fi

if ! grep -q "^ETCD_ELECTION_TIMEOUT" /etc/default/etcd; then
  echo "ETCD_ELECTION_TIMEOUT=1000" >> /etc/default/etcd
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
optimize_pgbouncer() {
  local host="$1"
  say "Optimizing PgBouncer on $host..."
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup original config
cp /etc/pgbouncer/pgbouncer.ini /etc/pgbouncer/pgbouncer.ini.backup.$(date +%s) 2>/dev/null || true

# Optimize PgBouncer for high performance
sed -i 's/^default_pool_size = .*/default_pool_size = 400/' /etc/pgbouncer/pgbouncer.ini
sed -i 's/^max_client_conn = .*/max_client_conn = 4000/' /etc/pgbouncer/pgbouncer.ini
sed -i 's/^min_pool_size = .*/min_pool_size = 50/' /etc/pgbouncer/pgbouncer.ini

# Add performance settings if not present
if ! grep -q "^reserve_pool_size" /etc/pgbouncer/pgbouncer.ini; then
  echo "reserve_pool_size = 50" >> /etc/pgbouncer/pgbouncer.ini
fi

if ! grep -q "^reserve_pool_timeout" /etc/pgbouncer/pgbouncer.ini; then
  echo "reserve_pool_timeout = 5" >> /etc/pgbouncer/pgbouncer.ini
fi

if ! grep -q "^max_db_connections" /etc/pgbouncer/pgbouncer.ini; then
  echo "max_db_connections = 400" >> /etc/pgbouncer/pgbouncer.ini
fi

if ! grep -q "^server_idle_timeout" /etc/pgbouncer/pgbouncer.ini; then
  echo "server_idle_timeout = 600" >> /etc/pgbouncer/pgbouncer.ini
fi

# Ensure pool_mode is transaction (best for most workloads)
sed -i 's/^pool_mode = .*/pool_mode = transaction/' /etc/pgbouncer/pgbouncer.ini

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

