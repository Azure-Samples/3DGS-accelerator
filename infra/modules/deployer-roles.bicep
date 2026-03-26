@description('Name of the Azure Container Registry.')
param containerRegistryName string

@description('Name of the Storage Account.')
param storageAccountName string

@description('Principal ID of the deployer (signed-in user).')
param deployerPrincipalId string

// AcrPush — deployer can push images during azd deploy
var acrPushRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '8311e382-0749-4cb8-b61a-304f252e45ec'
)

// Storage Blob Data Contributor — deployer can upload/manage blobs
var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: containerRegistryName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource acrPushAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, deployerPrincipalId, acrPushRoleId)
  scope: containerRegistry
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: acrPushRoleId
    principalType: 'User'
  }
}

resource storageBlobAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, deployerPrincipalId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: deployerPrincipalId
    roleDefinitionId: storageBlobDataContributorRoleId
    principalType: 'User'
  }
}
