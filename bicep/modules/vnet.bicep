@description('Location for the resource')
param location string

@description('VNet name')
param vnetName string

@description('Subnet name')
param subnetName string

@description('VNet address prefix')
param addressPrefix string

@description('Subnet address prefix')
param subnetPrefix string

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: subnetPrefix
          natGateway: {
            id: nat.id
          }
        }
      }
    ]
  }
}

@description('Enable NAT Gateway integration')
param enableNatGateway bool = true

var natName = '${vnetName}-nat'
var natPipName = '${vnetName}-nat-pip'

resource natPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (enableNatGateway) {
  name: natPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nat 'Microsoft.Network/natGateways@2023-11-01' = if (enableNatGateway) {
  name: natName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPip.id
      }
    ]
    idleTimeoutInMinutes: 4
  }
}

output vnetId string = vnet.id
output subnetId string = '${vnet.id}/subnets/${subnetName}'
