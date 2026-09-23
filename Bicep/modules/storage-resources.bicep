param storageAccountName string
param blobContainerName string
param blobPublicAccessLevel string
param blobSoftDeleteRetentionDays int
param containerSoftDeleteRetentionDays int

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    restorePolicy: {
      enabled: false
    }
    deleteRetentionPolicy: {
      enabled: true
      days: blobSoftDeleteRetentionDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: containerSoftDeleteRetentionDays
    }
    changeFeed: {
      enabled: false
    }
    isVersioningEnabled: false
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: blobContainerName
  properties: {
    immutableStorageWithVersioning: {
      enabled: false
    }
    metadata: {}
    publicAccess: blobPublicAccessLevel
  }
}
