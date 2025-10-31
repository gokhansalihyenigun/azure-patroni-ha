#!/bin/bash
# PgBouncer Diagnostic Script - Run from test VM

set -euo pipefail

echo "======================================"
echo "PgBouncer Diagnostic Tool"
echo "======================================"
echo ""

PGB_ILB_IP="10.50.1.11"
PGB_VMS=(10.50.1.7 10.50.1.8)
DB_ILB_IP="10.50.1.10"
ADMIN_USER="azureuser"
ADMIN_PASS="Azure123!@#"

echo "1. Testing PgBouncer ILB connection (10.50.1.11:6432)..."
if timeout 3 bash -c "echo > /dev/tcp/$PGB_ILB_IP/6432" 2>/dev/null; then
    echo "   ✓ Port 6432 is open"
else
    echo "   ✗ Port 6432 is NOT accessible"
fi

echo ""
echo "2. Testing direct psql connection to PgBouncer ILB..."
if PGPASSWORD='ChangeMe123Pass' psql -h "$PGB_ILB_IP" -p 6432 -U postgres -d postgres -c "SELECT now();" 2>&1; then
    echo "   ✓ Connection successful"
else
    echo "   ✗ Connection failed"
fi

echo ""
echo "3. Testing PgBouncer stats database..."
if PGPASSWORD='StrongPass123' psql -h "$PGB_ILB_IP" -p 6432 -U pgbouncer -d pgbouncer -c "SHOW POOLS;" 2>&1; then
    echo "   ✓ Stats database accessible"
else
    echo "   ✗ Stats database NOT accessible"
fi

echo ""
echo "4. Checking PgBouncer VM services..."
for vm_ip in "${PGB_VMS[@]}"; do
    echo ""
    echo "   Checking VM: $vm_ip"
    echo "   --------------------"
    
    # Service status
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$vm_ip" \
        "systemctl status pgbouncer --no-pager -l || echo 'Service check failed'" 2>&1 | head -15
    
    # Port listening
    echo ""
    echo "   Port 6432 listening?"
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$vm_ip" \
        "ss -lntp | grep 6432 || echo 'Port 6432 NOT listening'" 2>&1
    
    # Direct connection test from VM
    echo ""
    echo "   Testing direct connection from VM..."
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$vm_ip" \
        "PGPASSWORD='ChangeMe123Pass' psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c 'SELECT now();' 2>&1 | head -3" || echo "   Direct connection failed"
    
    # PgBouncer logs (last 10 lines)
    echo ""
    echo "   Recent PgBouncer logs:"
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$vm_ip" \
        "journalctl -u pgbouncer -n 10 --no-pager 2>/dev/null || tail -10 /var/log/pgbouncer/*.log 2>/dev/null || echo 'No logs found'" 2>&1
    
    # PgBouncer config check
    echo ""
    echo "   PgBouncer config (listen_addr, listen_port):"
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$vm_ip" \
        "grep -E '^(listen_addr|listen_port)' /etc/pgbouncer/pgbouncer.ini 2>/dev/null || echo 'Config file not found'" 2>&1
    
    # Backend connection test
    echo ""
    echo "   Testing backend PostgreSQL connection from PgBouncer VM..."
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no "$ADMIN_USER@$vm_ip" \
        "timeout 3 bash -c 'echo > /dev/tcp/$DB_ILB_IP/5432' 2>/dev/null && echo 'Backend DB reachable' || echo 'Backend DB NOT reachable'" 2>&1
done

echo ""
echo "======================================"
echo "Diagnostic Complete"
echo "======================================"

