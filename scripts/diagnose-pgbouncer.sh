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

# Install sshpass if not available
if ! command -v sshpass >/dev/null 2>&1; then
    echo "Installing sshpass..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y sshpass >/dev/null 2>&1 || {
            echo "Warning: Could not install sshpass. SSH checks will be skipped."
            echo "You can install manually: sudo apt-get install -y sshpass"
            SKIP_SSH=true
        }
    else
        echo "Warning: sshpass not available and apt-get not found. SSH checks will be skipped."
        SKIP_SSH=true
    fi
fi
SKIP_SSH=${SKIP_SSH:-false}

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
if [[ "$SKIP_SSH" == "true" ]]; then
    echo "   ⚠ Skipping SSH checks (sshpass not available)"
    echo "   Please SSH manually to PgBouncer VMs and run:"
    echo "   - systemctl status pgbouncer"
    echo "   - ss -lntp | grep 6432"
    echo "   - journalctl -u pgbouncer -n 20"
else
    for vm_ip in "${PGB_VMS[@]}"; do
        echo ""
        echo "   Checking VM: $vm_ip"
        echo "   --------------------"
        
        # Service status
        sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" \
            "systemctl status pgbouncer --no-pager -l || echo 'Service check failed'" 2>&1 | head -15 || echo "   ✗ Could not connect to VM"
        
        # Port listening
        echo ""
        echo "   Port 6432 listening?"
        sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" \
            "ss -lntp | grep 6432 || echo 'Port 6432 NOT listening'" 2>&1 || echo "   ✗ Could not check port"
        
        # Direct connection test from VM
        echo ""
        echo "   Testing direct connection from VM..."
        sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" \
            "PGPASSWORD='ChangeMe123Pass' psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c 'SELECT now();' 2>&1 | head -3" || echo "   ✗ Direct connection failed"
        
        # PgBouncer logs (last 20 lines)
        echo ""
        echo "   Recent PgBouncer logs:"
        sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" \
            "journalctl -u pgbouncer -n 20 --no-pager 2>/dev/null || tail -20 /var/log/pgbouncer/*.log 2>/dev/null || echo 'No logs found'" 2>&1 || echo "   ✗ Could not retrieve logs"
        
        # PgBouncer config check
        echo ""
        echo "   PgBouncer config (listen_addr, listen_port, admin_users):"
        sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" \
            "grep -E '^(listen_addr|listen_port|admin_users)' /etc/pgbouncer/pgbouncer.ini 2>/dev/null || echo 'Config file not found'" 2>&1 || echo "   ✗ Could not check config"
        
        # Backend connection test
        echo ""
        echo "   Testing backend PostgreSQL connection from PgBouncer VM..."
        sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" \
            "timeout 3 bash -c 'echo > /dev/tcp/$DB_ILB_IP/5432' 2>/dev/null && echo '✓ Backend DB reachable' || echo '✗ Backend DB NOT reachable'" 2>&1 || echo "   ✗ Could not test backend"
        
        # Check if PgBouncer process is running
        echo ""
        echo "   PgBouncer process running?"
        sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$ADMIN_USER@$vm_ip" \
            "pgrep -f pgbouncer && echo '✓ Process found' || echo '✗ Process NOT found'" 2>&1 || echo "   ✗ Could not check process"
    done
fi

echo ""
echo "======================================"
echo "Diagnostic Complete"
echo "======================================"

