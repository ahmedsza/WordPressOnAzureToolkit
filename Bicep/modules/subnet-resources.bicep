param vnetName string
param appSubnetName string
param databaseSubnetName string
param privateEndpointSubnetName string
param appSubnetAddressPrefix string
param databaseSubnetAddressPrefix string
param privateEndpointSubnetAddressPrefix string

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' existing = {
  name: vnetName
}

resource appSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = {
  parent: vnet
  name: appSubnetName
  properties: {
    addressPrefix: appSubnetAddressPrefix
    delegations: [
      {
        name: 'dlg-appService'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
}

resource databaseSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = {
  parent: vnet
  name: databaseSubnetName
  properties: {
    addressPrefix: databaseSubnetAddressPrefix
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-07-01' = {
  parent: vnet
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetAddressPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}
