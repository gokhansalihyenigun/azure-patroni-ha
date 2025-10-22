@description('Location for the resource')
param location string

@description('Load balancer name')
param lbName string

@description('Load balancer private IP')
param lbPrivateIP string

@description('VNet name')
param vnetName string

@description('Subnet name')
param subnetName string

@description('Backend pool name')
param bePoolName string

@description('Probe name')
param probeName string

@description('Load balancing rule name')
param lbruleName string

@description('Is public load balancer')
param isPublic bool = false

@description('Prefix for resource naming')
param prefix string = ''

@description('Port for load balancer')
param port int = 5432

@description('Probe port')
param probePort int = 8008

@description('Probe protocol')
param probeProtocol string = 'Http'

@description('Probe request path')
param probeRequestPath string = '/primary'

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  name: subnetName
  parent: vnet
}

resource publicIP 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${lbName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
  condition: isPublic
}

resource lb 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: lbName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe'
        properties: isPublic ? {
          publicIPAddress: {
            id: publicIP.id
          }
        } : {
          subnet: {
            id: subnet.id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: lbPrivateIP
        }
      }
    ]
    backendAddressPools: [
      {
        name: bePoolName
      }
    ]
    probes: [
      {
        name: probeName
        properties: {
          protocol: probeProtocol
          port: probePort
          requestPath: probeProtocol == 'Http' ? probeRequestPath : ''
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: lbruleName
        properties: {
          frontendIPConfiguration: {
            id: '${lb.id}/frontendIPConfigurations/fe'
          }
          backendAddressPool: {
            id: '${lb.id}/backendAddressPools/${bePoolName}'
          }
          protocol: 'Tcp'
          frontendPort: port
          backendPort: port
          enableFloatingIP: false
          idleTimeoutInMinutes: 30
          probe: {
            id: '${lb.id}/probes/${probeName}'
          }
        }
      }
    ]
  }
}

output lbId string = lb.id
output lbPrivateIP string = lb.properties.frontendIPConfigurations[0].properties.privateIPAddress
output lbPublicIP string = isPublic ? publicIP.properties.ipAddress : ''
