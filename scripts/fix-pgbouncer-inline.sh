#!/bin/bash
# Inline fix script - run this ON each PgBouncer VM directly via SSH

set -e

echo "=== Fixing PgBouncer (inline) ==="
echo ""

echo "Step 1: Ensuring PgBouncer package is installed..."
if ! command -v pgbouncer >/dev/null 2>&1; then
  sudo apt-get update -qq >/dev/null 2>&1 || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y pgbouncer || exit 1
fi

echo "Step 2: Creating pgbouncer user and directories..."
sudo adduser --system --group --home /var/lib/pgbouncer --no-create-home pgbouncer || true
sudo install -o pgbouncer -g pgbouncer -m 755 -d /etc/pgbouncer || true
sudo install -o pgbouncer -g pgbouncer -m 755 -d /run/pgbouncer || true
sudo install -o pgbouncer -g pgbouncer -m 755 -d /var/log/pgbouncer || true

echo "Step 3: Creating configuration files..."
sudo tee /etc/pgbouncer/pgbouncer.ini >/dev/null <<'INIFILE'
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
INIFILE

sudo tee /etc/pgbouncer/userlist.txt >/dev/null <<'USERLIST'
"pgbouncer" "StrongPass123"
"postgres" "ChangeMe123Pass"
USERLIST

sudo chown pgbouncer:pgbouncer /etc/pgbouncer/pgbouncer.ini
sudo chmod 644 /etc/pgbouncer/pgbouncer.ini
sudo chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
sudo chmod 640 /etc/pgbouncer/userlist.txt

echo "Step 4: Creating systemd service..."
PGB_BIN=$(which pgbouncer 2>/dev/null || echo "/usr/sbin/pgbouncer")
sudo tee /etc/systemd/system/pgbouncer.service >/dev/null <<UNIT
[Unit]
Description=PgBouncer connection pooler
After=network-online.target
Wants=network-online.target

[Service]
User=pgbouncer
Group=pgbouncer
Type=simple
ExecStart=$PGB_BIN -q /etc/pgbouncer/pgbouncer.ini
PIDFile=/run/pgbouncer/pgbouncer.pid
RuntimeDirectory=pgbouncer
RuntimeDirectoryMode=0755
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable pgbouncer

echo "Step 5: Stopping old service if running..."
sudo systemctl stop pgbouncer || true
sleep 2

echo "Step 6: Starting PgBouncer..."
sudo systemctl start pgbouncer
sleep 5

echo "Step 7: Verifying..."
if sudo systemctl is-active --quiet pgbouncer && sudo ss -lntp | grep -q :6432; then
  echo "✓ PgBouncer is running and listening on port 6432"
  if PGPASSWORD='ChangeMe123Pass' timeout 5 psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    echo "✓ Backend connection test successful"
  else
    echo "⚠ Backend connection test failed (may need more time for PostgreSQL ILB)"
  fi
else
  echo "✗ PgBouncer failed to start"
  sudo systemctl status pgbouncer --no-pager || true
  sudo journalctl -u pgbouncer -n 20 --no-pager || true
  exit 1
fi

echo ""
echo "=== Fix completed ==="

