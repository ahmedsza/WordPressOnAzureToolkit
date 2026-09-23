@description('Stable lowercase workload identifier without an environment suffix. Use letters, numbers, and hyphens only, for example wordpress-example.')
@maxLength(34)
param name string
param location string = 'West Europe'
@allowed([
  'dev'
  'test'
  'prod'
])
param environmentName string
param wordpressAdminEmail string
param wordpressUsername string = 'wpadmin'

@secure()
param wordpressPassword string
param wpLocaleCode string = 'en_US'
param serverUsername string = 'wpdbadmin'

@secure()
param serverPassword string
param emailDataLocation string = 'unitedstates'
param appServiceZoneRedundant bool = true
param appServicePlanSkuName string = 'P1V3'
param appServicePlanSkuTier string = 'PremiumV3'
@minValue(1)
param appServicePlanCapacity int = 3
@allowed([
  'Disabled'
  'SameZone'
  'ZoneRedundant'
])
param mysqlHighAvailabilityMode string = 'ZoneRedundant'
param mysqlSkuName string = 'Standard_D2ds_v4'
param mysqlSkuTier string = 'GeneralPurpose'
param kind string = 'linux'
param reserved bool = true
param alwaysOn bool = true
param ftpsState string = 'FtpsOnly'
param linuxFxVersion string = 'sitecontainers'
param siteContainerName string = 'main'
param siteContainerImage string = 'mcr.microsoft.com/appsvc/wordpress-debian-php:8.4'
param storageSizeGB int = 128
param storageIops int = 700
param storageAutoGrow string = 'Enabled'
param storageAutoIoScaling string = 'Enabled'
param backupRetentionDays int = 7
param geoRedundantBackup string = 'Disabled'
param publicNetworkAccess string = 'Disabled'
param charset string = 'utf8'
param collation string = 'utf8_general_ci'
param storageAccountType string = 'Standard_RAGRS'
param storageAccountKind string = 'StorageV2'
param accessTier string = 'Hot'
param minimumTlsVersion string = 'TLS1_2'
param supportsHttpsTrafficOnly bool = true
param keySource string = 'Microsoft.Storage'
param encryptionEnabled bool = true
param infrastructureEncryptionEnabled bool = false
@allowed([
  'Balanced_B0'
  'Balanced_B1'
  'Balanced_B3'
])
param redisSkuName string = 'Balanced_B0'
param redisHighAvailabilityEnabled bool = true
param vnetAddressSpace string = '10.0.0.0/23'
param appSubnetAddressPrefix string = '10.0.0.0/25'
param databaseSubnetAddressPrefix string = '10.0.1.0/25'
param privateEndpointSubnetAddressPrefix string = '10.0.2.0/25'
@minValue(1)
@maxValue(365)
param blobSoftDeleteRetentionDays int = 7
@minValue(1)
@maxValue(365)
param containerSoftDeleteRetentionDays int = 7
param frontDoorHealthProbePath string = '/'
@allowed([
  30
  60
  100
])
param frontDoorHealthProbeIntervalInSeconds int = 100
@allowed([
  'Detection'
  'Prevention'
])
param frontDoorWafMode string = 'Prevention'
param keyVaultPurgeProtectionEnabled bool = true
@minValue(7)
@maxValue(90)
param keyVaultSoftDeleteRetentionDays int = 90

