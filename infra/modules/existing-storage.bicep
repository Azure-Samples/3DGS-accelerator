@description('Name of the existing Storage Account.')
param name string

@description('Whether shared key access is enabled on the existing account.')
param allowSharedKeyAccess bool = false

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: name
}

@description('The name of the Storage Account.')
output name string = storageAccount.name

@description('The resource ID of the Storage Account.')
output id string = storageAccount.id

@description('The primary connection string (only usable when allowSharedKeyAccess is true).')
output connectionString string = allowSharedKeyAccess
  ? 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  : ''
