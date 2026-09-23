param identityInfo object
param acsAccount object
param emailDomain object
param serverName string
param databaseName string
param managedIdentityName string
param storageAccountName string
param blobContainerName string
param acsSenderEmailAddress string
param keyVaultName string
param redisHostName string
param appServiceName string
param appServiceAlwaysOn bool
param applicationInsightsConnectionString string
param frontDoorId string
param frontDoorEndpointHostName string
param wordpressAdminEmail string
param wordpressUsername string
@secure()
param wordpressPassword string
param wpLocaleCode string

resource appService 'Microsoft.Web/sites@2021-03-01' existing = {
  name: appServiceName
}

resource webConfiguration 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: appService
  name: 'web'
  properties: {
    alwaysOn: appServiceAlwaysOn
    healthCheckPath: '/'
    ipSecurityRestrictionsDefaultAction: 'Deny'
    scmIpSecurityRestrictionsUseMain: true
    ipSecurityRestrictions: [
      {
        name: 'Allow-Azure-Front-Door'
        description: 'Allow traffic from this Front Door profile only.'
        action: 'Allow'
        priority: 100
        tag: 'ServiceTag'
        ipAddress: 'AzureFrontDoor.Backend'
        headers: {
          'X-Azure-FDID': [
            frontDoorId
          ]
        }
      }
    ]
    appSettings: [
      {
        name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
        value: 'true'
      }
      {
        name: 'AFD_ENABLED'
        value: 'true'
      }
      {
        name: 'AFD_ENDPOINT'
        value: frontDoorEndpointHostName
      }
      {
        name: 'DATABASE_HOST'
        value: '${serverName}.mysql.database.azure.com'
      }
      {
        name: 'DATABASE_NAME'
        value: databaseName
      }
      {
        name: 'WEBSITES_CONTAINER_START_TIME_LIMIT'
        value: '1800'
      }
      {
        name: 'WORDPRESS_LOCALE_CODE'
        value: wpLocaleCode
      }
      {
        name: 'SETUP_PHPMYADMIN'
        value: 'true'
      }
      {
        name: 'WORDPRESS_LOCAL_STORAGE_CACHE_ENABLED'
        value: 'false'
      }
      {
        name: 'ENTRA_CLIENT_ID'
        value: identityInfo.clientId
      }
      {
        name: 'ENABLE_MYSQL_MANAGED_IDENTITY'
        value: 'true'
      }
      {
        name: 'DATABASE_USERNAME'
        value: managedIdentityName
      }
      {
        name: 'BLOB_STORAGE_ENABLED'
        value: 'true'
      }
      {
        name: 'STORAGE_ACCOUNT_NAME'
        value: storageAccountName
      }
      {
        name: 'BLOB_CONTAINER_NAME'
        value: blobContainerName
      }
      {
        name: 'BLOB_STORAGE_URL'
        value: '${storageAccountName}.blob.${environment().suffixes.storage}'
      }
      {
        name: 'ENABLE_BLOB_MANAGED_IDENTITY'
        value: 'true'
      }
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: applicationInsightsConnectionString
      }
      {
        name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
        value: '~3'
      }
      {
        name: 'REDIS_HOST'
        value: redisHostName
      }
      {
        name: 'REDIS_PORT'
        value: '10000'
      }
      {
        name: 'REDIS_PASSWORD'
        value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=redis-primary-key)'
      }
      {
        name: 'WP_REDIS_HOST'
        value: redisHostName
      }
      {
        name: 'WP_REDIS_PASSWORD'
        value: '@Microsoft.KeyVault(VaultName=${keyVaultName};SecretName=redis-primary-key)'
      }
      {
        name: 'WP_EMAIL_CONNECTION_STRING'
        value: 'endpoint=https://${acsAccount.hostName};senderaddress=${acsSenderEmailAddress}@${emailDomain.mailFromSenderDomain}'
      }
      {
        name: 'ENABLE_EMAIL_MANAGED_IDENTITY'
        value: 'true'
      }
    ]
    connectionStrings: [
      {
        name: 'WORDPRESS_ADMIN_EMAIL'
        connectionString: wordpressAdminEmail
        type: 'Custom'
      }
      {
        name: 'WORDPRESS_ADMIN_USER'
        connectionString: wordpressUsername
        type: 'Custom'
      }
      {
        name: 'WORDPRESS_ADMIN_PASSWORD'
        connectionString: wordpressPassword
        type: 'Custom'
      }
    ]
  }
}
