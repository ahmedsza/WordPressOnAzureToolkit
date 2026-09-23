param serverName string

resource mysqlServer 'Microsoft.DBforMySQL/flexibleServers@2021-12-01-preview' existing = {
  name: serverName
}

resource aadAuthenticationOnly 'Microsoft.DBforMySQL/flexibleServers/configurations@2021-12-01-preview' = {
  parent: mysqlServer
  name: 'aad_auth_only'
  properties: {
    value: 'ON'
  }
}
