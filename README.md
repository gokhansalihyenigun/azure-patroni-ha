# Azure Patroni HA PostgreSQL

High-performance, highly available PostgreSQL cluster on Azure managed by Patroni, fronted by PgBouncer.

**Key Features:**
- ✅ **Zero Data Loss (RPO=0)**: Synchronous replication
- ✅ **Fast Failover (RTO < 10s)**: 4-7 seconds with optimized Patroni settings
- ✅ **High Performance**: Optimized for Standard_D32s_v6 (32 vCPU, 128GB RAM) with Premium SSD v2
- ✅ **Connection Pooling**: PgBouncer with 600 pool size, 6000 max clients
- ✅ **Multi-Zone Deployment**: Availability Zones for fault tolerance
- ✅ **Automated Testing**: Comprehensive test suite for production readiness

**For detailed cluster information, see [CLUSTER_DETAILS.md](CLUSTER_DETAILS.md)**

## Deploy to Azure button

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgokhansalihyenigun%2Fazure-patroni-ha%2Fmain%2Fazuredeploy.json)

## What you get

- **Fully automated deployment** - Single-click deployment, no manual configuration required
- **DB tier** - 2 or 3 Patroni nodes (configurable), ILB 5432, probe HTTP 8008 path /primary
  - **VM Size**: Standard_D32s_v6 (default) - 32 vCPU, 128GB RAM - v6 series for maximum performance
  - **Disks**: Premium SSD v2 (default) - 80,000+ IOPS, 1,200 MB/s+ throughput
  - **PostgreSQL**: Version 16.10, max_connections=500 (optimized)
  - **Failover**: 4-7 seconds (optimized loop_wait=5s)
- **Patroni manages PostgreSQL** - No rsync, Patroni initializes cluster from scratch
- **Optional ELB** - 5432 for controlled external access
- **PgBouncer tier** - 2 VMs across zones, ILB 6432, probe TCP 6432, pool_mode transaction
  - **VM Size**: Standard_D16s_v6 - 16 vCPU, 64GB RAM
  - **Pool Size**: 600 (optimized, configurable default: 200)
  - **Max Client Connections**: 6000 (optimized, configurable default: 2000)
- **Flexible disk SKU** - PremiumV2_LRS (default, recommended), Premium_LRS, Premium_ZRS, StandardSSD_LRS, StandardSSD_ZRS, UltraSSD_LRS
- **NSG rules** - Scoped to VNet
- **NAT Gateway** - For outbound internet access (package installations)
- **Azure Monitor** - Agent ready

## Parameters

