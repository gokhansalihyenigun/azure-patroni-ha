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
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output subnetId string = '${vnet.id}/subnets/${subnetName}'
