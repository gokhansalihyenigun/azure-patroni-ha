#!/bin/bash

# Azure Patroni HA PostgreSQL Setup Script
# This script will be run manually on each VM

set -e

echo "=== Starting PostgreSQL Patroni HA Setup ==="

# Update system
apt-get update
apt-get upgrade -y

# Install basic packages
apt-get install -y jq curl gnupg lsb-release software-properties-common python3-pip haproxy etcd

# Add PostgreSQL repository
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/pg.gpg
echo "deb [signed-by=/usr/share/keyrings/pg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pg.list

# Install PostgreSQL
apt-get update
apt-get install -y postgresql-16 postgresql-16-pglogical python3-psycopg2

# System tuning
sysctl -w vm.swappiness=1
sysctl -w vm.max_map_count=262144
echo "vm.swappiness=1" >> /etc/sysctl.conf
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# File limits
echo "* soft nofile 100000" >> /etc/security/limits.conf
echo "* hard nofile 100000" >> /etc/security/limits.conf

# Format and mount data disk
DISK_DATA=/dev/disk/azure/scsi1/lun0
if [ -b "$DISK_DATA" ]; then
    parted -s ${DISK_DATA} mklabel gpt mkpart primary ext4 1MiB 100%
    sleep 2
    mkfs.ext4 -F ${DISK_DATA}1
    mkdir -p /pgdata
    echo "${DISK_DATA}1 /pgdata ext4 defaults,noatime 0 2" >> /etc/fstab
    mount -a
fi

# Format and mount WAL disk
DISK_WAL=/dev/disk/azure/scsi1/lun1
if [ -b "$DISK_WAL" ]; then
    parted -s ${DISK_WAL} mklabel gpt mkpart primary ext4 1MiB 100%
    sleep 2
    mkfs.ext4 -F ${DISK_WAL}1
    mkdir -p /pgwal
    echo "${DISK_WAL}1 /pgwal ext4 defaults,noatime 0 2" >> /etc/fstab
    mount -a
fi

# Stop PostgreSQL and move data
systemctl stop postgresql
if [ -d "/pgdata" ]; then
    rsync -a /var/lib/postgresql/16/main/ /pgdata/ || true
    chown -R postgres:postgres /pgdata
fi
if [ -d "/pgwal" ]; then
    chown -R postgres:postgres /pgwal
fi

# Configure PostgreSQL data directory
sed -i "s|^data_directory = .*|data_directory = '/pgdata'|" /etc/postgresql/16/main/postgresql.conf

# Get VM info
HOSTNAME=$(hostname -s)
IP=$(ip -4 addr show dev eth0 | awk '/inet /{print $2}' | cut -d/ -f1)

# Configure etcd
cat > /etc/default/etcd <<EOF
ETCD_NAME="${HOSTNAME}"
ETCD_INITIAL_CLUSTER="pgpatroni-1=http://10.50.1.4:2380,pgpatroni-2=http://10.50.1.5:2380,pgpatroni-3=http://10.50.1.6:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${IP}:2379"
ETCD_LISTEN_PEER_URLS="http://${IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${IP}:2379"
EOF

systemctl enable etcd
systemctl restart etcd

# Install Patroni
pip3 install patroni[etcd] requests

# Configure Patroni
mkdir -p /etc/patroni

cat > /etc/patroni/patroni.yml <<EOF
scope: pg-ha
namespace: /service/
name: ${HOSTNAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${IP}:8008

etcd:
  hosts: 10.50.1.4:2379,10.50.1.5:2379,10.50.1.6:2379

bootstrap:
  dcs:
    ttl: 20
    loop_wait: 5
    retry_timeout: 5
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_mode_strict: false
    synchronous_node_count: 1
    postgresql:
      parameters:
        wal_level: logical
        max_wal_senders: 20
        max_replication_slots: 20
        shared_buffers: 4GB
        effective_cache_size: 8GB
        maintenance_work_mem: 1GB
        work_mem: 64MB
        checkpoint_timeout: 10min
        synchronous_commit: on
      use_slots: true
      use_pg_rewind: true
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator 10.50.0.0/16 md5
    - host all all 10.50.0.0/16 md5
  users:
    replicator:
      password: ChangeMe123!
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${IP}:5432
  data_dir: /pgdata
  bin_dir: /usr/lib/postgresql/16/bin
  parameters: {}
  authentication:
    superuser:
      username: postgres
      password: ChangeMe123!
    replication:
      username: replicator
      password: ChangeMe123!

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
EOF

chown postgres:postgres /etc/patroni/patroni.yml

# Create Patroni systemd service
cat > /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
Restart=on-failure
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Patroni
systemctl daemon-reload
systemctl enable patroni
systemctl start patroni

# Configure HAProxy
cat > /etc/haproxy/haproxy.cfg <<EOF
global
    maxconn 100000

defaults
    mode tcp
    timeout connect 5s
    timeout client  24h
    timeout server  24h

frontend pg_fe
    bind *:5432
    default_backend pg_be

backend pg_be
    option tcp-check
    tcp-check connect port 5432
    server pg1 10.50.1.4:5432 check
    server pg2 10.50.1.5:5432 check backup
    server pg3 10.50.1.6:5432 check backup
EOF

systemctl enable haproxy
systemctl restart haproxy

echo "=== Setup Complete! ==="
echo "Hostname: ${HOSTNAME}"
echo "IP: ${IP}"
echo "Check Patroni status: curl http://localhost:8008/cluster"

