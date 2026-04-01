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

// ── Existing Resource Parameters ────────────────────────────────────────────
// Set via: ./scripts/configure-existing-resources.sh
// When a name is provided the resource is referenced with the Bicep `existing`
// keyword — its lifecycle is NOT managed by this deployment.
// Existing resources may live in a separate resource group from the one azd
// manages. Set existingResourceGroupName to point at that RG.

@description('Resource group that contains the existing resources to reuse. May differ from the azd-managed resource group. If empty, existing resources are assumed to be in the azd-managed resource group.')
param existingResourceGroupName string = ''

@description('Name of an existing Azure Container Registry to reuse. If empty, a new one is created.')
param existingAcrName string = ''

@description('Name of an existing Storage Account to reuse. If empty, a new one is created.')
param existingStorageAccountName string = ''

@description('Name of an existing Container Apps Environment to reuse. If empty, a new one is created.')
param existingContainerAppsEnvName string = ''

@description('Name of an existing Log Analytics workspace to reuse. If empty, a new one is created — unless an existing Container Apps Environment is also provided, in which case monitoring is skipped entirely.')
param existingLogAnalyticsName string = ''

// ── Naming & Computed Variables ─────────────────────────────────────────────
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }

var useExistingAcr = !empty(existingAcrName)
var useExistingStorage = !empty(existingStorageAccountName)
var useExistingEnv = !empty(existingContainerAppsEnvName)
var useExistingMonitoring = !empty(existingLogAnalyticsName)

// azd always manages its own RG for ephemeral resources (MI, Job).
// Existing resources may live in a different RG.
var rgName = '${abbrs.resourceGroup}${environmentName}'
var existingRgName = !empty(existingResourceGroupName) ? existingResourceGroupName : rgName

// ── Resource Group ──────────────────────────────────────────────────────────
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: tags
}

// ── Managed Identity ────────────────────────────────────────────────────────
module managedIdentity 'modules/managed-identity.bicep' = {
  name: 'managed-identity'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    name: '${abbrs.managedIdentity}-${resourceToken}'
    location: location
    tags: tags
  }
}

// ── Monitoring ──────────────────────────────────────────────────────────────
// Created only when deploying a new Container Apps Environment AND no existing
// Log Analytics workspace is provided.
module monitoring 'modules/monitoring.bicep' = if (!useExistingEnv && !useExistingMonitoring) {
  name: 'monitoring'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    name: '${abbrs.operationalInsightsWorkspace}-${resourceToken}'
    location: location
    tags: tags
  }
}

module existingMonitoringRef 'modules/existing-monitoring.bicep' = if (useExistingMonitoring) {
  name: 'existing-monitoring'
  scope: resourceGroup(existingRgName)
  params: {
    name: existingLogAnalyticsName
  }
}

// ── Container Registry ──────────────────────────────────────────────────────
module acr 'modules/acr.bicep' = if (!useExistingAcr) {
  name: 'acr'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    name: '${abbrs.containerRegistry}${resourceToken}'
    location: location
    tags: tags
  }
}

module existingAcrRef 'modules/existing-acr.bicep' = if (useExistingAcr) {
  name: 'existing-acr'
  scope: resourceGroup(existingRgName)
  params: {
    name: existingAcrName
  }
}

// ── Storage Account ─────────────────────────────────────────────────────────
module storage 'modules/storage.bicep' = if (!useExistingStorage) {
  name: 'storage'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    name: '${abbrs.storageAccount}${resourceToken}'
    location: location
    tags: union(tags, storageExtraTags)
    allowSharedKeyAccess: useStorageKeys
  }
}

module existingStorageRef 'modules/existing-storage.bicep' = if (useExistingStorage) {
  name: 'existing-storage'
  scope: resourceGroup(existingRgName)
  params: {
    name: existingStorageAccountName
    allowSharedKeyAccess: useStorageKeys
  }
}

// ── Container Apps Environment ──────────────────────────────────────────────
module containerAppsEnv 'modules/container-apps-env.bicep' = if (!useExistingEnv) {
  name: 'container-apps-env'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    name: '${abbrs.appContainerAppsEnvironment}-${resourceToken}'
    location: location
    tags: tags
    logAnalyticsWorkspaceId: useExistingMonitoring ? existingMonitoringRef.outputs.id : monitoring.outputs.id
    useGpu: useGpu
    gpuProfileType: gpuProfileType
  }
}

module existingEnvRef 'modules/existing-container-apps-env.bicep' = if (useExistingEnv) {
  name: 'existing-container-apps-env'
  scope: resourceGroup(existingRgName)
  params: {
    name: existingContainerAppsEnvName
    useGpu: useGpu
    gpuProfileType: gpuProfileType
  }
}

