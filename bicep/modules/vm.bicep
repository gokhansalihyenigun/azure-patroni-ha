@description('Location for the resource')
param location string

@description('VM names array')
param vmNames array

@description('VM IPs array')
param vmIps array

@description('Availability zones')
param zones array

@description('VM size')
param vmSize string

@description('Data disk size in GB')
param dataDiskSizeGB int

@description('WAL disk size in GB')
param walDiskSizeGB int

@description('Admin username')
param adminUsername string

@description('SSH public key')
param adminSshPubKey string

@description('VNet name')
param vnetName string

@description('Subnet name')
param subnetName string

@description('NSG name')
param nsgName string

@description('Load balancer name')
param ilbName string

@description('Backend pool name')
param bePoolName string

@description('PostgreSQL password')
@secure()
param postgresPassword string

@description('Replicator password')
@secure()
param replicatorPassword string

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  name: subnetName
  parent: vnet
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' existing = {
  name: nsgName
}

resource lb 'Microsoft.Network/loadBalancers@2023-11-01' existing = {
  name: ilbName
}

resource backendPool 'Microsoft.Network/loadBalancers/backendAddressPools@2023-11-01' existing = {
  name: bePoolName
  parent: lb
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = [for i in range(length(vmNames)): {
  name: '${vmNames[i]}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: vmIps[i]
          loadBalancerBackendAddressPools: [
            {
              id: backendPool.id
            }
          ]
        }
      }
    ]
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}]

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = [for i in range(length(vmNames)): {
  name: vmNames[i]
  location: location
  zones: [zones[i]]
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmNames[i]
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPubKey
            }
          ]
        }
      }
      customData: base64(loadFileContent('cloudinit/cloud-init.yaml'))
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: dataDiskSizeGB > 0 ? [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGB
          managedDisk: {
            storageAccountType: 'PremiumV2_LRS'
          }
        }
        {
          lun: 1
          createOption: 'Empty'
          diskSizeGB: walDiskSizeGB
          managedDisk: {
            storageAccountType: 'PremiumV2_LRS'
          }
        }
      ] : []
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic[i].id
        }
      ]
    }
  }
}]

output vmIds array = [for i in range(length(vmNames)): vm[i].id]