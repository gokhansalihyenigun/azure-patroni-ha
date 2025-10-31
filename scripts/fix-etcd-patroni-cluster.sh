#!/bin/bash
# Fix etcd cluster and ensure Patroni can see each other

set -euo pipefail

NODE1_IP="10.50.1.4"
NODE2_IP="10.50.1.5"
NODE3_IP="10.50.1.7"  # PgBouncer node that should have etcd
POSTGRES_PASS="ChangeMe123Pass"

echo "=== Checking etcd cluster members ==="
echo ""

# Check if etcd cluster is properly formed
for ip in "$NODE1_IP" "$NODE2_IP" "$NODE3_IP"; do
  echo "Checking etcd at $ip:2379"
  health=$(curl -fsS "http://$ip:2379/health" 2>/dev/null || echo "{}")
  if [[ "$health" == "{}" ]]; then
    echo "  ✗ etcd not reachable"
  else
    echo "  ✓ Health: $health"
    
    # Try to get members
    if command -v etcdctl >/dev/null 2>&1; then
      members=$(ETCDCTL_API=3 etcdctl --endpoints="http://$ip:2379" member list 2>/dev/null || echo "failed")
      if [[ "$members" != "failed" ]]; then
        echo "  Members:"
        echo "$members" | while read line; do
          echo "    $line"
        done
      fi
    fi
  fi
  echo ""
done

echo "=== Checking Patroni cluster in etcd ==="
echo ""
if command -v etcdctl >/dev/null 2>&1; then
  echo "Checking /pg-ha/ keys in etcd:"
  ETCDCTL_API=3 etcdctl --endpoints="http://$NODE1_IP:2379" get --prefix /pg-ha/ 2>/dev/null || echo "  No keys found or etcdctl error"
  echo ""
else
  echo "etcdctl not available, skipping etcd key check"
  echo ""
fi

echo "=== Fix Steps ==="
echo ""
echo "1. Ensure all etcd instances are running and in the same cluster"
echo ""
echo "2. On pgpatroni-1, restart Patroni to re-establish lock:"
echo "   ssh azureuser@$NODE1_IP 'sudo systemctl restart patroni'"
echo ""
echo "3. Wait 10 seconds, then check cluster:"
echo "   curl -s http://$NODE1_IP:8008/cluster | jq"
echo ""
echo "4. On pgpatroni-2, if still not joining, manually trigger:"
echo "   ssh azureuser@$NODE2_IP"
echo "   sudo systemctl stop patroni"
echo "   sudo rm -rf /var/lib/etcd/member/*  # Clear etcd data"
echo "   sudo systemctl restart etcd"
echo "   sleep 5"
echo "   sudo systemctl start patroni"
echo ""

