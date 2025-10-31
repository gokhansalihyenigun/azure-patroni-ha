#!/bin/bash
# Quick PgBouncer diagnostic script

PGB_VMS="10.50.1.7 10.50.1.8"
ADMIN_PASS="Azure123!@#"

echo "=== Quick PgBouncer Diagnostic ==="
echo ""

for ip in $PGB_VMS; do
  echo "--- Checking $ip ---"
  
  # Service status
  echo "Service status:"
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@"$ip" \
    "sudo systemctl status pgbouncer --no-pager | head -10" 2>/dev/null || echo "  SSH failed"
  
  # Port check
  echo "Port 6432 listening:"
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@"$ip" \
    "sudo ss -lntp | grep 6432" 2>/dev/null || echo "  Not listening or SSH failed"
  
  # Config files
  echo "Config files:"
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@"$ip" \
    "sudo ls -la /etc/pgbouncer/ 2>/dev/null || echo '  Directory not found'" 2>/dev/null || echo "  SSH failed"
  
  # Recent logs
  echo "Recent logs (last 10 lines):"
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@"$ip" \
    "sudo journalctl -u pgbouncer -n 10 --no-pager 2>/dev/null" 2>/dev/null || echo "  SSH failed or no logs"
  
  # Test local connection
  echo "Local connection test:"
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 azureuser@"$ip" \
    "PGPASSWORD='ChangeMe123Pass' timeout 3 psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c 'SELECT 1;' 2>&1 | head -3" 2>/dev/null || echo "  Connection failed"
  
  echo ""
done

echo "--- Load Balancer Check ---"
echo "PgBouncer ILB IP: 10.50.1.11"
timeout 3 bash -c "echo > /dev/tcp/10.50.1.11/6432" 2>/dev/null && echo "Port 6432 reachable" || echo "Port 6432 NOT reachable"