var subscriptionId = subscription().subscriptionId
var resourceGroupName = resourceGroup().name
var deploymentPrefix = '${name}-${environmentName}'
var uniqueSuffix = uniqueString(resourceGroup().id, deploymentPrefix)
var keyVaultUniqueSuffix = uniqueString(subscription().id, resourceGroup().id, deploymentPrefix)
var deploymentId = '${deploymentPrefix}-${uniqueSuffix}'
var sanitizedName = toLower(replace(replace(deploymentPrefix, '-', ''), '_', ''))
var hostingPlanName = 'asp-${deploymentPrefix}-${uniqueSuffix}'
var managedIdentityName = '${deploymentPrefix}-identity'
var serverName = toLower('${deploymentPrefix}-mysql-${uniqueSuffix}')
var databaseName = toLower('${sanitizedName}_db')
var storageAccountName = toLower('${take('${sanitizedName}wp', 11)}${uniqueSuffix}')
var blobContainerName = toLower('blob${storageAccountName}')
var webAppName = toLower(take('${sanitizedName}-wp-${environmentName}-${uniqueSuffix}', 60))
var vnetName = '${deploymentPrefix}-vnet'
var subnetForApp = '${deploymentPrefix}-appsubnet'
var subnetForDb = '${deploymentPrefix}-dbsubnet'
var subnetForPrivateEndpoints = '${deploymentPrefix}-pesubnet'
var keyVaultName = toLower('kv-${take(sanitizedName, 5)}-${environmentName}-${take(keyVaultUniqueSuffix, 10)}')
var redisName = toLower(take('${sanitizedName}redis${uniqueSuffix}', 63))
var frontDoorProfileName = '${deploymentPrefix}-afd'
var frontDoorEndpointName = toLower(take('${sanitizedName}afd${uniqueSuffix}', 45))
var frontDoorWafPolicyName = take('${sanitizedName}waf', 128)
var logAnalyticsWorkspaceName = toLower(take('${sanitizedName}law${uniqueSuffix}', 63))
var applicationInsightsName = toLower(take('${sanitizedName}appi${uniqueSuffix}', 63))
var emailCommServiceName = '${deploymentPrefix}-email-acs-${uniqueSuffix}'
var commServiceName = '${deploymentPrefix}-acs-${uniqueSuffix}'
var databaseVersion = '8.4'
var acsSenderEmailAddress = 'DoNotReply'
var managedIdentityApiVersion = '2018-11-30'
var resourceTags = {
  AppProfile: 'Wordpress'
  Environment: environmentName
  WordPressDeploymentID: deploymentId
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: resourceTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  kind: 'web'
  tags: resourceTags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource wordpressSite 'Microsoft.Web/sites@2021-03-01' = {
  name: webAppName
  location: location
  tags: resourceTags
  properties: {
    siteConfig: {
      ftpsState: ftpsState
      linuxFxVersion: linuxFxVersion
    }
    serverFarmId: '/subscriptions/${subscriptionId}/resourcegroups/${resourceGroupName}/providers/Microsoft.Web/serverfarms/${hostingPlanName}'
    clientAffinityEnabled: false
    httpsOnly: true
    keyVaultReferenceIdentity: managedIdentity.id
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  dependsOn: [
    hostingPlan
    server
    serverName_database
    aadAuthenticationOnly
    storageResources
  ]
}

resource hostingPlan 'Microsoft.Web/serverfarms@2021-03-01' = {
  name: hostingPlanName
  location: location
  kind: kind
  tags: resourceTags
  properties: {
    reserved: reserved
    zoneRedundant: appServiceZoneRedundant
  }
  sku: {
    tier: appServicePlanSkuTier
    name: appServicePlanSkuName
    capacity: appServicePlanCapacity
  }
  dependsOn: [
    server
  ]
}

resource wordpressSiteContainer 'Microsoft.Web/sites/sitecontainers@2024-04-01' = {
  parent: wordpressSite
  name: siteContainerName
  properties: {
    image: siteContainerImage
    isMain: true
    authType: 'Anonymous'
    targetPort: '80'
    environmentVariables: []
  }
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: managedIdentityName
  location: location
  tags: resourceTags
}

resource server 'Microsoft.DBforMySQL/flexibleServers@2024-12-30' = {
  location: location
  name: serverName
  tags: resourceTags
  properties: {
    version: databaseVersion
    administratorLogin: serverUsername
    administratorLoginPassword: serverPassword
    storage: {
      storageSizeGB: storageSizeGB
      iops: storageIops
      autoGrow: storageAutoGrow
      autoIoScaling: storageAutoIoScaling
    }
    backup: {
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: geoRedundantBackup
    }
    network: {
      publicNetworkAccess: publicNetworkAccess
    }
    highAvailability: {
      mode: mysqlHighAvailabilityMode
    }
    availabilityZone: ''
  }
  sku: {
    name: mysqlSkuName
    tier: mysqlSkuTier
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
}

resource serverName_database 'Microsoft.DBforMySQL/flexibleServers/databases@2021-12-01-preview' = {
  parent: server
  name: databaseName
  properties: {
    charset: charset
    collation: collation
  }
}

// The MySQL RP allows only one control-plane operation per server at a time and
// returns 429 for concurrent ones, so every server-scoped resource below is chained.
resource serverName_sql_generate_invisible_primary_key 'Microsoft.DBforMySQL/flexibleServers/configurations@2021-12-01-preview' = {
  parent: server
  name: 'sql_generate_invisible_primary_key'
  properties: {
    value: 'OFF'
  }
  dependsOn: [
    serverName_database
  ]
}

module aadAuthenticationOnly './modules/server-parameters-aad-auth-only.bicep' = {
  params: {
    serverName: server.name
  }
  dependsOn: [
    addAdmins
  ]
}

module addAdmins './modules/add-admins.bicep' = {
  params: {
    principalId: managedIdentity.properties.principalId
    tenantId: subscription().tenantId
    managedIdentityResourceId: managedIdentity.id
    serverName: server.name
    managedIdentityName: managedIdentityName
  }
  dependsOn: [
    serverName_sql_generate_invisible_primary_key
  ]
}

// Subnets are declared inline because a VNet PUT replaces the whole subnet collection:
// defining them as separate child resources makes every redeploy try to delete the in-use subnets.
resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  location: location
  name: vnetName
  tags: resourceTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: subnetForApp
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
      {
        name: subnetForDb
        properties: {
          addressPrefix: databaseSubnetAddressPrefix
        }
      }
      {
        name: subnetForPrivateEndpoints
        properties: {
          addressPrefix: privateEndpointSubnetAddressPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource wordpressSiteVirtualNetwork 'Microsoft.Web/sites/networkConfig@2021-03-01' = {
  parent: wordpressSite
  name: 'virtualNetwork'
  properties: {
    subnetResourceId: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetForApp)
  }
  dependsOn: [
    vnet
    mysqlPrivateDnsLink
  ]
}

resource emailCommService 'Microsoft.Communication/emailServices@2023-03-31' = {
  name: emailCommServiceName
  location: 'global'
  tags: resourceTags
  properties: {
    dataLocation: emailDataLocation
  }
}

resource commService 'Microsoft.Communication/CommunicationServices@2023-03-31' = {
  name: commServiceName
  location: 'global'
  tags: resourceTags
  properties: {
    dataLocation: emailDataLocation
    linkedDomains: [
      emailCommServiceName_AzureManagedDomain.id
    ]
  }
}

resource emailCommServiceName_AzureManagedDomain 'Microsoft.Communication/emailServices/domains@2023-03-31' = {
  parent: emailCommService
  name: 'AzureManagedDomain'
  location: 'global'
  tags: resourceTags
  properties: {
    domainManagement: 'AzureManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource resourceGroupName_commServiceName_CustomEmailContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(resourceGroupName, commServiceName, 'CustomEmailContributorRole')
  properties: {
    roleName: 'Custom Email Contributor Role - ${commServiceName}'
    description: 'Custom Email Contributor role for Azure Communication Services'
    assignableScopes: [
      '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}'
    ]
    permissions: [
      {
        actions: [
          'Microsoft.Communication/CommunicationServices/Read'
          'Microsoft.Communication/CommunicationServices/Write'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource Microsoft_Communication_CommunicationServices_commServiceName_managedIdentityName_Contributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: commService
  name: guid(commService.id, managedIdentityName, 'Contributor')
  properties: {
    roleDefinitionId: '/subscriptions/${subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/${guid(resourceGroupName,commServiceName,'CustomEmailContributorRole')}'
    principalId: reference(managedIdentity.id, managedIdentityApiVersion).principalId
  }
  dependsOn: [
    resourceGroupName_commServiceName_CustomEmailContributorRole
  ]
}

module appServiceConfiguration './modules/app-service-resources.bicep' = {
  params: {
    identityInfo: {
      clientId: managedIdentity.properties.clientId
    }
    acsAccount: {
      hostName: commService.properties.hostName
    }
    emailDomain: {
      mailFromSenderDomain: emailCommServiceName_AzureManagedDomain.properties.mailFromSenderDomain
    }
    serverName: server.name
    databaseName: databaseName
    managedIdentityName: managedIdentityName
    storageAccountName: storageAccount.name
    blobContainerName: blobContainerName
    acsSenderEmailAddress: acsSenderEmailAddress
    keyVaultName: keyVault.name
    redisHostName: redis.properties.hostName
    appServiceName: wordpressSite.name
    appServiceAlwaysOn: alwaysOn
    applicationInsightsConnectionString: applicationInsights.properties.ConnectionString
    frontDoorId: frontDoorProfile.properties.frontDoorId
    frontDoorEndpointHostName: frontDoorEndpoint.properties.hostName
    wordpressAdminEmail: wordpressAdminEmail
    wordpressUsername: wordpressUsername
    wordpressPassword: wordpressPassword
    wpLocaleCode: wpLocaleCode
  }
  dependsOn: [
    keyVaultSecretsUser
    redisPrimaryKeySecret
  ]
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: resourceTags
  properties: {
    accessTier: accessTier
    minimumTlsVersion: minimumTlsVersion
    supportsHttpsTrafficOnly: supportsHttpsTrafficOnly
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      ipRules: []
    }
    encryption: {
      keySource: keySource
      services: {
        blob: {
          enabled: encryptionEnabled
        }
        file: {
          enabled: encryptionEnabled
        }
        table: {
          enabled: encryptionEnabled
        }
        queue: {
          enabled: encryptionEnabled
        }
      }
      requireInfrastructureEncryption: infrastructureEncryptionEnabled
    }
  }
  kind: storageAccountKind
  sku: {
    name: storageAccountType
  }
  dependsOn: [
    server
  ]
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: resourceTags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVaultSoftDeleteRetentionDays
    // Key Vault rejects an explicit false, so the property must be omitted when disabled.
    enablePurgeProtection: keyVaultPurgeProtectionEnabled ? true : null
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
    }
  }
}

resource redis 'Microsoft.Cache/redisEnterprise@2025-07-01' = {
  name: redisName
  location: location
  tags: resourceTags
  sku: {
    name: redisSkuName
  }
  properties: any({
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    highAvailability: redisHighAvailabilityEnabled ? 'Enabled' : 'Disabled'
  })
}

resource redisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-05-01-preview' = {
  parent: redis
  name: 'default'
  properties: {
    accessKeysAuthentication: 'Enabled'
    clientProtocol: 'Encrypted'
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'VolatileLru'
    port: 10000
  }
}

resource wordpressAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'wordpress-admin-password'
  properties: {
    value: wordpressPassword
  }
}

resource mysqlAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'mysql-admin-password'
  properties: {
    value: serverPassword
  }
}

resource redisPrimaryKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'redis-primary-key'
  properties: {
    value: redisDatabase.listKeys().primaryKey
  }
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, managedIdentity.id, 'KeyVaultSecretsUser')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource keyVaultCryptoUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, managedIdentity.id, 'KeyVaultCryptoUser')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '12338af0-0e69-4776-bea7-57ae8d297424')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource storagePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: resourceTags
}

