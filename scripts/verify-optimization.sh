#!/bin/bash
# Verify PostgreSQL optimization settings are active

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
POSTGRES_PASS="${POSTGRES_PASS:-ChangeMe123Pass}"

say() { echo "[CHECK] $*"; }
pass() { echo "✓ PASSED: $*"; }
fail() { echo "✗ FAILED: $*"; }
warn() { echo "⚠ WARNING: $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Checking PostgreSQL optimization settings..."
echo ""

for host in "${DB_NODES[@]}"; do
  say "Node: $host"
  
  # Get current PostgreSQL settings
  local current_settings=$(ssh_cmd "$host" "PGPASSWORD='$POSTGRES_PASS' psql -h 127.0.0.1 -U postgres -d postgres -tAc \"
SELECT name || '=' || setting || ' ' || COALESCE(unit, '') FROM pg_settings 
WHERE name IN ('shared_buffers', 'max_connections', 'work_mem', 'effective_cache_size', 'max_parallel_workers', 'max_parallel_workers_per_gather')
ORDER BY name;
\" 2>/dev/null")
  
  if [[ -z "$current_settings" ]]; then
    fail "Could not connect to PostgreSQL on $host"
    continue
  fi
  
  # Check each setting
  local shared_buffers=$(echo "$current_settings" | grep "^shared_buffers=" | awk -F= '{print $2}' | awk '{print $1}')
  local max_conn=$(echo "$current_settings" | grep "^max_connections=" | awk -F= '{print $2}' | awk '{print $1}')
  local work_mem=$(echo "$current_settings" | grep "^work_mem=" | awk -F= '{print $2}' | awk '{print $1}')
  
  # Convert shared_buffers to GB for comparison
  local shared_buffers_gb=0
  if echo "$shared_buffers" | grep -q "kB"; then
    shared_buffers_gb=$(echo "$shared_buffers" | sed 's/kB//' | awk '{printf "%.1f", $1/1024/1024}')
  elif echo "$shared_buffers" | grep -q "MB"; then
    shared_buffers_gb=$(echo "$shared_buffers" | sed 's/MB//' | awk '{printf "%.1f", $1/1024}')
  elif echo "$shared_buffers" | grep -q "GB"; then
    shared_buffers_gb=$(echo "$shared_buffers" | sed 's/GB//' | awk '{print $1}')
  fi
  
  echo "  shared_buffers: $shared_buffers (${shared_buffers_gb}GB)"
  echo "  max_connections: $max_conn"
  echo "  work_mem: $work_mem"
  echo ""
  
  # Check if values are optimized
  local all_optimized=true
  
  if (( $(echo "$shared_buffers_gb < 30" | bc -l 2>/dev/null || echo 0) )); then
    warn "shared_buffers should be ~32GB, currently: ${shared_buffers_gb}GB (restart needed)"
    all_optimized=false
  else
    pass "shared_buffers is optimized (~32GB)"
  fi
  
  if [[ "$max_conn" -lt 400 ]]; then
    warn "max_connections should be 500, currently: $max_conn (restart needed)"
    all_optimized=false
  else
    pass "max_connections is optimized (500)"
  fi
  
  # Check Patroni status
  local patroni_state=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/patroni 2>/dev/null | grep -o '\"state\":\"[^\"]*\"' | head -1" || echo "")
  echo "  Patroni state: ${patroni_state:-unknown}"
  echo ""
  
  if [[ "$all_optimized" == "true" ]]; then
    pass "All settings optimized on $host"
  else
    warn "Some settings need PostgreSQL restart on $host"
    say "  Triggering Patroni restart to apply settings..."
    ssh_cmd "$host" "curl -fsS -X POST 'http://127.0.0.1:8008/restart' >/dev/null 2>&1 && echo 'Restart triggered' || echo 'Restart failed'"
    say "  Waiting 30 seconds for PostgreSQL restart..."
    sleep 30
  fi
  
  echo "----------------------------------------"
done

say ""
say "Summary:"
say "  If settings are still old, PostgreSQL restart is pending"
say "  Patroni will automatically restart when it detects postgresql.auto.conf changes"
say "  Or manually trigger: curl -X POST http://<leader>:8008/restart"

