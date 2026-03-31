@description('Name of the existing Azure Container Registry.')
param name string

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = {
  name: name
}

@description('The name of the Container Registry.')
output name string = containerRegistry.name

@description('The login server of the Container Registry.')
output loginServer string = containerRegistry.properties.loginServer

@description('The resource ID of the Container Registry.')
output id string = containerRegistry.id
