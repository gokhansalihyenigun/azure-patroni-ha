#!/bin/bash
# PgBouncer Fix Script - Run on each PgBouncer VM

set -euo pipefail

echo "======================================"
echo "PgBouncer Fix Script"
echo "======================================"
echo ""

# 1. Check service status
echo "1. Checking PgBouncer service status..."
if systemctl is-active --quiet pgbouncer; then
    echo "   ✓ PgBouncer is active"
else
    echo "   ✗ PgBouncer is NOT active"
    echo "   Attempting to start..."
    systemctl start pgbouncer || {
        echo "   ✗ Failed to start. Checking logs..."
        journalctl -u pgbouncer -n 30 --no-pager
        exit 1
    }
    sleep 2
fi

# 2. Check port listening
echo ""
echo "2. Checking if port 6432 is listening..."
if ss -lntp | grep -q :6432; then
    echo "   ✓ Port 6432 is listening"
    ss -lntp | grep 6432
else
    echo "   ✗ Port 6432 is NOT listening"
    echo "   Attempting to restart PgBouncer..."
    systemctl restart pgbouncer
    sleep 3
    if ss -lntp | grep -q :6432; then
        echo "   ✓ Port 6432 is now listening"
    else
        echo "   ✗ Still not listening. Checking logs..."
        journalctl -u pgbouncer -n 30 --no-pager
        exit 1
    fi
fi

# 3. Test backend connection
echo ""
echo "3. Testing backend PostgreSQL connection..."
DB_ILB="10.50.1.10"
if timeout 3 bash -c "echo > /dev/tcp/$DB_ILB/5432" 2>/dev/null; then
    echo "   ✓ Backend PostgreSQL is reachable"
else
    echo "   ✗ Backend PostgreSQL is NOT reachable"
    echo "   This may cause PgBouncer to fail. Checking network..."
fi

# 4. Test local PgBouncer connection
echo ""
echo "4. Testing local PgBouncer connection..."
if PGPASSWORD='ChangeMe123Pass' psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c "SELECT now();" >/dev/null 2>&1; then
    echo "   ✓ Local PgBouncer connection successful"
else
    echo "   ✗ Local PgBouncer connection failed"
    echo "   Checking configuration..."
    grep -E '^(listen_addr|listen_port|admin_users)' /etc/pgbouncer/pgbouncer.ini || echo "   ✗ Config file issue"
fi

# 5. Check config file
echo ""
echo "5. Checking PgBouncer configuration..."
if [ -f /etc/pgbouncer/pgbouncer.ini ]; then
    echo "   ✓ Config file exists"
    echo "   Key settings:"
    grep -E '^(listen_addr|listen_port|admin_users|auth_type)' /etc/pgbouncer/pgbouncer.ini || echo "   ✗ Key settings missing"
else
    echo "   ✗ Config file NOT found!"
    exit 1
fi

# 6. Check userlist
echo ""
echo "6. Checking userlist file..."
if [ -f /etc/pgbouncer/userlist.txt ]; then
    echo "   ✓ Userlist file exists"
    echo "   Users:"
    cat /etc/pgbouncer/userlist.txt
else
    echo "   ✗ Userlist file NOT found!"
    exit 1
fi

# 7. Final status
echo ""
echo "======================================"
echo "Final Status"
echo "======================================"
systemctl status pgbouncer --no-pager -l | head -15

echo ""
echo "If PgBouncer is still not working, check logs:"
echo "  journalctl -u pgbouncer -n 50 --no-pager"

