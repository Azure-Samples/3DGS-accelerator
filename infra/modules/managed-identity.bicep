@description('Name of the managed identity.')
param name string

@description('Azure region for the resource.')
param location string = resourceGroup().location

@description('Tags for the resource.')
param tags object = {}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

@description('The name of the managed identity.')
output name string = managedIdentity.name

@description('The principal ID of the managed identity.')
output principalId string = managedIdentity.properties.principalId

@description('The client ID of the managed identity.')
output clientId string = managedIdentity.properties.clientId

@description('The resource ID of the managed identity.')
output resourceId string = managedIdentity.id
