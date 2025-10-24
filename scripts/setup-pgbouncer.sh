#!/bin/bash

# Azure PgBouncer Setup Script

set -e

echo "=== Starting PgBouncer Setup ==="

# Update system
apt-get update
apt-get upgrade -y

# Install PgBouncer
apt-get install -y pgbouncer

# Get IP
IP=$(ip -4 addr show dev eth0 | awk '/inet /{print $2}' | cut -d/ -f1)

# Configure PgBouncer
cat > /etc/pgbouncer/pgbouncer.ini <<EOF
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
server_tls_sslmode = prefer
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
admin_users = pgbouncer
EOF

# Create userlist
cat > /etc/pgbouncer/userlist.txt <<EOF
"pgbouncer" "StrongPass123!"
EOF

chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
chmod 640 /etc/pgbouncer/userlist.txt

# Enable and start PgBouncer
systemctl enable pgbouncer
systemctl restart pgbouncer

echo "=== PgBouncer Setup Complete! ==="
echo "IP: ${IP}"
echo "PgBouncer listening on port 6432"