resource keyVaultPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: resourceTags
}

resource redisPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.redis.azure.net'
  location: 'global'
  tags: resourceTags
}

resource mysqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.mysql.database.azure.com'
  location: 'global'
  tags: resourceTags
}

resource storagePrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: storagePrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource keyVaultPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: keyVaultPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource redisPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: redisPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource mysqlPrivateDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: mysqlPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${storageAccountName}-blob-pe'
  location: location
  tags: resourceTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetForPrivateEndpoints)
    }
    privateLinkServiceConnections: [
      {
        name: 'storage-blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
  dependsOn: [
    storagePrivateDnsLink
    vnet
  ]
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${keyVaultName}-pe'
  location: location
  tags: resourceTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetForPrivateEndpoints)
    }
    privateLinkServiceConnections: [
      {
        name: 'keyvault'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
  dependsOn: [
    keyVaultPrivateDnsLink
    vnet
    storagePrivateEndpoint
  ]
}

resource redisPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${redisName}-pe'
  location: location
  tags: resourceTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetForPrivateEndpoints)
    }
    privateLinkServiceConnections: [
      {
        name: 'redis'
        properties: {
          privateLinkServiceId: redis.id
          groupIds: [
            'redisEnterprise'
          ]
        }
      }
    ]
  }
  dependsOn: [
    redisPrivateDnsLink
    vnet
    keyVaultPrivateEndpoint
  ]
}

