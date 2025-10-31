# Azure Patroni HA PostgreSQL

Azure Patroni HA, Active-Passive with ILB and optional ELB, plus PgBouncer tier

## Deploy to Azure button

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgokhansalihyenigun%2Fazure-patroni-ha%2Fmain%2Fazuredeploy.json)

## What you get

- **Fully automated deployment** - Single-click deployment, no manual configuration required
- **DB tier** - 2 or 3 Patroni nodes (configurable), ILB 5432, probe HTTP 8008 path /primary
- **Patroni manages PostgreSQL** - No rsync, Patroni initializes cluster from scratch
- **Optional ELB** - 5432 for controlled external access
- **PgBouncer tier** - 2 VMs across zones, ILB 6432, probe TCP 6432, pool_mode transaction
- **Flexible disk SKU** - Premium_LRS, Premium_ZRS, StandardSSD_LRS, StandardSSD_ZRS, UltraSSD_LRS
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
- **pgbouncerDefaultPool**: PgBouncer default pool size (default: 200)
- **pgbouncerMaxClientConn**: PgBouncer max client connections (default: 2000)
- **pgbouncerAdminUser**: PgBouncer admin user (default: pgbouncer)
- **pgbouncerAdminPass**: PgBouncer admin password (default: StrongPass123)

## How to deploy

- Click the button
- Set parameters
- Create

## Connection

- Apps connect to PgBouncer ILB 6432
- Admin, ETL, replication connect to DB ILB 5432

## Automated Testing

After deployment, SSH into any database VM and run the comprehensive test suite:

```bash
# Download and run the test script
curl -fsSL https://raw.githubusercontent.com/gokhansalihyenigun/azure-patroni-ha/main/scripts/test-deployment.sh | sudo bash
```

The test script validates:
- ✅ VM connectivity (DB + PgBouncer)
- ✅ Patroni cluster health (leader + replicas)
- ✅ PostgreSQL connections (direct + Load Balancer)
- ✅ PgBouncer functionality
- ✅ Replication status and lag
- ✅ etcd cluster health
- ✅ High availability configuration
- ✅ Performance benchmarks

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
