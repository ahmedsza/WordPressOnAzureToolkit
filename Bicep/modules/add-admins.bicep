param principalId string
param tenantId string
param managedIdentityResourceId string
param serverName string
param managedIdentityName string

resource mysqlServer 'Microsoft.DBforMySQL/flexibleServers@2021-12-01-preview' existing = {
  name: serverName
}

resource activeDirectoryAdministrator 'Microsoft.DBforMySQL/flexibleServers/administrators@2021-12-01-preview' = {
  parent: mysqlServer
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: managedIdentityName
    identityResourceId: managedIdentityResourceId
    sid: principalId
    tenantId: tenantId
  }
}
