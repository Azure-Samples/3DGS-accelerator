@description('Name of the existing Container Apps Environment.')
param name string

@description('Whether a GPU workload profile is expected on this environment.')
param useGpu bool = false

@description('GPU workload profile type (must already be configured on the existing environment).')
@allowed(['Consumption-GPU-NC8as-T4', 'Consumption-GPU-NC24-A100'])
param gpuProfileType string = 'Consumption-GPU-NC8as-T4'

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: name
}

@description('The resource ID of the Container Apps Environment.')
output id string = containerAppsEnvironment.id

@description('The name of the Container Apps Environment.')
output name string = containerAppsEnvironment.name

@description('The default domain of the Container Apps Environment.')
output defaultDomain string = containerAppsEnvironment.properties.defaultDomain

@description('The GPU workload profile name (if GPU enabled).')
output gpuProfileName string = useGpu ? gpuProfileType : ''
