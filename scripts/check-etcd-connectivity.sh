#!/bin/bash
# Quick check for etcd connectivity

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo "[CHECK] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Checking etcd connectivity and cluster status..."
say ""

# Check if each node can reach other node's etcd
for host in "${DB_NODES[@]}"; do
  say "=== From Node: $host ==="
  for other_host in "${DB_NODES[@]}"; do
    if [[ "$host" != "$other_host" ]]; then
      say "  Checking etcd on $other_host:2379..."
      result=$(ssh_cmd "$host" "curl -fsS http://$other_host:2379/health 2>&1" || echo "FAILED")
      if echo "$result" | grep -q '"health":"true"'; then
        say "    ✓ Can reach etcd on $other_host"
      else
        say "    ✗ CANNOT reach etcd on $other_host"
        say "    Error: ${result:0:200}"
      fi
    fi
  done
  
  # Check local etcd
  local_health=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:2379/health 2>&1" || echo "FAILED")
  if echo "$local_health" | grep -q '"health":"true"'; then
    say "  ✓ Local etcd is healthy"
  else
    say "  ✗ Local etcd is NOT healthy"
  fi
  
  # Check etcd cluster members
  say "  etcd cluster members:"
  members=$(ssh_cmd "$host" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1" || echo "failed")
  if echo "$members" | grep -q "failed\|error"; then
    say "    Could not list members (etcdctl might not be available)"
  else
    echo "$members" | sed 's/^/    /'
  fi
  
  echo ""
done

say "Checking Patroni config for etcd hosts..."
for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  etcd_hosts=$(ssh_cmd "$host" "sudo grep -A1 'etcd:' /etc/patroni/patroni.yml | grep 'hosts:' | sed 's/.*hosts://' | tr -d ' ' || echo 'not found'")
  say "  etcd hosts in config: $etcd_hosts"
done