// ── RBAC: AcrPull for Managed Identity (conditional) ────────────────────────
module acrPullRole 'modules/acr-pull-role.bicep' = if (includeRbac) {
  name: 'acr-pull-role'
  scope: resourceGroup(useExistingAcr ? existingRgName : rgName)
  dependsOn: [rg]
  params: {
    containerRegistryName: useExistingAcr ? existingAcrRef.outputs.name : acr.outputs.name
    managedIdentityPrincipalId: managedIdentity.outputs.principalId
  }
}

// ── RBAC: Storage Blob Data Contributor for Managed Identity (conditional) ──
module storageBlobRole 'modules/storage-blob-role.bicep' = if (includeRbac) {
  name: 'storage-blob-role'
  scope: resourceGroup(useExistingStorage ? existingRgName : rgName)
  dependsOn: [rg]
  params: {
    storageAccountName: useExistingStorage ? existingStorageRef.outputs.name : storage.outputs.name
    managedIdentityPrincipalId: managedIdentity.outputs.principalId
  }
}

// ── RBAC: Deployer roles (conditional) ──────────────────────────────────────
// Skipped when existing resources are in a separate RG — the deployer-roles
// module references both ACR and Storage by name and they must be in the same
// scope. Use ./infra/scripts/assign-rbac.sh manually in that case.
var canDeployDeployerRoles = !empty(deployerPrincipalId) && (existingRgName == rgName)
module deployerRoles 'modules/deployer-roles.bicep' = if (canDeployDeployerRoles) {
  name: 'deployer-roles'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    containerRegistryName: useExistingAcr ? existingAcrRef.outputs.name : acr.outputs.name
    storageAccountName: useExistingStorage ? existingStorageRef.outputs.name : storage.outputs.name
    deployerPrincipalId: deployerPrincipalId
  }
}

// ── Container Apps Job ──────────────────────────────────────────────────────
// Always created and managed by this deployment.
module job 'modules/container-apps-job.bicep' = {
  name: 'container-apps-job'
  scope: resourceGroup(rgName)
  dependsOn: [rg]
  params: {
    name: '${abbrs.appJobs}-${resourceToken}'
    location: location
    tags: tags
    environmentName: environmentName
    containerAppsEnvironmentId: useExistingEnv ? existingEnvRef.outputs.id : containerAppsEnv.outputs.id
    containerRegistryLoginServer: useExistingAcr ? existingAcrRef.outputs.loginServer : acr.outputs.loginServer
    managedIdentityId: managedIdentity.outputs.resourceId
    managedIdentityClientId: managedIdentity.outputs.clientId
    storageAccountName: useExistingStorage ? existingStorageRef.outputs.name : storage.outputs.name
    useGpu: useGpu
    gpuProfileName: useGpu
      ? (useExistingEnv ? existingEnvRef.outputs.gpuProfileName : containerAppsEnv.outputs.gpuProfileName)
      : 'Consumption'
    useStorageKeys: useStorageKeys
    storageConnectionString: useStorageKeys
      ? (useExistingStorage ? existingStorageRef.outputs.connectionString : storage.outputs.connectionString)
      : ''
    processorBackend: processorBackend
  }
}

// ── Outputs (saved to azd env) ──────────────────────────────────────────────
output AZURE_CONTAINER_REGISTRY_NAME string = useExistingAcr ? existingAcrRef.outputs.name : acr.outputs.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = useExistingAcr ? existingAcrRef.outputs.loginServer : acr.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_ID string = useExistingAcr ? existingAcrRef.outputs.id : acr.outputs.id
output AZURE_CONTAINER_ENVIRONMENT_NAME string = useExistingEnv ? existingEnvRef.outputs.name : containerAppsEnv.outputs.name
output AZURE_STORAGE_ACCOUNT_NAME string = useExistingStorage ? existingStorageRef.outputs.name : storage.outputs.name
output AZURE_STORAGE_ACCOUNT_ID string = useExistingStorage ? existingStorageRef.outputs.id : storage.outputs.id
output MANAGED_IDENTITY_NAME string = managedIdentity.outputs.name
output MANAGED_IDENTITY_PRINCIPAL_ID string = managedIdentity.outputs.principalId
output MANAGED_IDENTITY_CLIENT_ID string = managedIdentity.outputs.clientId
output MANAGED_IDENTITY_RESOURCE_ID string = managedIdentity.outputs.resourceId
output JOB_NAME string = job.outputs.name
output AZURE_RESOURCE_GROUP string = rgName
