@description('Name of the existing Log Analytics workspace.')
param name string

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: name
}

@description('The resource ID of the Log Analytics workspace.')
output id string = logAnalytics.id

@description('The name of the Log Analytics workspace.')
output name string = logAnalytics.name
