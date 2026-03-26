@description('Name of the Container Apps Job.')
param name string

@description('Azure region for the resource.')
param location string = resourceGroup().location

@description('Tags for the resource.')
param tags object = {}

@description('The azd environment name.')
param environmentName string

@description('Resource ID of the Container Apps Environment.')
param containerAppsEnvironmentId string

@description('Login server of the Container Registry.')
param containerRegistryLoginServer string

@description('Resource ID of the User-Assigned Managed Identity.')
param managedIdentityId string

@description('Client ID of the User-Assigned Managed Identity.')
param managedIdentityClientId string

@description('Name of the Storage Account.')
param storageAccountName string

@description('Container image name (set by acr-build hook or azd deploy).')
param imageName string = ''

@description('Whether to use a GPU workload profile.')
param useGpu bool = false

@description('GPU workload profile name (from Container Apps Environment).')
param gpuProfileName string = 'Consumption-GPU-NC8as-T4'

@description('Whether to use storage account keys instead of RBAC.')
param useStorageKeys bool = false

@description('Storage account connection string (only used when useStorageKeys is true).')
@secure()
param storageConnectionString string = ''

@description('3DGS processing backend (mock, gsplat, gaussian-splatting).')
param processorBackend string = 'gsplat'

var effectiveImage = !empty(imageName)
  ? imageName
  : 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

// The processor runs in batch mode: download from blob → process → upload → exit
var baseEnv = [
  { name: 'RUN_MODE', value: 'batch' }
  { name: 'BACKEND', value: processorBackend }
  { name: 'INPUT_PATH', value: '/data/input' }
  { name: 'OUTPUT_PATH', value: '/data/output' }
  { name: 'PROCESSED_PATH', value: '/data/processed' }
  { name: 'ERROR_PATH', value: '/data/error' }
  { name: 'TEMP_PATH', value: '/tmp/3dgs-work' }
  { name: 'AZURE_STORAGE_ACCOUNT', value: storageAccountName }
  { name: 'AZURE_USE_MANAGED_IDENTITY', value: 'true' }
  { name: 'AZURE_CLIENT_ID', value: managedIdentityClientId }
  { name: 'AZURE_BLOB_CONTAINER_INPUT', value: 'input' }
  { name: 'AZURE_BLOB_CONTAINER_OUTPUT', value: 'output' }
  { name: 'AZURE_BLOB_CONTAINER_PROCESSED', value: 'processed' }
  { name: 'AZURE_BLOB_CONTAINER_ERROR', value: 'error' }
  { name: 'BATCH_INPUT_PREFIX', value: 'south_building/' }
  { name: 'LOG_LEVEL', value: 'info' }
  { name: 'MAX_RETRIES', value: '1' }
  { name: 'RECONSTRUCTION_BACKEND', value: 'colmap' }
  { name: 'COLMAP_MATCHER', value: 'sequential' }
  { name: 'COLMAP_MAX_NUM_FEATURES', value: '2048' }
  { name: 'FRAME_RATE', value: '2' }
  { name: 'MIN_VIDEO_FRAMES', value: '5' }
  { name: 'MIN_VIDEO_DURATION', value: '0.5' }
  { name: 'MIN_RECONSTRUCTION_POINTS', value: '100' }
]

var keyEnv = useStorageKeys
  ? [
      {
        name: 'AZURE_STORAGE_CONNECTION_STRING'
        secretRef: 'storage-connection-string'
      }
    ]
  : []

var secrets = useStorageKeys
  ? [
      {
        name: 'storage-connection-string'
        value: storageConnectionString
      }
    ]
  : []

resource job 'Microsoft.App/jobs@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, {
    'azd-env-name': environmentName
    'azd-service-name': 'job'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    environmentId: containerAppsEnvironmentId
    workloadProfileName: useGpu ? gpuProfileName : 'Consumption'
    configuration: {
      replicaTimeout: 7200
      replicaRetryLimit: 1
      triggerType: 'Manual'
      secrets: secrets
      registries: [
        {
          server: containerRegistryLoginServer
          identity: managedIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          image: effectiveImage
          name: 'main'
          resources: useGpu
            ? {
                cpu: json('8')
                memory: '56Gi'
              }
            : {
                cpu: json('2')
                memory: '4Gi'
              }
          env: concat(baseEnv, keyEnv)
        }
      ]
    }
  }
}

@description('The name of the Container Apps Job.')
output name string = job.name

@description('The resource ID of the Container Apps Job.')
output id string = job.id