- **region**: Azure region (dropdown selection, default: Germany West Central)
- **prefix**: Resource name prefix (default: pgpatroni)
- **adminUsername**: VM admin username (default: azureuser)
- **adminPassword**: VM admin password (default: Azure123!@#)
- **vmSize**: Database VM size (dropdown, default: Standard_D32s_v6 - **32 vCPU, 128 GB RAM - v6 series for maximum performance**)
- **numberOfNodes**: Number of database nodes - 2 or 3 (default: 2)
- **dataDiskSizeGB**: Data disk size in GB (default: 1024)
- **walDiskSizeGB**: WAL disk size in GB (default: 512)
- **diskSku**: Managed disk SKU (dropdown, default: PremiumV2_LRS - **Premium SSD v2 for best performance**)
- **addressPrefix**: VNet address prefix (default: 10.50.0.0/16)
- **subnetPrefix**: Subnet address prefix (default: 10.50.1.0/24)
- **lbPrivateIP**: Database load balancer private IP (default: 10.50.1.10)
- **postgresPassword**: PostgreSQL superuser password (default: ChangeMe123Pass)
- **replicatorPassword**: PostgreSQL replicator password (default: ChangeMe123Pass)
- **enablePublicLB**: Enable public load balancer (default: false)
- **enablePgBouncerTier**: Enable PgBouncer tier (default: true)
- **pgbouncerLbPrivateIP**: PgBouncer load balancer private IP (default: 10.50.1.11)
- **pgbouncerDefaultPool**: PgBouncer default pool size (default: 200, optimized: 600)
- **pgbouncerMaxClientConn**: PgBouncer max client connections (default: 2000, optimized: 6000)
- **pgbouncerAdminUser**: PgBouncer admin user (default: pgbouncer)
- **pgbouncerAdminPass**: PgBouncer admin password (default: StrongPass123)

## How to deploy

- Click the button
- Set parameters
- Create

## Connection

- **Applications**: Connect to PgBouncer ILB `10.50.1.11:6432` (recommended for connection pooling)
- **Admin/ETL**: Connect directly to DB ILB `10.50.1.10:5432`
- **PostgreSQL Max Connections**: 500 (optimized, default: 100)
- **PgBouncer Pool Size**: 600 (optimized, configurable)
- **PgBouncer Max Client Connections**: 6000 (optimized, configurable)

## Automated Testing

After deployment, SSH into any database VM and run the comprehensive test suite:

```bash
# Download and run the test script (direct DB connection)
curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo bash

# Test via PgBouncer (recommended - realistic scenario)
export USE_PGBOUNCER=true; curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo -E bash
```

**Note:** When using `sudo bash`, use `sudo -E` to preserve environment variables like `USE_PGBOUNCER`.

The test script validates:
- ✅ VM connectivity (DB + PgBouncer)
- ✅ Patroni cluster health (leader + replicas)
- ✅ PostgreSQL connections (direct + Load Balancer)
- ✅ PgBouncer functionality and connection pooling
- ✅ Replication status and lag
- ✅ etcd cluster health
- ✅ High availability configuration
- ✅ Performance benchmarks (QPS, TPS, latency)
- ✅ Failover tests (normal and under load - 2k/3k/4k/8k QPS)
- ✅ Zero Data Loss (RPO=0) validation
- ✅ Write performance (TPS measurement)
- ✅ Latency tests (p50, p95, p99)
- ✅ Sustained load test (5 minutes)
- ✅ Concurrent connection stress test
- ✅ Replication lag monitoring
- ✅ Large transaction test

## Troubleshooting

If the test script shows "No replicas found", run the diagnostic script:

```bash
# Comprehensive cluster diagnostics
curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/diagnose-cluster.sh | bash

# Replica join diagnostics and fix suggestions
curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/fix-replica-join.sh | bash
```

Common issues and fixes:

**Issue: Split-brain (both nodes are leaders)**
- This indicates etcd cluster was not properly formed
- Run the split-brain fix script:
  ```bash
  # Non-interactive (recommended)
  AUTO_CONFIRM=yes ADMIN_PASS='Azure123!@#' curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/fix-split-brain.sh | bash
  
  # Or interactive (will ask for confirmation)
  ADMIN_PASS='Azure123!@#' curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/fix-split-brain.sh | bash
  ```
- The script will reinitialize one node as a replica

**Issue: No replicas found**
- Check if second VM (pgpatroni-2) is running: `ssh azureuser@10.50.1.5 'sudo systemctl status patroni'`
- Check Patroni logs on replica: `ssh azureuser@10.50.1.5 'sudo journalctl -u patroni -n 50'`
- Verify etcd cluster: `curl http://10.50.1.4:2379/health`
- Check if both nodes see the same etcd cluster: 
  ```bash
  ETCDCTL_API=3 etcdctl --endpoints=http://10.50.1.4:2379 member list
  ETCDCTL_API=3 etcdctl --endpoints=http://10.50.1.5:2379 member list
  ```
- If replica is stuck, restart Patroni on replica VM: `sudo systemctl restart patroni`

**Issue: PgBouncer connection failed**
- Check PgBouncer service: `ssh azureuser@10.50.1.7 'sudo systemctl status pgbouncer'`
- Verify backend connectivity: `ssh azureuser@10.50.1.7 'PGPASSWORD=ChangeMe123Pass psql -h 10.50.1.10 -p 5432 -U postgres -c "SELECT 1;"'`
- Check PgBouncer config: `ssh azureuser@10.50.1.7 'sudo cat /etc/pgbouncer/pgbouncer.ini'`

## Manual Checks

```bash
# Connect via PgBouncer
PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.11 -p 6432 -U postgres -d postgres -c "SELECT now();"

# Connect directly to database
PGPASSWORD='ChangeMe123Pass' psql -h 10.50.1.10 -p 5432 -U postgres -d postgres -c "SELECT version();"

# Check Patroni cluster status
curl -s http://10.50.1.4:8008/cluster | jq

# Check etcd cluster
ETCDCTL_API=3 etcdctl --endpoints=http://10.50.1.4:2379,http://10.50.1.5:2379 member list
```

## Performance Optimization

After deployment, run the optimization script to apply production-ready performance settings:

```bash
# Apply comprehensive optimizations (PostgreSQL, Patroni, etcd, PgBouncer, system-level)
curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/optimize-all-services.sh | bash
```

**Optimizations Applied:**
- PostgreSQL: Memory tuning (32GB shared_buffers, 96GB effective_cache_size), max_connections=500, parallel workers=30
- Patroni: Faster failover (loop_wait=5s, retry_timeout=5s)
- etcd: Improved performance (heartbeat=100ms, election_timeout=1000ms)
- PgBouncer: Increased pool_size=600, max_client_conn=6000
- System: Kernel tuning for high performance

**Performance Metrics (Tested):**
- Failover: 4-7 seconds (normal and under load)
- Write Performance: ~1,182 TPS (50 clients, 8 jobs)
- Latency: ~1.08 ms average (p50)
- Concurrent Connections: 200+ connections tested successfully
- Replication Lag: < 1 MB (near-zero lag)

For detailed performance metrics and cluster information, see [CLUSTER_DETAILS.md](CLUSTER_DETAILS.md)
