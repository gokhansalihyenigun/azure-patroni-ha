# Azure Patroni HA PostgreSQL

Azure Patroni HA, Active-Passive with ILB and optional ELB, plus PgBouncer tier

## Deploy to Azure button

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fgokhansalihyenigun%2Fazure-patroni-ha%2Fmain%2Fazuredeploy.json)

## What you get

- DB tier, Patroni primary, sync standby, witness, ILB 5432, probe HTTP 8008 path /primary
- Optional ELB 5432 for controlled external access
- PgBouncer tier, 2 VMs across zones, ILB 6432, probe TCP 6432, pool_mode transaction
- Premium SSD v2 data and wal disks
- NSG rules scoped to VNet
- Azure Monitor Agent ready

## Parameters

- adminUsername, adminSshPubKey
- addressPrefix, subnetPrefix, lbPrivateIP, pgbouncerLbPrivateIP
- zones array
- postgresPassword, replicatorPassword
- enablePublicLB true or false
- enablePgBouncerTier true or false
- pgbouncerDefaultPool, pgbouncerMaxClientConn, pgbouncerAdminUser, pgbouncerAdminPass

## How to deploy

- Click the button
- Set parameters
- Create

## Connection

- Apps connect to PgBouncer ILB 6432
- Admin, ETL, replication connect to DB ILB 5432

## Post deploy checks

- psql -h <PGBOUNCER_ILB_IP> -p 6432 -U postgres -d postgres -c "select now()"
- psql -h <DB_ILB_IP> -p 5432 -U postgres -d postgres -c "select now()"
