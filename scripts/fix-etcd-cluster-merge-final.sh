#!/bin/bash
# Fix etcd cluster split-brain by merging pgpatroni-1 into pgpatroni-2's cluster

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo "[FIX] $*"; }
pass() { echo "✓ $*"; }
fail() { echo "✗ $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

say "=== Fixing etcd Cluster Split-Brain ==="
say ""

# Step 1: Check current etcd member lists
say "Current etcd cluster status:"
for ip in "${DB_NODES[@]}"; do
  say "  Node $ip:"
  members=$(curl -fsS "http://$ip:2379/v2/members" 2>/dev/null || echo "failed")
  if [[ "$members" != "failed" ]]; then
    member_count=$(echo "$members" | jq '[.members[]] | length' 2>/dev/null || echo "0")
    echo "$members" | jq -r '.members[] | "    - \(.name // "unnamed"): id=\(.id[0:8])..."' 2>/dev/null || echo "    (parse failed)"
    say "    Total members: $member_count"
  else
    say "    (etcd not responding)"
  fi
done

say ""
say "Determining primary cluster (node with more members)..."
primary_cluster_ip=""
primary_member_count=0

for ip in "${DB_NODES[@]}"; do
  members=$(curl -fsS "http://$ip:2379/v2/members" 2>/dev/null || echo "failed")
  if [[ "$members" != "failed" ]]; then
    member_count=$(echo "$members" | jq '[.members[]] | length' 2>/dev/null || echo "0")
    if [[ "$member_count" -gt "$primary_member_count" ]]; then
      primary_member_count=$member_count
      primary_cluster_ip="$ip"
    fi
  fi
done

if [[ -z "$primary_cluster_ip" ]]; then
  fail "Cannot determine primary cluster"
  exit 1
fi

say "Primary cluster is on: $primary_cluster_ip (${primary_member_count} members)"
say ""

# Step 2: Identify which node needs to rejoin
rejoin_node_ip=""
for ip in "${DB_NODES[@]}"; do
  if [[ "$ip" != "$primary_cluster_ip" ]]; then
    rejoin_node_ip="$ip"
    break
  fi
done

if [[ -z "$rejoin_node_ip" ]]; then
  fail "Cannot determine which node to rejoin"
  exit 1
fi

say "Node to rejoin: $rejoin_node_ip"
say ""

# Step 3: Get primary cluster member list (excluding the node that will rejoin)
say "Getting primary cluster member list..."
primary_members=$(curl -fsS "http://$primary_cluster_ip:2379/v2/members" 2>/dev/null || echo "")
if [[ -z "$primary_members" ]]; then
  fail "Cannot retrieve primary cluster members"
  exit 1
fi

# Get the member ID that will be added (from the node that will rejoin)
say "Getting current member info from rejoin node..."
rejoin_node_name=$(ssh_cmd "$rejoin_node_ip" "grep '^ETCD_NAME=' /etc/default/etcd | cut -d'=' -f2 | tr -d '\"' || echo ''")
if [[ -z "$rejoin_node_name" ]]; then
  case "$rejoin_node_ip" in
    10.50.1.4) rejoin_node_name="pgpatroni-1" ;;
    10.50.1.5) rejoin_node_name="pgpatroni-2" ;;
    *) rejoin_node_name="node-$rejoin_node_ip" ;;
  esac
fi

rejoin_node_peer_url="http://$rejoin_node_ip:2380"
say "Rejoin node: $rejoin_node_name ($rejoin_node_ip)"
say "Peer URL: $rejoin_node_peer_url"
say ""

# Step 4: Stop Patroni and etcd on the rejoin node
say "Stopping services on rejoin node ($rejoin_node_ip)..."
ssh_cmd "$rejoin_node_ip" "sudo systemctl stop patroni || true"
ssh_cmd "$rejoin_node_ip" "sudo systemctl stop etcd || true"
sleep 3

