#!/bin/bash
# Manual PgBouncer Fix Script - Run on EACH PgBouncer VM (10.50.1.7 and 10.50.1.8)

set -euo pipefail

echo "======================================"
echo "Manual PgBouncer Fix Script"
echo "======================================"
echo ""

# 1. Stop any running PgBouncer processes
echo "1. Stopping existing PgBouncer processes..."
pkill -f pgbouncer || true
sleep 2

# 2. Create pgbouncer user if not exists
echo ""
echo "2. Ensuring pgbouncer user exists..."
id -u pgbouncer >/dev/null 2>&1 || adduser --system --group --home /var/lib/pgbouncer pgbouncer

# 3. Create necessary directories
echo ""
echo "3. Creating directories..."
install -o pgbouncer -g pgbouncer -m 755 -d /run/pgbouncer /var/log/pgbouncer /etc/pgbouncer 2>/dev/null || true

# 4. Create PgBouncer config file
echo ""
echo "4. Creating PgBouncer configuration..."
cat > /etc/pgbouncer/pgbouncer.ini <<'EOF'
[databases]
postgres = host=10.50.1.10 port=5432 dbname=postgres
* = host=10.50.1.10 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
pool_mode = transaction
default_pool_size = 200
max_client_conn = 2000
ignore_startup_parameters = extra_float_digits
auth_type = plain
auth_file = /etc/pgbouncer/userlist.txt
admin_users = pgbouncer,postgres
EOF

# 5. Create userlist file
echo ""
echo "5. Creating userlist file..."
cat > /etc/pgbouncer/userlist.txt <<'EOF'
"pgbouncer" "StrongPass123"
"postgres" "ChangeMe123Pass"
EOF

# 6. Set permissions
echo ""
echo "6. Setting permissions..."
chown -R pgbouncer:pgbouncer /etc/pgbouncer /var/log/pgbouncer /run/pgbouncer
chmod 640 /etc/pgbouncer/userlist.txt
chmod 644 /etc/pgbouncer/pgbouncer.ini

# 7. Find pgbouncer binary location
echo ""
echo "7. Finding PgBouncer binary..."
PGBOUNCER_BIN=$(which pgbouncer 2>/dev/null || find /usr -name pgbouncer -type f 2>/dev/null | head -1)
if [ -z "$PGBOUNCER_BIN" ]; then
    echo "   ✗ PgBouncer binary not found! Attempting to install..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y pgbouncer >/dev/null 2>&1 || {
        echo "   ✗ Failed to install PgBouncer"
        exit 1
    }
    PGBOUNCER_BIN=$(which pgbouncer || echo "/usr/sbin/pgbouncer")
fi
echo "   ✓ Found PgBouncer at: $PGBOUNCER_BIN"

# 8. Create systemd service
echo ""
echo "8. Creating systemd service..."
cat > /etc/systemd/system/pgbouncer.service <<EOF
[Unit]
Description=PgBouncer connection pooler
After=network.target

[Service]
User=pgbouncer
Group=pgbouncer
Type=simple
ExecStart=$PGBOUNCER_BIN -q /etc/pgbouncer/pgbouncer.ini
PIDFile=/run/pgbouncer/pgbouncer.pid
RuntimeDirectory=pgbouncer
RuntimeDirectoryMode=0755
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# 9. Reload systemd and enable service
echo ""
echo "9. Enabling PgBouncer service..."
systemctl daemon-reload
systemctl enable pgbouncer

# 10. Wait for backend to be ready
echo ""
echo "10. Checking backend PostgreSQL availability..."
DB_ILB="10.50.1.10"
for i in {1..30}; do
    if timeout 2 bash -c "echo > /dev/tcp/$DB_ILB/5432" 2>/dev/null; then
        echo "   ✓ Backend PostgreSQL is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "   ⚠ Backend not ready after 30 attempts, continuing anyway..."
    fi
    sleep 2
done

# 11. Start PgBouncer
echo ""
echo "11. Starting PgBouncer service..."
systemctl start pgbouncer
sleep 3

# 12. Verify it's running
echo ""
echo "12. Verifying PgBouncer status..."
if systemctl is-active --quiet pgbouncer; then
    echo "   ✓ PgBouncer service is active"
else
    echo "   ✗ PgBouncer service failed to start"
    systemctl status pgbouncer --no-pager -l
    exit 1
fi

# 13. Check port
echo ""
echo "13. Checking if port 6432 is listening..."
if ss -lntp | grep -q :6432; then
    echo "   ✓ Port 6432 is listening"
    ss -lntp | grep 6432
else
    echo "   ✗ Port 6432 is NOT listening"
    echo "   Checking logs..."
    journalctl -u pgbouncer -n 20 --no-pager
    exit 1
fi

# 14. Test local connection (if psql is available)
echo ""
echo "14. Testing local connection..."
if command -v psql >/dev/null 2>&1; then
    if PGPASSWORD='ChangeMe123Pass' psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c "SELECT now();" >/dev/null 2>&1; then
        echo "   ✓ Local connection successful"
    else
        echo "   ✗ Local connection failed (this may be normal if backend is still initializing)"
    fi
else
    echo "   ⚠ psql not available, skipping connection test"
fi

echo ""
echo "======================================"
echo "PgBouncer Fix Complete!"
echo "======================================"
echo ""
echo "Service status:"
systemctl status pgbouncer --no-pager -l | head -10

