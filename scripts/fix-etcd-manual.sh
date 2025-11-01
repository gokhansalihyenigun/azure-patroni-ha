#!/bin/bash
# Manual fix for etcd cluster - add member explicitly if needed

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo "[FIX] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "Checking etcd cluster membership from both nodes..."
say ""

# Check from primary (10.50.1.5)
say "=== From PRIMARY (10.50.1.5) ==="
primary_members=$(ssh_cmd "10.50.1.5" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1" || echo "")
echo "$primary_members" | sed 's/^/  /'

say ""
say "=== From REPLICA (10.50.1.4) ==="
replica_members=$(ssh_cmd "10.50.1.4" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1" || echo "")
echo "$replica_members" | sed 's/^/  /'

say ""
say "Checking if we need to manually add member..."

# Check if 10.50.1.4 is in primary's member list
if echo "$primary_members" | grep -q "10.50.1.4"; then
  say "  ✓ 10.50.1.4 is already in cluster member list"
else
  say "  ✗ 10.50.1.4 is NOT in cluster member list - need to add"
  
  # Get replica's peer URL
  say ""
  say "Attempting to add 10.50.1.4 to cluster..."
  say "  (This requires etcdctl member add command from primary)"
  
  # Try to get the member ID from replica's etcd
  replica_id=$(ssh_cmd "10.50.1.4" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member list 2>&1 | grep 'pgpatroni-1' | cut -d',' -f1" || echo "")
  
  if [[ -n "$replica_id" ]] && [[ "$replica_id" != "" ]]; then
    say "  Found replica ID: $replica_id"
    say "  Trying to add member from primary..."
    
    # Add member from primary (using peer URL)
    add_result=$(ssh_cmd "10.50.1.5" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member add pgpatroni-1 --peer-urls=http://10.50.1.4:2380 2>&1" || echo "failed")
    if echo "$add_result" | grep -q "added\|already"; then
      say "  ✓ Member added (or already exists)"
    else
      say "  ✗ Failed to add member: ${add_result:0:200}"
    fi
  else
    say "  Could not determine replica ID, trying direct add..."
    add_result=$(ssh_cmd "10.50.1.5" "ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member add pgpatroni-1 --peer-urls=http://10.50.1.4:2380 2>&1" || echo "failed")
    if echo "$add_result" | grep -q "added\|already"; then
      say "  ✓ Member added (or already exists)"
    else
      say "  ✗ Failed: ${add_result:0:200}"
      say ""
      say "Manual steps required:"
      say "  1. SSH to 10.50.1.5"
      say "  2. Run: sudo ETCDCTL_API=3 etcdctl --endpoints=http://127.0.0.1:2379 member add pgpatroni-1 --peer-urls=http://10.50.1.4:2380"
      say "  3. Update /etc/default/etcd on 10.50.1.4 with new initial-cluster value (if provided)"
      say "  4. Restart etcd on 10.50.1.4"
    fi
  fi
fi

say ""
say "Verifying Patroni cluster view after 30 seconds..."
sleep 30

for host in "${DB_NODES[@]}"; do
  say "=== Node: $host ==="
  members=$(ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '[.members[]] | length' || echo '0'")
  say "  Patroni sees: $members member(s)"
  if [[ "$members" == "2" ]]; then
    say "  ✓✓✓ SUCCESS!"
    ssh_cmd "$host" "curl -fsS http://127.0.0.1:8008/cluster 2>/dev/null | jq '.members[] | {name, role, state}'" || true
  else
    say "  ✗ Still incomplete"
  fi
done