# Step 5: Clear etcd data on rejoin node
say "Clearing etcd data on rejoin node..."
ssh_cmd "$rejoin_node_ip" "sudo rm -rf /var/lib/etcd/* || true"
pass "etcd data cleared"

# Step 6: Add member to primary cluster (from primary node)
say "Adding $rejoin_node_name to primary cluster from $primary_cluster_ip..."
add_response=$(curl -fsS -X POST "http://$primary_cluster_ip:2379/v2/members" \
  -H "Content-Type: application/json" \
  -d "{\"peerURLs\": [\"$rejoin_node_peer_url\"]}" 2>/dev/null || echo "failed")

if [[ "$add_response" == "failed" ]]; then
  fail "Failed to add member to primary cluster"
  say "Attempting to continue anyway..."
else
  new_member_id=$(echo "$add_response" | jq -r '.id // ""' 2>/dev/null || echo "")
  if [[ -n "$new_member_id" ]]; then
    pass "Member added to primary cluster (ID: ${new_member_id:0:8}...)"
  else
    warn "Member add response received but ID not parsed"
  fi
fi

# Step 7: Update etcd config on rejoin node
say "Updating etcd configuration on rejoin node..."
ssh_cmd "$rejoin_node_ip" "sudo bash" <<'ETCD_CONFIG'
# Backup current config
cp /etc/default/etcd /etc/default/etcd.backup.$(date +%s) 2>/dev/null || true

# Get all cluster members (from primary)
PRIMARY_IP="${1:-10.50.1.5}"
ETCD_NAME="${2:-pgpatroni-1}"
NODE_IP="${3:-10.50.1.4}"

# Get member list from primary
MEMBERS_JSON=$(curl -fsS "http://${PRIMARY_IP}:2379/v2/members" 2>/dev/null || echo "[]")
CLUSTER_LIST=""

# Build cluster list
for member in $(echo "$MEMBERS_JSON" | jq -r '.members[] | "\(.name // "unknown"):\(.peerURLs[0])"' 2>/dev/null); do
  member_name="${member%%:*}"
  member_url="${member##*:}"
  if [[ -z "$CLUSTER_LIST" ]]; then
    CLUSTER_LIST="${member_name}=${member_url}"
  else
    CLUSTER_LIST="${CLUSTER_LIST},${member_name}=${member_url}"
  fi
done

# If cluster list is empty, build from known nodes
if [[ -z "$CLUSTER_LIST" ]] || [[ "$CLUSTER_LIST" == *"unknown"* ]]; then
  CLUSTER_LIST="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
fi

# Update /etc/default/etcd
cat > /etc/default/etcd <<EOF
ETCD_NAME="${ETCD_NAME}"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="${CLUSTER_LIST}"
ETCD_INITIAL_CLUSTER_STATE="existing"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NODE_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${NODE_IP}:2379"
ETCD_LISTEN_PEER_URLS="http://${NODE_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://${NODE_IP}:2379"
EOF

echo "Updated /etc/default/etcd:"
cat /etc/default/etcd
ETCD_CONFIG

# Call with parameters
case "$rejoin_node_ip" in
  10.50.1.4)
    ssh_cmd "$rejoin_node_ip" "sudo bash" <<EOF
$(cat <<'ETCD_CONFIG_INNER'
PRIMARY_IP="10.50.1.5"
ETCD_NAME="pgpatroni-1"
NODE_IP="10.50.1.4"
MEMBERS_JSON=\$(curl -fsS "http://\${PRIMARY_IP}:2379/v2/members" 2>/dev/null || echo "[]")
CLUSTER_LIST="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
cat > /etc/default/etcd <<'CFGEOF'
ETCD_NAME="pgpatroni-1"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
ETCD_INITIAL_CLUSTER_STATE="existing"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.50.1.4:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.50.1.4:2379"
ETCD_LISTEN_PEER_URLS="http://10.50.1.4:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://10.50.1.4:2379"
CFGEOF
echo "Updated /etc/default/etcd"
cat /etc/default/etcd
ETCD_CONFIG_INNER
)
EOF
    ;;
  10.50.1.5)
    ssh_cmd "$rejoin_node_ip" "sudo bash" <<EOF
