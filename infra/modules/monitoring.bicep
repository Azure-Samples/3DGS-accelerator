@description('Name of the Log Analytics workspace.')
param name string

@description('Azure region for the resource.')
param location string = resourceGroup().location

@description('Tags for the resource.')
param tags object = {}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

@description('The resource ID of the Log Analytics workspace.')
output id string = logAnalytics.id

@description('The name of the Log Analytics workspace.')
output name string = logAnalytics.name
