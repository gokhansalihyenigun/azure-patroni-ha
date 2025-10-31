#!/bin/bash
# Fix PgBouncer on all VMs - can be run from any VM

set -euo pipefail

ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"
PGB_VMS="10.50.1.7 10.50.1.8"

echo "=== Fixing PgBouncer on all VMs ==="
echo ""

ssh_cmd() {
  local ip="$1"
  shift
  local cmd="$*"
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o PubkeyAuthentication=no \
      -o PreferredAuthentications=password \
      azureuser@"$ip" "$cmd" 2>&1
  else
    echo "ERROR: sshpass not found. Install with: sudo apt-get install -y sshpass" >&2
    return 1
  fi
}

# Install sshpass if needed
if ! command -v sshpass >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass >/dev/null 2>&1 || true
  fi
fi

FIX_SCRIPT=$(cat <<'SCRIPTEND'
set -e

echo "Step 1: Ensuring PgBouncer package is installed..."
if ! command -v pgbouncer >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y pgbouncer || exit 1
fi

echo "Step 2: Creating pgbouncer user and directories..."
adduser --system --group --home /var/lib/pgbouncer --no-create-home pgbouncer || true
install -o pgbouncer -g pgbouncer -m 755 -d /etc/pgbouncer || true
install -o pgbouncer -g pgbouncer -m 755 -d /run/pgbouncer || true
install -o pgbouncer -g pgbouncer -m 755 -d /var/log/pgbouncer || true

echo "Step 3: Creating configuration files..."
cat > /etc/pgbouncer/pgbouncer.ini <<'INIFILE'
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

cat > /etc/pgbouncer/userlist.txt <<'USERLIST'
"pgbouncer" "StrongPass123"
"postgres" "ChangeMe123Pass"
USERLIST

chown pgbouncer:pgbouncer /etc/pgbouncer/pgbouncer.ini
chmod 644 /etc/pgbouncer/pgbouncer.ini
chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
chmod 640 /etc/pgbouncer/userlist.txt

echo "Step 4: Creating systemd service..."
PGB_BIN=$(which pgbouncer 2>/dev/null || echo "/usr/sbin/pgbouncer")
cat > /etc/systemd/system/pgbouncer.service <<UNIT
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

systemctl daemon-reload
systemctl enable pgbouncer

echo "Step 5: Stopping old service if running..."
systemctl stop pgbouncer || true
sleep 2

echo "Step 6: Starting PgBouncer..."
systemctl start pgbouncer
sleep 5

echo "Step 7: Verifying..."
if systemctl is-active --quiet pgbouncer && ss -lntp | grep -q :6432; then
  echo "✓ PgBouncer is running and listening on port 6432"
  if PGPASSWORD='ChangeMe123Pass' timeout 5 psql -h 127.0.0.1 -p 6432 -U postgres -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    echo "✓ Backend connection test successful"
  else
    echo "⚠ Backend connection test failed (may need more time)"
  fi
else
  echo "✗ PgBouncer failed to start"
  systemctl status pgbouncer --no-pager || true
  journalctl -u pgbouncer -n 20 --no-pager || true
  exit 1
fi
SCRIPTEND
)

for ip in $PGB_VMS; do
  echo "--- Fixing PgBouncer on $ip ---"
  
  # Send script via SSH and execute with sudo
  if ssh_cmd "$ip" "sudo bash" <<< "$FIX_SCRIPT"; then
    echo "✓ Successfully fixed PgBouncer on $ip"
  else
    echo "✗ Failed to fix PgBouncer on $ip"
    continue
  fi
  echo ""
done

echo "=== Final Verification ==="
for ip in $PGB_VMS; do
  echo "Checking $ip..."
  if ssh_cmd "$ip" "systemctl is-active --quiet pgbouncer && ss -lntp | grep -q :6432"; then
    echo "  ✓ Service active and port 6432 listening"
  else
    echo "  ✗ Service or port check failed"
  fi
done