$(cat <<'ETCD_CONFIG_INNER'
PRIMARY_IP="10.50.1.4"
ETCD_NAME="pgpatroni-2"
NODE_IP="10.50.1.5"
MEMBERS_JSON=\$(curl -fsS "http://\${PRIMARY_IP}:2379/v2/members" 2>/dev/null || echo "[]")
CLUSTER_LIST="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
cat > /etc/default/etcd <<'CFGEOF'
ETCD_NAME="pgpatroni-2"
ETCD_INITIAL_CLUSTER_TOKEN="pg-ha-token"
ETCD_INITIAL_CLUSTER="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380"
ETCD_INITIAL_CLUSTER_STATE="existing"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.50.1.5:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://10.50.1.5:2379"
ETCD_LISTEN_PEER_URLS="http://10.50.1.5:2380"
ETCD_LISTEN_CLIENT_URLS="http://127.0.0.1:2379,http://10.50.1.5:2379"
CFGEOF
echo "Updated /etc/default/etcd"
cat /etc/default/etcd
ETCD_CONFIG_INNER
)
EOF
    ;;
esac

pass "etcd configuration updated"

# Step 8: Start etcd on rejoin node
say "Starting etcd on rejoin node..."
ssh_cmd "$rejoin_node_ip" "sudo systemctl start etcd"
sleep 5

# Step 9: Verify etcd health
say "Verifying etcd health..."
for i in {1..10}; do
  health=$(ssh_cmd "$rejoin_node_ip" "curl -fsS http://127.0.0.1:2379/health 2>/dev/null | jq -r '.health // \"unknown\"' || echo 'unknown'")
  if [[ "$health" == "true" ]]; then
    pass "etcd is healthy on rejoin node"
    break
  fi
  if [[ $i -eq 10 ]]; then
    fail "etcd health check failed on rejoin node"
    exit 1
  fi
  sleep 2
done

# Step 10: Verify cluster view from both nodes
say ""
say "Verifying cluster view from both nodes..."
sleep 3
all_good=true
for ip in "${DB_NODES[@]}"; do
  members=$(curl -fsS "http://$ip:2379/v2/members" 2>/dev/null || echo "failed")
  if [[ "$members" != "failed" ]]; then
    member_count=$(echo "$members" | jq '[.members[]] | length' 2>/dev/null || echo "0")
    if [[ "$member_count" -ge 2 ]]; then
      pass "Node $ip sees $member_count member(s)"
    else
      fail "Node $ip sees only $member_count member(s) (expected 2+)"
      all_good=false
    fi
  else
    fail "Node $ip: etcd not responding"
    all_good=false
  fi
done

# Step 11: Start Patroni on rejoin node
if [[ "$all_good" == "true" ]]; then
  say "Starting Patroni on rejoin node..."
  ssh_cmd "$rejoin_node_ip" "sudo systemctl start patroni"
  sleep 10
  
  # Verify Patroni is running
  patroni_health=$(ssh_cmd "$rejoin_node_ip" "curl -fsS http://127.0.0.1:8008/health 2>/dev/null && echo 'ok' || echo 'failed'")
  if [[ "$patroni_health" == "ok" ]]; then
    pass "Patroni is healthy on rejoin node"
  else
    warn "Patroni health check failed, but service may still be starting..."
  fi
fi

say ""
if [[ "$all_good" == "true" ]]; then
  pass "=== etcd cluster merge completed successfully! ==="
  say "Both nodes should now see each other in etcd cluster"
  say "Run test script to verify cluster view:"
  say "  curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo bash"
else
  fail "=== etcd cluster merge had issues ==="
  say "Check etcd and Patroni logs on both nodes"
  exit 1
fi