resource mysqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: '${serverName}-pe'
  location: location
  tags: resourceTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetForPrivateEndpoints)
    }
    privateLinkServiceConnections: [
      {
        name: 'mysql'
        properties: {
          privateLinkServiceId: server.id
          groupIds: [
            'mysqlServer'
          ]
        }
      }
    ]
  }
  dependsOn: [
    mysqlPrivateDnsLink
    vnet
    redisPrivateEndpoint
    aadAuthenticationOnly
  ]
}

resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: storagePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'storage-blob'
        properties: {
          privateDnsZoneId: storagePrivateDnsZone.id
        }
      }
    ]
  }
}

resource keyVaultPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'keyvault'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZone.id
        }
      }
    ]
  }
}

resource redisPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: redisPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'redis'
        properties: {
          privateDnsZoneId: redisPrivateDnsZone.id
        }
      }
    ]
  }
}

resource mysqlPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: mysqlPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'mysql'
        properties: {
          privateDnsZoneId: mysqlPrivateDnsZone.id
        }
      }
    ]
  }
}

resource frontDoorProfile 'Microsoft.Cdn/profiles@2023-05-01' = {
  name: frontDoorProfileName
  location: 'global'
  tags: resourceTags
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
}

resource frontDoorEndpoint 'Microsoft.Cdn/profiles/afdEndpoints@2023-05-01' = {
  parent: frontDoorProfile
  name: frontDoorEndpointName
  location: 'global'
  properties: {
    enabledState: 'Enabled'
  }
}

