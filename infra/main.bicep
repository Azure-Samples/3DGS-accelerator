targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment (used for resource naming).')
param environmentName string

@description('Primary location for all resources.')
param location string

@description('Whether to enable GPU workload profile for the Container Apps Job.')
param useGpu bool = false

@description('GPU workload profile type.')
@allowed(['Consumption-GPU-NC8as-T4', 'Consumption-GPU-NC24-A100'])
param gpuProfileType string = 'Consumption-GPU-NC8as-T4'

@description('Whether to use storage account keys instead of RBAC for blob access.')
param useStorageKeys bool = false

@description('3DGS processing backend.')
@allowed(['mock', 'gsplat', 'gaussian-splatting'])
param processorBackend string = 'gsplat'

@description('Whether to include RBAC role assignments in this deployment.')
param includeRbac bool = true

@description('Principal ID of the deployer (auto-set by preprovision hook).')
param deployerPrincipalId string = ''

@description('Extra tags for the storage account (e.g., security controls).')
param storageExtraTags object = {}

// ── Naming ──────────────────────────────────────────────────────────────────
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

// ── Resource Group ──────────────────────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: '${abbrs.resourceGroup}${environmentName}'
  location: location
  tags: tags
}

// ── Managed Identity ────────────────────────────────────────────────────────
module managedIdentity 'modules/managed-identity.bicep' = {
  name: 'managed-identity'
  scope: rg
  params: {
    name: '${abbrs.managedIdentity}-${resourceToken}'
    location: location
    tags: tags
  }
}

// ── Monitoring ──────────────────────────────────────────────────────────────
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    name: '${abbrs.operationalInsightsWorkspace}-${resourceToken}'
    location: location
    tags: tags
  }
}

// ── Container Registry ──────────────────────────────────────────────────────
module acr 'modules/acr.bicep' = {
  name: 'acr'
  scope: rg
  params: {
    name: '${abbrs.containerRegistry}${resourceToken}'
    location: location
    tags: tags
  }
}

// ── Storage Account ─────────────────────────────────────────────────────────
module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    name: '${abbrs.storageAccount}${resourceToken}'
    location: location
    tags: union(tags, storageExtraTags)
    allowSharedKeyAccess: useStorageKeys
  }
}

// ── Container Apps Environment ──────────────────────────────────────────────
module containerAppsEnv 'modules/container-apps-env.bicep' = {
  name: 'container-apps-env'
  scope: rg
  params: {
    name: '${abbrs.appContainerAppsEnvironment}-${resourceToken}'
    location: location
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.id
    useGpu: useGpu
    gpuProfileType: gpuProfileType
  }
}

// ── RBAC: AcrPull for Managed Identity (conditional) ────────────────────────
module acrPullRole 'modules/acr-pull-role.bicep' = if (includeRbac) {
  name: 'acr-pull-role'
  scope: rg
  params: {
    containerRegistryName: acr.outputs.name
    managedIdentityPrincipalId: managedIdentity.outputs.principalId
  }
}

// ── RBAC: Storage Blob Data Contributor for Managed Identity (conditional) ──
module storageBlobRole 'modules/storage-blob-role.bicep' = if (includeRbac) {
  name: 'storage-blob-role'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    managedIdentityPrincipalId: managedIdentity.outputs.principalId
  }
}

// ── RBAC: Deployer roles (conditional) ──────────────────────────────────────
module deployerRoles 'modules/deployer-roles.bicep' = if (!empty(deployerPrincipalId)) {
  name: 'deployer-roles'
  scope: rg
  params: {
    containerRegistryName: acr.outputs.name
    storageAccountName: storage.outputs.name
    deployerPrincipalId: deployerPrincipalId
  }
}

// ── Container Apps Job ──────────────────────────────────────────────────────
module job 'modules/container-apps-job.bicep' = {
  name: 'container-apps-job'
  scope: rg
  params: {
    name: '${abbrs.appJobs}-${resourceToken}'
    location: location
    tags: tags
    environmentName: environmentName
    containerAppsEnvironmentId: containerAppsEnv.outputs.id
    containerRegistryLoginServer: acr.outputs.loginServer
    managedIdentityId: managedIdentity.outputs.resourceId
    managedIdentityClientId: managedIdentity.outputs.clientId
    storageAccountName: storage.outputs.name
    useGpu: useGpu
    gpuProfileName: useGpu ? containerAppsEnv.outputs.gpuProfileName : 'Consumption'
    useStorageKeys: useStorageKeys
    storageConnectionString: useStorageKeys ? storage.outputs.connectionString : ''
    processorBackend: processorBackend
  }
}

// ── Outputs (saved to azd env) ──────────────────────────────────────────────
output AZURE_CONTAINER_REGISTRY_NAME string = acr.outputs.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = acr.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_ID string = acr.outputs.id
output AZURE_CONTAINER_ENVIRONMENT_NAME string = containerAppsEnv.outputs.name
output AZURE_STORAGE_ACCOUNT_NAME string = storage.outputs.name
output AZURE_STORAGE_ACCOUNT_ID string = storage.outputs.id
output MANAGED_IDENTITY_NAME string = managedIdentity.outputs.name
output MANAGED_IDENTITY_PRINCIPAL_ID string = managedIdentity.outputs.principalId
output MANAGED_IDENTITY_CLIENT_ID string = managedIdentity.outputs.clientId
output MANAGED_IDENTITY_RESOURCE_ID string = managedIdentity.outputs.resourceId
output JOB_NAME string = job.outputs.name
output AZURE_RESOURCE_GROUP string = rg.name
