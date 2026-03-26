@description('Name of the Storage Account.')
param name string

@description('Azure region for the resource.')
param location string = resourceGroup().location

@description('Tags for the resource.')
param tags object = {}

@description('SKU for the Storage Account.')
param sku string = 'Standard_LRS'

@description('List of blob container names to create.')
param containerNames array = ['input', 'output', 'processed', 'error']

@description('Allow shared key (storage account key) access. Disabled by default for security; enable only when using key-based auth.')
param allowSharedKeyAccess bool = false

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: sku
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowSharedKeyAccess
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for containerName in containerNames: {
    parent: blobService
    name: containerName
    properties: {
      publicAccess: 'None'
    }
  }
]

@description('The name of the Storage Account.')
output name string = storageAccount.name

@description('The resource ID of the Storage Account.')
output id string = storageAccount.id

@description('The primary connection string (only usable when allowSharedKeyAccess is true).')
output connectionString string = allowSharedKeyAccess
  ? 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  : ''