resource frontDoorOriginGroup 'Microsoft.Cdn/profiles/originGroups@2023-05-01' = {
  parent: frontDoorProfile
  name: 'wordpress'
  properties: {
    healthProbeSettings: {
      probePath: frontDoorHealthProbePath
      probeRequestType: 'GET'
      probeProtocol: 'Https'
      probeIntervalInSeconds: frontDoorHealthProbeIntervalInSeconds
    }
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 0
    }
    sessionAffinityState: 'Disabled'
  }
}

resource frontDoorOrigin 'Microsoft.Cdn/profiles/originGroups/origins@2023-05-01' = {
  parent: frontDoorOriginGroup
  name: 'wordpress-app-service'
  properties: {
    hostName: wordpressSite.properties.defaultHostName
    originHostHeader: wordpressSite.properties.defaultHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource frontDoorRoute 'Microsoft.Cdn/profiles/afdEndpoints/routes@2023-05-01' = {
  parent: frontDoorEndpoint
  name: 'wordpress'
  properties: {
    originGroup: {
      id: frontDoorOriginGroup.id
    }
    supportedProtocols: [
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    httpsRedirect: 'Enabled'
    linkToDefaultDomain: 'Enabled'
    enabledState: 'Enabled'
  }
  dependsOn: [
    frontDoorOrigin
  ]
}

resource frontDoorWafPolicy 'Microsoft.Network/frontdoorwebapplicationfirewallpolicies@2024-02-01' = {
  name: frontDoorWafPolicyName
  location: 'global'
  tags: resourceTags
  sku: {
    name: 'Standard_AzureFrontDoor'
  }
  properties: {
    policySettings: {
      enabledState: 'Enabled'
      mode: frontDoorWafMode
      requestBodyCheck: 'Enabled'
    }
  }
}

resource frontDoorSecurityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2023-05-01' = {
  parent: frontDoorProfile
  name: 'wordpress-waf'
  properties: {
    parameters: {
      type: 'WebApplicationFirewall'
      wafPolicy: {
        id: frontDoorWafPolicy.id
      }
      associations: [
        {
          domains: [
            {
              id: frontDoorEndpoint.id
            }
          ]
          patternsToMatch: [
            '/*'
          ]
        }
      ]
    }
  }
}

module storageBlobDataContributor './modules/storage-role-assignment-managed-identity.bicep' = {
  scope: resourceGroup(subscriptionId, resourceGroupName)
  params: {
    identityInfo: {
      principalId: managedIdentity.properties.principalId
    }
    storageAccountName: storageAccount.name
    managedIdentityName: managedIdentityName
  }
  dependsOn: [
    storageResources
  ]
}

module storageResources './modules/storage-resources.bicep' = {
  scope: resourceGroup(subscriptionId, resourceGroupName)
  params: {
    storageAccountName: storageAccount.name
    blobContainerName: blobContainerName
    blobPublicAccessLevel: 'None'
    blobSoftDeleteRetentionDays: blobSoftDeleteRetentionDays
    containerSoftDeleteRetentionDays: containerSoftDeleteRetentionDays
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' existing = {
  parent: storageAccount
  name: 'default'
}

resource webAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: wordpressSite
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource appServicePlanDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: hostingPlan
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource mysqlDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: server
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: blobService
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: keyVault
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource redisDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: redis
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Connection audit events are only exposed on the database, not the Redis cluster.
resource redisDatabaseDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: redisDatabase
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource frontDoorDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: frontDoorProfile
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource communicationServicesDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: commService
  name: 'send-to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output frontDoorEndpointHostName string = frontDoorEndpoint.properties.hostName
output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultNameOutput string = keyVault.name
output storageAccountNameOutput string = storageAccount.name
output redisDatabaseHostName string = redis.properties.hostName
output logAnalyticsWorkspaceResourceId string = logAnalyticsWorkspace.id
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
