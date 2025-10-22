@description('Location for all resources')
param location string = 'westeurope'

@description('Prefix for resource naming')
param prefix string = 'pgpatroni'

@description('Admin username for VMs')
param adminUsername string

@description('SSH public key for admin user')
param adminSshPubKey string

@description('VM size for database nodes')
param vmSize string = 'Standard_D4s_v5'

@description('Data disk size in GB')
param dataDiskSizeGB int = 1024

@description('WAL disk size in GB')
param walDiskSizeGB int = 512

@description('VNet address prefix')
param addressPrefix string = '10.50.0.0/16'

@description('Subnet address prefix')
param subnetPrefix string = '10.50.1.0/24'

@description('Availability zones')
param zones array = ['1', '2', '3']

@description('Load balancer private IP')
param lbPrivateIP string = '10.50.1.10'

@description('PostgreSQL password')
@secure()
param postgresPassword string

@description('Replicator password')
@secure()
param replicatorPassword string

@description('Enable public load balancer')
param enablePublicLB bool = false

@description('Enable PgBouncer tier')
param enablePgBouncerTier bool = true

@description('PgBouncer load balancer private IP')
param pgbouncerLbPrivateIP string = '10.50.1.11'

@description('PgBouncer default pool size')
param pgbouncerDefaultPool int = 200

@description('PgBouncer max client connections')
param pgbouncerMaxClientConn int = 2000

@description('PgBouncer admin user')
param pgbouncerAdminUser string = 'pgbouncer'

@description('PgBouncer admin password')
@secure()
param pgbouncerAdminPass string

// Variables
var vnetName = '${prefix}-vnet'
var subnetName = 'db'
var nsgName = '${prefix}-nsg'
var ilbName = '${prefix}-ilb'
var elbName = '${prefix}-elb'
var pgbIlbName = '${prefix}-pgb-ilb'
var bePoolName = 'bepool'
var pgbBePoolName = 'pgb-bepool'
var probeName = 'patroniProbe'
var pgbProbeName = 'pgbProbe'
var lbruleName = 'pg'
var pgbRuleName = 'pgb'
var vmNames = [
  '${prefix}-1'
  '${prefix}-2'
  '${prefix}-3'
]
var vmIps = ['10.50.1.4', '10.50.1.5', '10.50.1.6']
var pgbVmNames = [
  '${prefix}-pgb-1'
  '${prefix}-pgb-2'
]
var pgbVmIps = ['10.50.1.7', '10.50.1.8']

// Modules
module vnet 'modules/vnet.bicep' = {
  name: 'vnet-deployment'
  params: {
    location: location
    vnetName: vnetName
    subnetName: subnetName
    addressPrefix: addressPrefix
    subnetPrefix: subnetPrefix
  }
}

module nsg 'modules/nsg.bicep' = {
  name: 'nsg-deployment'
  params: {
    location: location
    nsgName: nsgName
  }
}

module ilb 'modules/lb.bicep' = {
  name: 'ilb-deployment'
  params: {
    location: location
    lbName: ilbName
    lbPrivateIP: lbPrivateIP
    vnetName: vnetName
    subnetName: subnetName
    bePoolName: bePoolName
    probeName: probeName
    lbruleName: lbruleName
    isPublic: false
  }
}

module elb 'modules/lb.bicep' = {
  name: 'elb-deployment'
  params: {
    location: location
    lbName: elbName
    lbPrivateIP: lbPrivateIP
    vnetName: vnetName
    subnetName: subnetName
    bePoolName: bePoolName
    probeName: probeName
    lbruleName: lbruleName
    isPublic: true
    prefix: prefix
  }
  condition: enablePublicLB
}

module pgbIlb 'modules/lb.bicep' = {
  name: 'pgb-ilb-deployment'
  params: {
    location: location
    lbName: pgbIlbName
    lbPrivateIP: pgbouncerLbPrivateIP
    vnetName: vnetName
    subnetName: subnetName
    bePoolName: pgbBePoolName
    probeName: pgbProbeName
    lbruleName: pgbRuleName
    isPublic: false
    port: 6432
    probePort: 6432
    probeProtocol: 'Tcp'
  }
  condition: enablePgBouncerTier
}

module vm 'modules/vm.bicep' = {
  name: 'vm-deployment'
  params: {
    location: location
    vmNames: vmNames
    vmIps: vmIps
    zones: zones
    vmSize: vmSize
    dataDiskSizeGB: dataDiskSizeGB
    walDiskSizeGB: walDiskSizeGB
    adminUsername: adminUsername
    adminSshPubKey: adminSshPubKey
    vnetName: vnetName
    subnetName: subnetName
    nsgName: nsgName
    ilbName: ilbName
    bePoolName: bePoolName
    postgresPassword: postgresPassword
    replicatorPassword: replicatorPassword
  }
}

module pgbVm 'modules/pgbouncer-vm.bicep' = {
  name: 'pgb-vm-deployment'
  params: {
    location: location
    vmNames: pgbVmNames
    vmIps: pgbVmIps
    zones: zones
    vmSize: 'Standard_D2s_v5'
    adminUsername: adminUsername
    adminSshPubKey: adminSshPubKey
    vnetName: vnetName
    subnetName: subnetName
    nsgName: nsgName
    ilbName: pgbIlbName
    bePoolName: pgbBePoolName
    dbIlbIP: lbPrivateIP
    pgbouncerAdminUser: pgbouncerAdminUser
    pgbouncerAdminPass: pgbouncerAdminPass
    pgbouncerDefaultPool: pgbouncerDefaultPool
    pgbouncerMaxClientConn: pgbouncerMaxClientConn
  }
  condition: enablePgBouncerTier
}

// Outputs
output dbIlbIP string = ilb.outputs.lbPrivateIP
output elbIP string = enablePublicLB ? elb.outputs.lbPublicIP : 'disabled'
output pgbIlbIP string = enablePgBouncerTier ? pgbIlb.outputs.lbPrivateIP : 'disabled'
