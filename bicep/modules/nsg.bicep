@description('Location for the resource')
param location string

@description('NSG name')
param nsgName string

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'ssh'
        properties: {
          priority: 100
          access: 'Allow'
          protocol: 'Tcp'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'postgres'
        properties: {
          priority: 110
          access: 'Allow'
          protocol: 'Tcp'
          direction: 'Inbound'
          sourceAddressPrefix: '10.50.0.0/16'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '5432'
        }
      }
      {
        name: 'pgbouncer'
        properties: {
          priority: 115
          access: 'Allow'
          protocol: 'Tcp'
          direction: 'Inbound'
          sourceAddressPrefix: '10.50.0.0/16'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '6432'
        }
      }
      {
        name: 'patroni'
        properties: {
          priority: 120
          access: 'Allow'
          protocol: 'Tcp'
          direction: 'Inbound'
          sourceAddressPrefix: '10.50.0.0/16'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8008'
        }
      }
      {
        name: 'etcd'
        properties: {
          priority: 130
          access: 'Allow'
          protocol: 'Tcp'
          direction: 'Inbound'
          sourceAddressPrefix: '10.50.0.0/16'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '2379-2380'
        }
      }
    ]
  }
}

output nsgId string = nsg.id
