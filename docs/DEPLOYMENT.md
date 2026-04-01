# Deployment Guide: 3DGS Video Processor

Production deployment patterns and operational best practices.

## Table of Contents

* [Container Deployment](#container-deployment)
* [Azure Container Apps Job (GPU) — azd](#azure-container-apps-job-gpu--azd)
  * [Reusing Existing Azure Resources](#reusing-existing-azure-resources)
  * [Full Quickstart and Teardown](#full-quickstart-and-teardown)
* [Batch Mode (Azure SDK)](#batch-mode-azure-sdk)
* [Resource Requirements](#resource-requirements)
* [Storage Configuration](#storage-configuration)
* [Azure Blob Storage Setup](#azure-blob-storage-setup)
* [Security Hardening](#security-hardening)
* [Monitoring and Logging](#monitoring-and-logging)

## Container Deployment

### Docker Compose (Recommended for Single Server)

Create `docker-compose.yml`:

```yaml
version: '3.8'

services:
  3dgs-processor:
    image: 3dgs-processor:gpu
    container_name: 3dgs-processor
    restart: unless-stopped
    
    # Resource limits
    deploy:
      resources:
        limits:
          cpus: '8'
          memory: 16G
        reservations:
          cpus: '4'
          memory: 8G
    
    # Volume mounts
    volumes:
      - ./input:/data/input
      - ./output:/data/output
      - ./processed:/data/processed
      - ./error:/data/error
      - ./config.yaml:/app/config.yaml:ro
    
    # Environment configuration
    environment:
      INPUT_PATH: /data/input
      OUTPUT_PATH: /data/output
      PROCESSED_PATH: /data/processed
      ERROR_PATH: /data/error
      BACKEND: gsplat
      LOG_LEVEL: info
      STABILITY_TIMEOUT_SECS: 30
      MAX_RETRIES: 3
      RETENTION_DAYS: 30
      MIN_DISK_SPACE_GB: 50
    
    # Logging configuration
    logging:
      driver: json-file
      options:
        max-size: "100m"
        max-file: "5"
    
    # Health check
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

Deploy:

```bash
docker-compose up -d
docker-compose logs -f 3dgs-processor
```

### Kubernetes Deployment

Create `k8s/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: 3dgs-processor
  namespace: 3dgs
spec:
  replicas: 1  # Single instance (sequential processing)
  selector:
    matchLabels:
      app: 3dgs-processor
  template:
    metadata:
      labels:
        app: 3dgs-processor
    spec:
      containers:
      - name: processor
        image: 3dgs-processor:gpu
        imagePullPolicy: Always
        
        resources:
          requests:
            cpu: "4"
            memory: "8Gi"
          limits:
            cpu: "8"
            memory: "16Gi"
        
        env:
        - name: INPUT_PATH
          value: "/data/input"
        - name: OUTPUT_PATH
          value: "/data/output"
        - name: PROCESSED_PATH
          value: "/data/processed"
        - name: ERROR_PATH
          value: "/data/error"
        - name: BACKEND
          valueFrom:
            configMapKeyRef:
              name: 3dgs-config
              key: backend
        
        volumeMounts:
        - name: data
          mountPath: /data
        - name: config
          mountPath: /app/config.yaml
          subPath: config.yaml
          readOnly: true
        
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 30
        
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
      
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: 3dgs-pvc
      - name: config
        configMap:
          name: 3dgs-config
```

Create `k8s/pvc.yaml` for persistent storage:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: 3dgs-pvc
  namespace: 3dgs
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd
  resources:
    requests:
      storage: 500Gi
```

Deploy:

```bash
kubectl create namespace 3dgs
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/deployment.yaml
kubectl logs -f deployment/3dgs-processor -n 3dgs
```

### Azure Container Instances

Deploy serverless containers with Azure Files or Blobfuse2:

**Option 1: Using Azure Files (Simpler)**

```bash
# Set variables
RESOURCE_GROUP="<your-resource-group>"
LOCATION="eastus"
CONTAINER_NAME="3dgs-processor"
IMAGE="youracr.azurecr.io/3dgs-processor:gpu"
STORAGE_ACCOUNT="<your-storage-account>"
STORAGE_KEY="<your-storage-key>"

# Create container with Azure Files mount
az container create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --image $IMAGE \
  --cpu 8 \
  --memory 16 \
  --os-type Linux \
  --restart-policy Always \
  --environment-variables \
    INPUT_PATH=/data/input \
    OUTPUT_PATH=/data/output \
    PROCESSED_PATH=/data/processed \
    ERROR_PATH=/data/error \
    BACKEND=gsplat \
    LOG_LEVEL=info \
  --azure-file-volume-account-name $STORAGE_ACCOUNT \
  --azure-file-volume-account-key "$STORAGE_KEY" \
  --azure-file-volume-share-name input \
  --azure-file-volume-mount-path /data/input
```

**Option 2: Using Managed Identity with Azure Blob Storage**

Create `aci-deployment.yaml`:

```yaml
apiVersion: '2021-09-01'
location: eastus
name: 3dgs-processor-group
properties:
  containers:
  - name: 3dgs-processor
    properties:
      image: youracr.azurecr.io/3dgs-processor:gpu
      resources:
        requests:
          cpu: 8
          memoryInGB: 16
      environmentVariables:
      - name: INPUT_PATH
        value: /data/input
      - name: OUTPUT_PATH
        value: /data/output
      - name: PROCESSED_PATH
        value: /data/processed
      - name: ERROR_PATH
        value: /data/error
      - name: BACKEND
        value: gsplat
      - name: AZURE_STORAGE_ACCOUNT
        value: <your-storage-account>
      volumeMounts:
      - name: input-volume
        mountPath: /data/input
      - name: output-volume
        mountPath: /data/output
  
  volumes:
  - name: input-volume
    azureFile:
      shareName: input
      storageAccountName: <your-storage-account>
      storageAccountKey: <key>
  - name: output-volume
    azureFile:
      shareName: output
      storageAccountName: <your-storage-account>
      storageAccountKey: <key>
  
  osType: Linux
  restartPolicy: Always
  
  identity:
    type: SystemAssigned
type: Microsoft.ContainerInstance/containerGroups
```

Deploy:

```bash
az container create --resource-group $RESOURCE_GROUP --file aci-deployment.yaml
```

**Monitor ACI deployment**:

```bash
# View logs
az container logs --resource-group $RESOURCE_GROUP --name $CONTAINER_NAME --follow

# Check status
az container show --resource-group $RESOURCE_GROUP --name $CONTAINER_NAME --query instanceView.state

# Execute commands inside container
az container exec --resource-group $RESOURCE_GROUP --name $CONTAINER_NAME --exec-command "/bin/sh"

# Delete when done
az container delete --resource-group $RESOURCE_GROUP --name $CONTAINER_NAME
```

**Cost Optimization**:

- Use **Azure Container Instances** for variable workloads (pay per second)
- Use **AKS** for consistent high-volume processing
- Set `--restart-policy OnFailure` for one-time jobs
- Use spot instances for non-critical workloads

---

## Azure Container Apps Job (GPU) — azd

Deploy the 3DGS processor as a **serverless GPU job** on Azure Container Apps using the
Azure Developer CLI (`azd`). The job runs in batch mode: download videos from Azure Blob
Storage → extract frames → COLMAP reconstruction → gsplat GPU training → export PLY/SPLAT
→ upload results → exit.

**Key characteristics:**
- **Serverless GPU** — NVIDIA T4 (16 GB VRAM) via `Consumption-GPU-NC8as-T4` workload profile
- **No local Docker required** — images are built remotely via ACR Tasks
- **Batch mode** — single job execution, no long-running container
- **Managed Identity** — user-assigned MI for RBAC-based access to ACR and Storage
- **RBAC separation** — infrastructure provisioning and role assignments are separate steps
- **Existing resource preservation** — optionally reuse pre-existing Resource Groups, ACR,
  Storage Accounts, and Container Apps Environments. These resources are referenced via
  Bicep's `existing` keyword and are **not** deleted by `azd down`

### Prerequisites

| Requirement | Purpose |
|-------------|---------|
| [Azure CLI](https://aka.ms/installazurecli) (`az`) | Azure resource management |
| [Azure Developer CLI](https://aka.ms/install-azd) (`azd`) | Infrastructure-as-code orchestration |
| Azure subscription | With GPU quota in your target region |
| Test data | Download via `./scripts/e2e/01-download-testdata.sh` |

**No local Docker daemon is needed.** The GPU image is built remotely on Azure Container
Registry Tasks.

### Quick Start

```bash
# 1. Initialize the azd environment
azd init

# 2. Configure environment
azd env set AZURE_LOCATION swedencentral
azd env set USE_GPU true

# 3. (Optional) Reuse existing Azure resources instead of creating new ones
#    See "Reusing Existing Azure Resources" below for details.
./scripts/configure-existing-resources.sh

# 4. Provision infrastructure (also builds the GPU image on ACR — ~40 min)
azd provision

# 5. (Privileged user) Assign RBAC roles to the Managed Identity
./infra/scripts/assign-rbac.sh

# 6. Verify RBAC assignments
./infra/scripts/verify-rbac.sh

# 7. Upload test data to Azure Blob Storage
./infra/scripts/upload-testdata.sh

# 8. Run the GPU job
./infra/scripts/run-job.sh --logs
```

### What Gets Provisioned

`azd provision` creates the following Azure resources (all in a single resource group).
If you have configured existing resources via `./scripts/configure-existing-resources.sh`,
those resources are **referenced** (Bicep `existing` keyword) rather than created — their
lifecycle is not managed by this deployment, and `azd down` will not delete them.

| Resource | Bicep Module | Purpose | Can Reuse Existing? |
|----------|-------------|---------|---------------------|
| Resource Group | `main.bicep` | `rg-<env-name>` | ✅ Yes |
| User-Assigned Managed Identity | `modules/managed-identity.bicep` | Authenticate to ACR and Storage | No (always created) |
| Azure Container Registry (Basic) | `modules/acr.bicep` | Store GPU Docker images | ✅ Yes |
| Storage Account + 4 containers | `modules/storage.bicep` | `input`, `output`, `processed`, `error` | ✅ Yes |
| Log Analytics Workspace | `modules/monitoring.bicep` | Container log aggregation | No (skipped when reusing env) |
| Container Apps Environment | `modules/container-apps-env.bicep` | GPU workload profile (T4) | ✅ Yes |
| Container Apps Job (Manual trigger) | `modules/container-apps-job.bicep` | The processor job itself | No (always created) |

After provisioning, the `postprovision` hook automatically:
1. Builds the GPU Docker image via ACR Tasks (`infra/scripts/hooks/acr-build.sh`)
2. Updates the Container Apps Job with the new image

### RBAC Requirements — Read This Carefully

RBAC role assignments are **intentionally separated** from infrastructure provisioning.
This is because in many organizations, the person deploying infrastructure does not have
permission to assign IAM roles. The two operations may require different privilege levels.

#### Permissions Required by the Deployer (the person running `azd provision`)

The deployer needs these permissions **on the Azure subscription or resource group**:

| Permission | Why |
|------------|-----|
| `Microsoft.Resources/subscriptions/resourceGroups/write` | Create the resource group |
| `Microsoft.ContainerRegistry/registries/*` | Create ACR and push images |
| `Microsoft.Storage/storageAccounts/*` | Create storage account and containers |
| `Microsoft.App/managedEnvironments/*` | Create Container Apps Environment |
| `Microsoft.App/jobs/*` | Create Container Apps Job |
| `Microsoft.ManagedIdentity/userAssignedIdentities/*` | Create managed identity |
| `Microsoft.OperationalInsights/workspaces/*` | Create Log Analytics workspace |

Typically the **Contributor** built-in role on the subscription is sufficient.

The `preprovision` hook (`infra/scripts/hooks/preprovision.sh`) also attempts to assign
deployer-level RBAC (AcrPush, Storage Blob Data Contributor) so the deployer can push
images and upload test data. This requires the deployer to have **User Access Administrator**
or **Owner** on the resource group. If the deployer lacks this permission, the hook
continues (it's non-blocking) — a privileged user can assign these roles later.

#### Permissions Required for the Managed Identity (assigned after provisioning)

The Managed Identity needs two role assignments so the container job can pull images
and read/write blobs at runtime:

| Role | Scope | Role Definition ID | Purpose |
|------|-------|-------------------|---------|
| **AcrPull** | Container Registry | `7f951dda-4ed3-4680-a7ca-43fe172d538d` | Pull GPU image from ACR |
| **Storage Blob Data Contributor** | Storage Account | `ba92f5b4-2d11-453d-a403-e96b0029c9fe` | Download input videos, upload outputs, move blobs |

#### Who Can Assign These Roles?

A user with **one** of these roles on the target scope:
- **Owner** (full control, including RBAC)
- **User Access Administrator** (RBAC management only)
- A custom role with `Microsoft.Authorization/roleAssignments/write` permission

> **If the deployer does not have these permissions**, the `azd provision` step will
> succeed but the job will fail at runtime with authentication errors (HTTP 403 on
> Storage or image pull failures on ACR). Have a privileged user run the RBAC scripts.

#### Assigning RBAC Roles

```bash
# Assign roles via Azure CLI (reads values from azd env automatically)
./infra/scripts/assign-rbac.sh

# Or assign via Bicep deployment (alternative)
./infra/scripts/assign-rbac.sh --use-bicep
```

#### Verifying RBAC Roles

```bash
# Check that both roles are assigned
./infra/scripts/verify-rbac.sh
```

Expected output when roles are correctly assigned:
```
🔍 Verifying RBAC role assignments for Managed Identity...
   Principal ID: <managed-identity-principal-id>

  ✅ AcrPull on Container Registry
  ✅ Storage Blob Data Contributor on Storage Account

✅ All RBAC role assignments are in place.
```

If any roles are missing:
```
  ❌ AcrPull on Container Registry — MISSING

⚠️  1 RBAC role assignment(s) missing.
   Run './infra/scripts/assign-rbac.sh' as a privileged user to fix.
```

#### What Fails Without RBAC

| Missing Role | Symptom |
|--------------|---------|
| **AcrPull** | Job execution fails immediately — Container Apps cannot pull the image. The execution shows `Failed` status with no container logs (image never starts). |
| **Storage Blob Data Contributor** | Container starts but fails with `Failed to download input blobs from Azure Blob Storage` — the managed identity token is rejected with HTTP 403. |

### Uploading Test Data

The South Building dataset (128 multi-view images from UNC Chapel Hill) is used for testing.
The upload script downloads it if needed, creates 3 test videos, and uploads them:

```bash
# Download test data + upload to blob storage (default prefix: south_building/)
./infra/scripts/upload-testdata.sh

# Custom blob prefix
./infra/scripts/upload-testdata.sh --prefix my_scene/

# Download only (no upload)
./infra/scripts/upload-testdata.sh --download-only
```

### Running the Job

```bash
# Start job and return immediately
./infra/scripts/run-job.sh

# Start job, wait for completion, show status
./infra/scripts/run-job.sh --wait

# Start job, wait, then show container logs
./infra/scripts/run-job.sh --logs
```

A successful run produces these outputs in the `output` blob container:

| File | Description | Typical Size |
|------|-------------|-------------|
| `south_building/south_building.ply` | 3D Gaussian point cloud (real GPU-trained geometry) | ~65 KB |
| `south_building/south_building.splat` | Web-optimized format for real-time rendering | ~53 KB |
| `south_building/manifest.json` | Video metadata (resolution, duration, codec, frame count) | ~7 KB |
| `south_building/.checkpoint.json` | Pipeline progress tracking | ~11 KB |

Input videos are moved from `input/` to `processed/` on success, or `error/` on failure.

### Redeploying Code Changes

After modifying the processor code, rebuild and redeploy without re-provisioning:

```bash
# Build new image on ACR + update the job
./infra/scripts/deploy-job.sh

# Or skip the build and just redeploy the existing image
./infra/scripts/deploy-job.sh --skip-build
```

### Configuration Variables

Set these via `azd env set <NAME> <VALUE>` before provisioning:

| Variable | Default | Description |
|----------|---------|-------------|
| `AZURE_LOCATION` | *(required)* | Azure region. Must support GPU T4 (e.g., `swedencentral`, `eastus`, `westus`) |
| `USE_GPU` | `true` | Enable GPU workload profile |
| `GPU_PROFILE_TYPE` | `Consumption-GPU-NC8as-T4` | GPU type (`Consumption-GPU-NC8as-T4` or `Consumption-GPU-NC24-A100`) |
| `PROCESSOR_BACKEND` | `gsplat` | 3DGS backend (`gsplat`, `gaussian-splatting`, `mock`) |
| `INCLUDE_RBAC` | `true` | Include RBAC assignments in Bicep deployment |
| `USE_STORAGE_KEYS` | `false` | Use storage account keys instead of RBAC (fallback) |
| `EXISTING_RESOURCE_GROUP` | *(empty)* | Name of an existing Resource Group to deploy into (see [Reusing Existing Resources](#reusing-existing-azure-resources)) |
| `EXISTING_ACR_NAME` | *(empty)* | Name of an existing Azure Container Registry to reuse |
| `EXISTING_STORAGE_ACCOUNT_NAME` | *(empty)* | Name of an existing Storage Account to reuse |
| `EXISTING_CONTAINER_APPS_ENV_NAME` | *(empty)* | Name of an existing Container Apps Environment to reuse |
| `FORCE_DELETE` | *(empty)* | Set to `true` to allow `azd down` when existing resources are configured |

> **Tip:** Use `./scripts/configure-existing-resources.sh` to interactively set the
> `EXISTING_*` variables instead of setting them manually.

### GPU Region Availability

Serverless GPU (T4) Container Apps is available in these regions:

`swedencentral`, `eastus`, `westus`, `canadacentral`, `brazilsouth`, `australiaeast`,
`italynorth`, `francecentral`, `centralindia`, `japaneast`, `northcentralus`,
`southcentralus`, `southeastasia`, `southindia`, `westeurope`, `westus2`, `westus3`

If you get a deployment error about workload profiles, ensure your subscription has
GPU quota in the selected region. Check quota at:
[Azure Portal → Quotas](https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade)

### Cleaning Up RBAC Before Teardown

Before running `azd down`, remove the RBAC assignments:

```bash
./infra/scripts/cleanup-rbac.sh
azd down --purge --force
```

> **⚠️ Existing resource protection:** If your environment is configured to reuse existing
> Azure resources, `azd down` will be **blocked** by the `predown` hook to prevent
> accidental deletion of shared infrastructure. See
> [Reusing Existing Azure Resources](#reusing-existing-azure-resources) for details.

### Scripts Reference

All infrastructure scripts are in `infra/scripts/`:

| Script | Purpose | Requires Privilege? |
|--------|---------|-------------------|
| `hooks/preprovision.sh` | Captures deployer identity, runs RBAC preflight check | No (auto-run by azd) |
| `hooks/postprovision.sh` | Builds GPU image on ACR, updates job | No (auto-run by azd) |
| `hooks/predown.sh` | Blocks `azd down` when existing resources are configured (override with `FORCE_DELETE=true`) | No (auto-run by azd) |
| `hooks/acr-build.sh` | Creates minimal staging dir, runs `az acr build` for GPU target | No |
| `assign-rbac.sh` | Assigns AcrPull + Storage Blob Data Contributor to MI | **Yes** — Owner or User Access Admin |
| `verify-rbac.sh` | Checks if required RBAC roles are assigned | No |
| `cleanup-rbac.sh` | Removes RBAC role assignments | **Yes** — Owner or User Access Admin |
| `run-job.sh` | Starts a job execution with `--wait`/`--logs` options | No |
| `deploy-job.sh` | Rebuilds image on ACR + updates job | No |
| `upload-testdata.sh` | Downloads South Building dataset + uploads videos to blob storage | No (needs Storage Blob Data Contributor on deployer) |

Additional scripts in `scripts/`:

| Script | Purpose | Requires Privilege? |
|--------|---------|-------------------|
| `configure-existing-resources.sh` | Interactive wizard to select existing Azure resources for reuse (sets azd env vars) | No (needs Azure CLI login) |

### Troubleshooting

**"MANAGED_IDENTITY_PRINCIPAL_ID is not set"**
Run `azd provision` first — this creates the managed identity and saves its principal ID.

**Image pull failure (no container logs)**
The AcrPull role is missing. Run `./infra/scripts/assign-rbac.sh`.

**"Failed to download input blobs from Azure Blob Storage"**
Either: (a) Storage Blob Data Contributor is missing — run `./infra/scripts/assign-rbac.sh`,
or (b) no blobs exist at the `BATCH_INPUT_PREFIX` — run `./infra/scripts/upload-testdata.sh`.

**"Reconstruction quality too low"**
Increase `FRAME_RATE` (e.g., from 2 to 3) in the job env vars to extract more frames.

**ACR build timeout**
The GPU image build compiles COLMAP from source (~30 min). The default timeout is 3600s.
If it still times out, check ACR Tasks quotas.

**COLMAP matching timeout**
Ensure `COLMAP_MATCHER=sequential` (not `exhaustive`) in the job env vars.

**`azd down` blocked with "EXISTING RESOURCES DETECTED"**
The `predown` hook prevents accidental deletion of shared resources. Either reset
the existing resource configuration or explicitly opt in:
```bash
# Option 1: Remove existing resource configuration and tear down normally
./scripts/configure-existing-resources.sh --reset
azd down --purge --force

# Option 2: Force delete (will destroy the entire resource group)
azd env set FORCE_DELETE true
azd down --purge --force
```

### Reusing Existing Azure Resources

When deploying into an environment with pre-existing Azure infrastructure (e.g., a shared
resource group, a team ACR, or a storage account with data), you can configure `azd` to
**reference** those resources instead of creating new ones. Referenced resources use Bicep's
`existing` keyword — their lifecycle is **not managed** by this deployment and they are
**not deleted** by `azd down`.

#### Which Resources Can Be Reused?

| Resource | Env Variable | What Happens When Set |
|----------|-------------|----------------------|
| Resource Group | `EXISTING_RESOURCE_GROUP` | Deploy into this RG instead of creating `rg-<env-name>` |
| Azure Container Registry | `EXISTING_ACR_NAME` | Reference existing ACR; skip `modules/acr.bicep` |
| Storage Account | `EXISTING_STORAGE_ACCOUNT_NAME` | Reference existing storage; skip `modules/storage.bicep`. Required blob containers (`input`, `output`, `processed`, `error`) must already exist |
| Container Apps Environment | `EXISTING_CONTAINER_APPS_ENV_NAME` | Reference existing env; skip `modules/container-apps-env.bicep` and `modules/monitoring.bicep` (Log Analytics) |

Resources that are **always** created by the deployment, regardless of configuration:
- **Managed Identity** — a new user-assigned identity is always created
- **Container Apps Job** — the processor job itself is always created
- **RBAC role assignments** — AcrPull and Storage Blob Data Contributor (when `INCLUDE_RBAC=true`)

#### Configuring Existing Resources (Interactive)

The easiest way to configure resource reuse is the interactive wizard:

```bash
./scripts/configure-existing-resources.sh
```

The script:
1. Lists available Resource Groups in your subscription
2. Scans the selected RG for ACRs, Storage Accounts, and Container Apps Environments
3. Lets you pick which resources to reuse (or skip to create new ones)
4. Validates that required blob containers exist on a selected Storage Account
5. Sets the `EXISTING_*` environment variables in the azd environment
6. Sets `AZURE_LOCATION` to match the existing resource group's region

#### Configuring Existing Resources (Manual)

You can also set the variables directly:

```bash
azd env set EXISTING_RESOURCE_GROUP "my-shared-rg"
azd env set EXISTING_ACR_NAME "myteamacr"
azd env set EXISTING_STORAGE_ACCOUNT_NAME "mystorageaccount"
azd env set EXISTING_CONTAINER_APPS_ENV_NAME "my-cae"
```

Leave a variable empty (or omit it) to create that resource fresh.

#### Resetting to Fresh Resources

To go back to creating all resources from scratch:

```bash
./scripts/configure-existing-resources.sh --reset
```

This clears all `EXISTING_*` variables and `FORCE_DELETE` from the azd environment.

#### Teardown Protection (`predown` Hook)

When any `EXISTING_*` variable is set, `azd down` is **blocked** by the `predown` hook
(`infra/scripts/hooks/predown.sh`). This prevents accidental deletion of the resource
group (and everything inside it, including the existing shared resources).

The hook prints which existing resources are configured and exits with an error:

```
╔══════════════════════════════════════════════════════╗
║  ⚠️  EXISTING RESOURCES DETECTED                     ║
╚══════════════════════════════════════════════════════╝

This environment references pre-existing Azure resources:
   • Resource Group:             my-shared-rg
   • Storage Account:            mystorageaccount

Running 'azd down' would delete the resource group and ALL
resources inside it, including those listed above.
```

To proceed with teardown despite existing resources:

```bash
# Explicitly opt in to deletion
azd env set FORCE_DELETE true
azd down --purge --force
```

> **⚠️ Warning:** `FORCE_DELETE` deletes the **entire resource group**, including any
> existing resources you configured for reuse. Use with extreme caution.

#### How It Works (Bicep)

The `infra/main.bicep` template uses conditional deployment based on whether `EXISTING_*`
parameters are empty:

```bicep
var useExistingAcr = !empty(existingAcrName)

// New ACR — only created when not reusing
module acr 'modules/acr.bicep' = if (!useExistingAcr) { ... }

// Existing ACR — only referenced when reusing
module existingAcrRef 'modules/existing-acr.bicep' = if (useExistingAcr) { ... }

// Outputs resolve to whichever was used
output AZURE_CONTAINER_REGISTRY_NAME string = useExistingAcr
  ? existingAcrRef.outputs.name
  : acr.outputs.name
```

The same pattern applies to Storage Account, Container Apps Environment, and Resource Group.

### Full Quickstart and Teardown

Step-by-step instructions covering the complete lifecycle — from initial setup through
a successful job run to clean teardown.

#### Prerequisites

Ensure the following are installed and configured:

```bash
# Azure CLI — logged in
az login
az account show  # verify correct subscription

# Azure Developer CLI
azd version      # requires azd ≥ 1.5

# Test data (South Building dataset)
./scripts/e2e/01-download-testdata.sh
```

#### Quickstart: Fresh Deployment (New Resources)

```bash
# ── 1. Initialize ────────────────────────────────────────────────────────
azd init
# Choose an environment name (e.g., "3dgs-dev")

# ── 2. Configure ─────────────────────────────────────────────────────────
azd env set AZURE_LOCATION swedencentral    # Must support GPU T4
azd env set USE_GPU true

# ── 3. Provision infrastructure ──────────────────────────────────────────
# Creates: RG, ACR, Storage, Container Apps Env, MI, Job
# Also builds the GPU Docker image on ACR (~40 min first time)
azd provision

# ── 4. Assign RBAC roles ─────────────────────────────────────────────────
# Requires Owner or User Access Administrator on the resource group
./infra/scripts/assign-rbac.sh
./infra/scripts/verify-rbac.sh

# ── 5. Upload test data ──────────────────────────────────────────────────
./infra/scripts/upload-testdata.sh

# ── 6. Run the job ────────────────────────────────────────────────────────
./infra/scripts/run-job.sh --logs

# ── 7. Verify outputs ────────────────────────────────────────────────────
# Check the output blob container for PLY, SPLAT, manifest, checkpoint files
STORAGE_ACCOUNT=$(azd env get-value AZURE_STORAGE_ACCOUNT_NAME)
az storage blob list --account-name "$STORAGE_ACCOUNT" -c output --auth-mode login -o table
```

#### Quickstart: Deployment with Existing Resources

```bash
# ── 1. Initialize ────────────────────────────────────────────────────────
azd init

# ── 2. Configure existing resources ──────────────────────────────────────
# Interactive: select which existing resources to reuse
./scripts/configure-existing-resources.sh

# The script sets AZURE_LOCATION automatically from the resource group.
# Optionally configure additional settings:
azd env set USE_GPU true

# ── 3. Provision ─────────────────────────────────────────────────────────
# Only creates resources that aren't being reused (MI, Job, and any
# resources you chose to create fresh)
azd provision

# ── 4. Assign RBAC + upload data + run ────────────────────────────────────
./infra/scripts/assign-rbac.sh
./infra/scripts/verify-rbac.sh
./infra/scripts/upload-testdata.sh
./infra/scripts/run-job.sh --logs
```

#### Teardown: Fresh Deployment

When all resources were created by `azd`, teardown is straightforward:

```bash
# ── 1. Clean up RBAC assignments ─────────────────────────────────────────
./infra/scripts/cleanup-rbac.sh

# ── 2. Destroy all resources ─────────────────────────────────────────────
azd down --purge --force
# Deletes: Resource Group and all resources inside it
# --purge: permanently deletes soft-delete-enabled resources (Key Vault, etc.)
# --force: skip confirmation prompts
```

#### Teardown: Deployment with Existing Resources

When existing resources are configured, `azd down` is blocked to prevent accidental
deletion. You have two options:

**Option A — Remove only deployment-managed resources (recommended):**

This approach leaves existing shared resources intact and only removes what the
deployment created (Managed Identity, Container Apps Job, RBAC assignments):

```bash
# 1. Clean up RBAC assignments
./infra/scripts/cleanup-rbac.sh

# 2. Reset existing resource config so azd down only targets managed resources
./scripts/configure-existing-resources.sh --reset

# 3. Tear down
azd down --purge --force
```

> **Note:** Because `azd down` deletes the **entire resource group**, this option still
> deletes the RG and all resources in it when the RG was created by the deployment. If
> you deployed into an *existing* RG, be aware that `azd down` will attempt to delete
> that RG too. In that case, use Option B or manually delete only the managed resources.

**Option B — Force delete everything (use with caution):**

```bash
# 1. Clean up RBAC assignments
./infra/scripts/cleanup-rbac.sh

# 2. Explicitly opt in to deletion
azd env set FORCE_DELETE true

# 3. Destroy the entire resource group (including existing resources!)
azd down --purge --force
```

> **⚠️ Warning:** This deletes the entire resource group and all resources inside it,
> including any pre-existing ACR, Storage Account, or Container Apps Environment you
> configured for reuse.

---

## Batch Mode (Azure SDK)

Batch mode processes a single job using the Azure Blob Storage SDK directly — no BlobFuse2
FUSE mounts, no privileged containers, no continuous watching. The processor downloads input
videos from blob storage, runs the pipeline locally, uploads outputs, and exits.

### How It Works

```
┌─────────────────┐     ┌──────────────────────────────────┐     ┌──────────────────┐
│  Azure Blob     │     │  3DGS Processor (batch mode)     │     │  Azure Blob      │
│  input container│────>│  1. Download MP4s from blob      │     │  output container │
│  scene_001/     │     │  2. FFmpeg frame extraction       │     │                  │
│    view1.mp4    │     │  3. FFprobe metadata             │────>│  scene_001.ply   │
│    view2.mp4    │     │  4. Manifest generation          │     │  scene_001.splat  │
│    view3.mp4    │     │  5. COLMAP reconstruction        │     │  manifest.json    │
│                 │     │  6. 3DGS training                │     │                  │
│                 │     │  7. Export PLY/SPLAT              │     │                  │
└─────────────────┘     │  8. Upload outputs to blob       │     └──────────────────┘
                        │  9. Move inputs → processed/error │
                        │ 10. Exit (code 0 or 1)           │
                        └──────────────────────────────────┘
```

### Step-by-Step Setup

#### 1. Create Azure Storage Resources

```bash
# Set variables
RESOURCE_GROUP=<your-resource-group>
STORAGE_ACCOUNT=my3dgsdata    # Must be globally unique, lowercase, 3-24 chars
LOCATION=eastus

# Create resource group (skip if exists)
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create storage account
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2

# Create the four containers
for CONTAINER in input output processed error; do
  az storage container create \
    --account-name $STORAGE_ACCOUNT \
    --name $CONTAINER
done
```

#### 2. Upload Input Videos

```bash
# Upload MP4 files to the input container under a scene prefix
az storage blob upload-batch \
  --account-name $STORAGE_ACCOUNT \
  --destination input \
  --source ./my-scene-videos/ \
  --destination-path scene_001/

# Verify upload
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name input \
  --prefix scene_001/ \
  --output table
```

The input container should look like:
```
input/
  scene_001/
    view1.mp4
    view2.mp4
    view3.mp4
```

#### 3. Choose Authentication Method

See the [Authentication](#authentication) section below for details on each method.

#### 4. Run the Processor

```bash
RUN_MODE=batch \
  AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  BATCH_INPUT_PREFIX=scene_001/ \
  BACKEND=mock \
  cargo run --release
```

#### 5. Check Outputs

```bash
# List output blobs
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name output \
  --output table

# Download results
az storage blob download-batch \
  --account-name $STORAGE_ACCOUNT \
  --source output \
  --destination ./results/
```

After success, inputs are moved to the processed container:
```
processed/
  scene_001/
    view1.mp4
    view2.mp4
    view3.mp4
```

On failure, inputs are moved to the error container instead.

### Required Environment Variables

```bash
# Mode selection
RUN_MODE=batch                              # Required: enables batch mode

# Azure storage account
AZURE_STORAGE_ACCOUNT=mystorageaccount      # Required: the storage account name

# Batch job input
BATCH_INPUT_PREFIX=scene_001/               # Required: blob prefix to process
BATCH_JOB_ID=my-job-123                     # Optional: custom job ID for logging

# Processing backend
BACKEND=mock                                # Or: gsplat, gaussian-splatting, 3dgs-cpp
```

### Optional Environment Variables

```bash
# Container names (defaults shown)
AZURE_BLOB_CONTAINER_INPUT=input            # Where MP4s are uploaded
AZURE_BLOB_CONTAINER_OUTPUT=output          # Where PLY/SPLAT/manifest are written
AZURE_BLOB_CONTAINER_PROCESSED=processed    # Archive after success
AZURE_BLOB_CONTAINER_ERROR=error            # Archive after failure

# Auth: see Authentication section below
AZURE_USE_MANAGED_IDENTITY=true             # Use Managed Identity (Azure VMs, ACI, AKS)
AZURE_STORAGE_SAS_TOKEN="sv=2022-11-02&..." # Use SAS token auth

# Paths default to /tmp/3dgs-work/* in batch mode, but can be overridden
OUTPUT_PATH=/custom/output/dir
TEMP_PATH=/custom/temp/dir
```

### Authentication

Batch mode supports three authentication methods, checked in priority order:

| Priority | Method | Env Variable | Best For |
|----------|--------|-------------|----------|
| 1 | **SAS Token** | `AZURE_STORAGE_SAS_TOKEN` | CI/CD pipelines, time-limited access, cross-tenant |
| 2 | **Managed Identity** | `AZURE_USE_MANAGED_IDENTITY=true` | Azure VMs, ACI, AKS (production) |
| 3 | **Azure CLI** | *(default)* | Local development (`az login`) |

> **Note:** Storage account keys (connection strings) are not supported in batch mode.
> Use SAS tokens for key-based scenarios — they provide time-limited access and can be
> scoped to specific containers and operations.

#### SAS Token Authentication

Generate a SAS token with the required permissions and set it as an environment variable.
The token is appended to the storage endpoint URL — no credential object is needed.

```bash
# Generate an account-level SAS token (read, write, delete, list on blob service)
SAS_TOKEN=$(az storage account generate-sas \
  --account-name $STORAGE_ACCOUNT \
  --permissions rwdlac \
  --services b \
  --resource-types sco \
  --expiry $(date -u -d '+24 hours' +%Y-%m-%dT%H:%MZ) \
  --output tsv)

# Run with SAS token
RUN_MODE=batch \
  AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  AZURE_STORAGE_SAS_TOKEN="$SAS_TOKEN" \
  BATCH_INPUT_PREFIX=scene_001/ \
  BACKEND=mock \
  cargo run --release
```

You can also generate a container-level SAS token for tighter scoping:

```bash
# Container-level SAS (input container: read+list, output container: write)
# Note: you'll need separate tokens per container, or use account-level SAS
SAS_TOKEN=$(az storage container generate-sas \
  --account-name $STORAGE_ACCOUNT \
  --name input \
  --permissions rl \
  --expiry $(date -u -d '+24 hours' +%Y-%m-%dT%H:%MZ) \
  --output tsv)
```

#### Azure CLI Authentication (Local Development)

```bash
# Log in to Azure (one-time setup)
az login

# Assign yourself Storage Blob Data Contributor role
az role assignment create \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT

# Run — Azure CLI credentials are used automatically
RUN_MODE=batch \
  AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  BATCH_INPUT_PREFIX=scene_001/ \
  BACKEND=mock \
  cargo run --release
```

> **Important:** `az login` alone is not enough — you also need the
> **Storage Blob Data Contributor** RBAC role on the storage account. Without it,
> you'll get a 403 Forbidden error even though authentication succeeds.

#### Managed Identity Authentication (Azure VMs, ACI, AKS)

```bash
# Enable system-assigned managed identity on a VM
az vm identity assign --name myVM --resource-group $RESOURCE_GROUP

# Get the VM's identity principal ID
PRINCIPAL_ID=$(az vm show --name myVM --resource-group $RESOURCE_GROUP \
  --query identity.principalId -o tsv)

# Assign Storage Blob Data Contributor role
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role "Storage Blob Data Contributor" \
  --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT

# On the VM, run with managed identity
RUN_MODE=batch \
  AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  AZURE_USE_MANAGED_IDENTITY=true \
  BATCH_INPUT_PREFIX=scene_001/ \
  BACKEND=gsplat \
  ./3dgs-processor
```

### Complete Examples

#### Local Development (Azure CLI)

```bash
# Prerequisites: az login, RBAC role assigned
az login

RUN_MODE=batch \
  AZURE_STORAGE_ACCOUNT=my3dgsdata \
  BATCH_INPUT_PREFIX=scene_001/ \
  BACKEND=mock \
  RECONSTRUCTION_BACKEND=colmap \
  FRAME_RATE=2 \
  cargo run --release
```

#### Docker with SAS Token

```bash
# Generate SAS token
SAS_TOKEN=$(az storage account generate-sas \
  --account-name my3dgsdata \
  --permissions rwdlac --services b --resource-types sco \
  --expiry $(date -u -d '+24 hours' +%Y-%m-%dT%H:%MZ) \
  --output tsv)

# Run in Docker — no privileged mode needed
docker run --rm \
  -e RUN_MODE=batch \
  -e AZURE_STORAGE_ACCOUNT=my3dgsdata \
  -e AZURE_STORAGE_SAS_TOKEN="$SAS_TOKEN" \
  -e BATCH_INPUT_PREFIX=scene_001/ \
  -e BACKEND=mock \
  youracr.azurecr.io/3dgs-processor:cpu
```

#### Docker with Managed Identity (Azure VM)

```bash
docker run --rm \
  -e RUN_MODE=batch \
  -e AZURE_STORAGE_ACCOUNT=my3dgsdata \
  -e AZURE_USE_MANAGED_IDENTITY=true \
  -e BATCH_INPUT_PREFIX=scene_001/ \
  -e BACKEND=gsplat \
  youracr.azurecr.io/3dgs-processor:gpu
```

#### Azure Container Instances (Managed Identity)

```bash
az container create \
  --resource-group mygroup \
  --name 3dgs-batch-job \
  --image myregistry.azurecr.io/3dgs-processor:gpu \
  --assign-identity \
  --environment-variables \
    RUN_MODE=batch \
    AZURE_STORAGE_ACCOUNT=my3dgsdata \
    BATCH_INPUT_PREFIX=scene_001/ \
    BACKEND=gsplat \
    AZURE_USE_MANAGED_IDENTITY=true \
    RECONSTRUCTION_BACKEND=colmap \
    FRAME_RATE=2 \
  --restart-policy Never \
  --cpu 8 --memory 16
```

#### Azure Container Instances (SAS Token)

```bash
# Use --secure-environment-variables for SAS tokens
az container create \
  --resource-group mygroup \
  --name 3dgs-batch-job \
  --image myregistry.azurecr.io/3dgs-processor:gpu \
  --environment-variables \
    RUN_MODE=batch \
    AZURE_STORAGE_ACCOUNT=my3dgsdata \
    BATCH_INPUT_PREFIX=scene_001/ \
    BACKEND=gsplat \
  --secure-environment-variables \
    AZURE_STORAGE_SAS_TOKEN="$SAS_TOKEN" \
  --restart-policy Never \
  --cpu 8 --memory 16
```

### Batch Mode vs Watch Mode

| Feature | Watch Mode | Batch Mode |
|---------|-----------|------------|
| Azure access | BlobFuse2 (FUSE mount) | Azure SDK (direct API) |
| Privileged container | Yes (`--device /dev/fuse`) | **No** |
| Lifecycle | Continuous service | Single job → exit |
| Trigger | File watcher detects new folders | External orchestration |
| `INPUT_PATH` etc. | Required local paths | Optional (defaults to /tmp) |
| Auth: Azure CLI | ✗ | ✓ (default for local dev) |
| Auth: SAS Token | Via BlobFuse2 config | ✓ `AZURE_STORAGE_SAS_TOKEN` |
| Auth: Managed Identity | Via BlobFuse2 config | ✓ `AZURE_USE_MANAGED_IDENTITY=true` |
| Auth: Connection String | Via BlobFuse2 config | ✗ (use SAS token instead) |

### Troubleshooting Batch Mode

| Symptom | Cause | Fix |
|---------|-------|-----|
| `AZURE_STORAGE_ACCOUNT is required` | Missing env var | Set `AZURE_STORAGE_ACCOUNT=<name>` |
| `No blobs found in container 'input' with prefix 'X'` | Wrong prefix or empty container | Check `az storage blob list --container-name input --prefix X` |
| `403 Forbidden` with Azure CLI auth | Missing RBAC role | Assign **Storage Blob Data Contributor** role |
| `403 Forbidden` with SAS token | Token expired or wrong permissions | Regenerate SAS with `rwdlac` permissions on blob service |
| `401 Unauthorized` with Managed Identity | Identity not assigned or wrong scope | Verify `az vm identity show` and RBAC assignment |
| Process exits with code 1 | Pipeline failure | Check stderr logs; inputs moved to error container |
| `Failed to create DeveloperToolsCredential` | Not logged in | Run `az login` |

## Resource Requirements

### Minimum Requirements

* **CPU**: 4 cores (8+ cores recommended)
* **RAM**: 8GB (16GB+ recommended for large scenes)
* **Disk**: 100GB (500GB+ recommended for production)
* **GPU**: Optional (required for `gaussian-splatting` and `gsplat` backends)

### Sizing Guidelines

Resource needs scale with:

* **Video Resolution**: 4K requires 2-3x resources vs. 1080p
* **Video Count**: 5+ videos per job require more memory
* **Training Iterations**: Higher iterations = longer GPU time
* **Concurrent Jobs**: Sequential processing (1 at a time)

**Example Profiles:**

| Profile | Videos | Resolution | CPU | RAM | Disk | GPU |
|---------|--------|------------|-----|-----|------|-----|
| Small | 2-3 | 720p-1080p | 4 | 8GB | 100GB | Optional |
| Medium | 3-5 | 1080p-1440p | 8 | 16GB | 250GB | Recommended |
| Large | 5+ | 1440p-4K | 16 | 32GB | 500GB | Required |

### Disk I/O Optimization

* **Use SSDs** for input/output paths (10x faster frame extraction)
* **Separate volumes** for input, output, and processed (parallel I/O)
* **Local storage** preferred over network mounts for performance
* **NVMe drives** ideal for high-throughput scenarios

## Storage Configuration

### Local Filesystem

Recommended directory layout:

```
/data/
├── input/          # Active uploads (fast SSD)
├── output/         # Processing outputs (fast SSD)
├── processed/      # Archive (slower HDD acceptable)
└── error/          # Failed jobs (manual review)
```

Mount with appropriate permissions:

```bash
docker run -d \
  -v /data/input:/data/input \
  -v /data/output:/data/output \
  -v /data/processed:/data/processed:ro \  # Read-only for safety
  -v /data/error:/data/error \
  ...
```

### Network File Systems

**NFS Configuration:**

```yaml
volumes:
  - type: nfs
    source: nfs-server.example.com:/export/3dgs/input
    target: /data/input
    volume:
      nocopy: true
      o: "addr=nfs-server.example.com,rw,sync"
```

**Note**: Use `poll_watcher` for NFS mounts (set `WATCHER_MODE=poll`).

### Azure Files

```bash
# Create file share
az storage share create --name 3dgs-input --quota 1024

# Mount in container
docker run -d \
  -v 3dgs-input:/data/input \
  --mount type=volume,dst=/data/input,volume-driver=azure,volume-opt=share=3dgs-input \
  ...
```

## Azure Blob Storage Setup

### Prerequisites

1. **Azure Subscription** - Active subscription (free tier works for testing)
2. **Azure Storage Account** - General Purpose v2 with Blob Storage
3. **Azure CLI** - For setup and management (`az login` required)
4. **Authentication** - One of: Connection String, SAS Token, Azure AD, or Managed Identity
5. **Linux Container Host** - Blobfuse2 requires Linux kernel (not available on macOS)

### Quick Setup (For Testing)

Use the provided setup script to create test resources:

```bash
# Clone repository
cd 3DGS-accelerator

# Create Azure resources (auto-generates unique storage account name)
./scripts/azure-setup.sh

# Load credentials
source azure-test-config.env

# Run test to validate
./scripts/azure-test.sh

# Cleanup when done
./scripts/azure-cleanup.sh --delete-all
```

For production deployment, continue with the sections below.

### Azure Storage Account Setup

#### 1. Create Storage Account

```bash
# Set variables
RESOURCE_GROUP="<your-resource-group>"
LOCATION="eastus"
STORAGE_ACCOUNT="3dgsprodstorage"  # Must be globally unique, lowercase, 3-24 chars

# Create resource group
az group create \
  --name $RESOURCE_GROUP \
  --location $LOCATION

# Create storage account
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2 \
  --https-only true \
  --min-tls-version TLS1_2
```

#### 2. Create Blob Containers

```bash
# Option A: Using connection string (if shared key enabled)
CONN_STRING=$(az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query connectionString -o tsv)

for container in input output processed error; do
  az storage container create \
    --name $container \
    --connection-string "$CONN_STRING"
done

# Option B: Using Azure AD authentication (enterprise environments)
for container in input output processed error; do
  az storage container create \
    --name $container \
    --account-name $STORAGE_ACCOUNT \
    --auth-mode login
done
```

**Container Purpose:**
- `input/` - Active uploads waiting for processing
- `output/` - Generated PLY/SPLAT models and manifests
- `processed/` - Archive of successfully processed jobs
- `error/` - Failed jobs for manual review

### Authentication Methods

The processor supports **four authentication methods**. Choose based on your security requirements:

#### 1. Connection String (Development/Testing)

**Best for:** Local testing, simple setups  
**Security:** ⚠️ Highest privilege - protect carefully  
**Availability:** ❌ Not available if shared key access disabled

```bash
# Get connection string
az storage account show-connection-string \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query connectionString -o tsv

# Use in container
docker run -d --privileged \
  --name 3dgs-processor \
  -e AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=3dgsprodstorage;AccountKey=abc123...;EndpointSuffix=core.windows.net" \
  -e AZURE_BLOB_CONTAINER_INPUT=input \
  -e AZURE_BLOB_CONTAINER_OUTPUT=output \
  -e AZURE_BLOB_CONTAINER_PROCESSED=processed \
  -e AZURE_BLOB_CONTAINER_ERROR=error \
  youracr.azurecr.io/3dgs-processor:gpu
```

#### 2. SAS Token (Time-Limited)

**Best for:** Temporary access, third-party integrations  
**Security:** ✅ Time-limited, scoped permissions  
**Availability:** ⚠️ Account SAS requires shared keys; User delegation SAS works with Azure AD

**Generate User Delegation SAS (Azure AD-based):**

```bash
# Requires Storage Blob Data Contributor role
EXPIRY="2026-12-31"

# Get user delegation SAS (works even with shared key disabled)
az storage container generate-sas \
  --name input \
  --account-name $STORAGE_ACCOUNT \
  --permissions racwdl \
  --expiry $EXPIRY \
  --auth-mode login \
  --as-user

# Output: se=2026-12-31&sp=racwdl&sv=2021-06-08&sr=c&sig=...

# Use in container
docker run -d --privileged \
  --name 3dgs-processor \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  -e AZURE_STORAGE_SAS_TOKEN="se=2026-12-31&sp=racwdl&sv=2021-06-08&sr=c&sig=..." \
  -e AZURE_BLOB_CONTAINER_INPUT=input \
  youracr.azurecr.io/3dgs-processor:gpu
```

**Best Practices:**
- Set expiry to shortest necessary duration (e.g., 7 days for testing, 90 days for production)
- Use user delegation SAS (Azure AD-based) instead of account SAS
- Rotate SAS tokens regularly
- Store in secrets manager (Azure Key Vault), not in code

#### 3. Azure AD Authentication (Enterprise) ⭐ Recommended

**Best for:** Enterprise environments, security-first organizations  
**Security:** ✅ No shared keys, identity-based, full audit trail  
**Availability:** ✅ **Works when shared key access is disabled**

**Setup:**

```bash
# 1. Assign role to user/service principal/managed identity
USER_ID=$(az ad signed-in-user show --query id -o tsv)

az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $USER_ID \
  --scope "/subscriptions/<subscription-id>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

# 2. Login to Azure (for local testing)
az login

# 3. Run container with Azure AD
docker run -d --privileged \
  --name 3dgs-processor \
  -v $HOME/.azure:/root/.azure:ro \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  -e AZURE_USE_AZURE_AD=true \
  youracr.azurecr.io/3dgs-processor:gpu
```

**For CI/CD (Service Principal):**

```bash
# Create service principal
SP=$(az ad sp create-for-rbac --name "3dgs-processor-sp" --role "Storage Blob Data Contributor" --scopes "/subscriptions/<sub>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT")

# Use credentials in container
docker run -d --privileged \
  -e AZURE_TENANT_ID=$(echo $SP | jq -r .tenant) \
  -e AZURE_CLIENT_ID=$(echo $SP | jq -r .appId) \
  -e AZURE_CLIENT_SECRET=$(echo $SP | jq -r .password) \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  youracr.azurecr.io/3dgs-processor:gpu
```

#### 4. Managed Identity (Production Azure Deployment) ⭐ Most Secure

**Best for:** Azure VM, Azure Container Instances, AKS  
**Security:** ✅✅ No credentials, Azure-managed, most secure  
**Availability:** Only in Azure environments (VM/ACI/AKS)

**Azure Container Instances Example:**

```bash
# 1. Create container with managed identity
az container create \
  --resource-group $RESOURCE_GROUP \
  --name 3dgs-processor \
  --image youracr.azurecr.io/3dgs-processor:gpu \
  --cpu 8 --memory 16 \
  --assign-identity [system] \
  --environment-variables \
    AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
    AZURE_USE_MANAGED_IDENTITY=true

# 2. Get managed identity ID
IDENTITY_ID=$(az container show \
  --resource-group $RESOURCE_GROUP \
  --name 3dgs-processor \
  --query identity.principalId -o tsv)

# 3. Grant storage access
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id $IDENTITY_ID \
  --scope "/subscriptions/<sub>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"
```

**No credentials needed in container!** Azure manages authentication automatically.

### Enterprise Environments (Shared Key Disabled)

Many organizations disable shared key access for compliance (SOC 2, ISO 27001, etc.):

```bash
# Check if shared key is disabled
az storage account show \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query allowSharedKeyAccess -o tsv
# Output: false
```

**If shared key is disabled:**

✅ **Azure AD authentication** - Works (use `--auth-mode login`)  
✅ **User delegation SAS** - Works (Azure AD-based)  
✅ **Managed Identity** - Works (Azure AD-based)  
❌ **Connection string** - Blocked  
❌ **Account SAS** - Blocked

**Required Setup:**

```bash
# 1. Assign required role
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee <user-or-sp-object-id> \
  --scope "/subscriptions/<sub>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

# 2. All Azure CLI commands must use --auth-mode login
az storage blob upload \
  --account-name $STORAGE_ACCOUNT \
  --container-name input \
  --name test.mp4 \
  --file test.mp4 \
  --auth-mode login  # Required!

# 3. Container uses Azure AD or managed identity (see methods 3 & 4 above)
```

### Blobfuse2 Container Mount (Linux Only)

**Requirements:**
- Linux kernel (not available on macOS/Windows)
- Privileged container (requires FUSE kernel module access)
- AMD64 architecture (blobfuse2 not available for ARM64)

**Basic Mount:**

```bash
docker run -d --privileged \
  --name 3dgs-processor \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  -e AZURE_STORAGE_CONNECTION_STRING="..." \
  -e INPUT_PATH=/mnt/blobfuse/input \
  -e OUTPUT_PATH=/mnt/blobfuse/output \
  -e PROCESSED_PATH=/mnt/blobfuse/processed \
  -e ERROR_PATH=/mnt/blobfuse/error \
  youracr.azurecr.io/3dgs-processor:gpu
```

**Performance Tuning:**

```bash
# Configure caching for better performance
docker run -d --privileged \
  --name 3dgs-processor \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  -e AZURE_STORAGE_CONNECTION_STRING="..." \
  -e BLOBFUSE_CACHE_SIZE_MB=10240 \
  -e BLOBFUSE_FILE_CACHE_TIMEOUT_SECS=120 \
  -e BLOBFUSE_ATTR_CACHE_TIMEOUT_SECS=60 \
  -e BLOBFUSE_ENABLE_STREAMING=true \
  youracr.azurecr.io/3dgs-processor:gpu
```

**Cache Configuration:**
- `BLOBFUSE_CACHE_SIZE_MB`: Local disk cache size (default: 1024, recommend: 10240 for production)
- `BLOBFUSE_FILE_CACHE_TIMEOUT_SECS`: File cache validity (default: 120)
- `BLOBFUSE_ATTR_CACHE_TIMEOUT_SECS`: Attribute cache (default: 60)
- `BLOBFUSE_ENABLE_STREAMING`: Stream large files (default: false)

**Why Privileged?** Blobfuse2 requires CAP_SYS_ADMIN to mount FUSE filesystems.

### Production Deployment Examples

#### Azure Container Instances (Recommended for Production)

**Deployment with Managed Identity (Most Secure):**

```bash
# Set variables
RESOURCE_GROUP="<your-resource-group>"
LOCATION="eastus"
CONTAINER_NAME="3dgs-processor"
ACR_NAME="yourcontainerregistry"
IMAGE="$ACR_NAME.azurecr.io/3dgs-processor:gpu"
STORAGE_ACCOUNT="3dgsprodstorage"

# Create container with managed identity
az container create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --image $IMAGE \
  --cpu 8 \
  --memory 16 \
  --os-type Linux \
  --restart-policy Always \
  --assign-identity [system] \
  --acr-identity [system] \
  --environment-variables \
    INPUT_PATH=/mnt/blobfuse/input \
    OUTPUT_PATH=/mnt/blobfuse/output \
    PROCESSED_PATH=/mnt/blobfuse/processed \
    ERROR_PATH=/mnt/blobfuse/error \
    AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
    AZURE_USE_MANAGED_IDENTITY=true \
    BACKEND=gsplat \
    LOG_LEVEL=info \
    HEALTH_CHECK_ENABLED=true \
    HEALTH_CHECK_PORT=8080 \
    RETENTION_DAYS=30 \
    MAX_RETRIES=3 \
  --ports 8080

# Get managed identity principal ID
IDENTITY_ID=$(az container show \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --query identity.principalId -o tsv)

# Grant storage access to managed identity
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id $IDENTITY_ID \
  --scope "/subscriptions/<subscription-id>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

# Grant ACR pull access (if using private ACR)
az role assignment create \
  --role "AcrPull" \
  --assignee-object-id $IDENTITY_ID \
  --scope "/subscriptions/<subscription-id>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"

echo "Waiting 2 minutes for role assignments to propagate..."
sleep 120

# Restart container to apply permissions
az container restart --resource-group $RESOURCE_GROUP --name $CONTAINER_NAME
```

**Monitor Deployment:**

```bash
# View logs (follow mode)
az container logs \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --follow

# Check health endpoint
CONTAINER_IP=$(az container show \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --query ipAddress.ip -o tsv)

curl http://$CONTAINER_IP:8080/health

# Check container status
az container show \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --query '{state:instanceView.state,cpu:containers[0].resources.requests.cpu,memory:containers[0].resources.requests.memoryInGB,restartCount:instanceView.currentState.restartCount}'

# Execute command inside container
az container exec \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --exec-command "/bin/bash"
```

**Update Deployment:**

```bash
# Delete old container
az container delete \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME \
  --yes

# Deploy new version (repeat create command with new image tag)
```

**Cost Optimization:**

```bash
# Use spot instances for development (60-90% cheaper)
az container create \
  --resource-group $RESOURCE_GROUP \
  --name $CONTAINER_NAME-dev \
  --image $IMAGE \
  --priority Spot \
  --cpu 4 \
  --memory 8 \
  ...

# Set restart policy for one-time jobs
--restart-policy OnFailure  # Only restart on failure, not on success
```

#### Azure Virtual Machine (For GPU Workloads)

**Create GPU-enabled VM:**

```bash
RESOURCE_GROUP="<your-resource-group>"
VM_NAME="3dgs-gpu-vm"
LOCATION="eastus"
STORAGE_ACCOUNT="3dgsprodstorage"

# Create VM with GPU (NC-series for CUDA)
az vm create \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --location $LOCATION \
  --size Standard_NC6s_v3 \
  --image Ubuntu2204 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --assign-identity [system]

# Get managed identity
IDENTITY_ID=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --query identity.principalId -o tsv)

# Grant storage access
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id $IDENTITY_ID \
  --scope "/subscriptions/<sub>/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

# SSH into VM
VM_IP=$(az vm show \
  --resource-group $RESOURCE_GROUP \
  --name $VM_NAME \
  --show-details \
  --query publicIps -o tsv)

ssh azureuser@$VM_IP
```

**Setup VM:**

```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER

# Install NVIDIA drivers (for GPU)
sudo apt update
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers autoinstall
sudo reboot

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo systemctl restart docker

# Verify GPU
nvidia-smi
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```

**Run Container on VM:**

```bash
# Login to Azure from VM (for managed identity)
az login --identity

# Run container with GPU
docker run -d --privileged \
  --name 3dgs-processor \
  --gpus all \
  --restart unless-stopped \
  -v /mnt/blobfuse:/mnt/blobfuse \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  -e AZURE_USE_MANAGED_IDENTITY=true \
  -e INPUT_PATH=/mnt/blobfuse/input \
  -e OUTPUT_PATH=/mnt/blobfuse/output \
  -e PROCESSED_PATH=/mnt/blobfuse/processed \
  -e ERROR_PATH=/mnt/blobfuse/error \
  -e BACKEND=gsplat \
  -e LOG_LEVEL=info \
  youracr.azurecr.io/3dgs-processor:gpu

# Monitor
docker logs -f 3dgs-processor
```

**Auto-start on VM reboot:**

```bash
# Create systemd service
sudo tee /etc/systemd/system/3dgs-processor.service <<EOF
[Unit]
Description=3DGS Video Processor
Requires=docker.service
After=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker start -a 3dgs-processor
ExecStop=/usr/bin/docker stop -t 10 3dgs-processor

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable 3dgs-processor
sudo systemctl start 3dgs-processor
sudo systemctl status 3dgs-processor
```

#### Kubernetes / AKS (For Enterprise Scale)

See [Kubernetes Deployment](#kubernetes-deployment) section above for full deployment manifests.

**AKS-specific quick start:**

```bash
# Create AKS cluster with managed identity
az aks create \
  --resource-group $RESOURCE_GROUP \
  --name 3dgs-aks-cluster \
  --node-count 2 \
  --node-vm-size Standard_D8s_v3 \
  --enable-managed-identity \
  --generate-ssh-keys

# Get credentials
az aks get-credentials \
  --resource-group $RESOURCE_GROUP \
  --name 3dgs-aks-cluster

# Enable Azure AD workload identity (for pod-level managed identity)
az aks update \
  --resource-group $RESOURCE_GROUP \
  --name 3dgs-aks-cluster \
  --enable-oidc-issuer \
  --enable-workload-identity

# Deploy application
kubectl create namespace 3dgs
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/pvc.yaml

# Monitor
kubectl logs -f deployment/3dgs-processor -n 3dgs
kubectl get pods -n 3dgs
```

**Scale down when idle:**

```bash
# Manual scale
kubectl scale deployment/3dgs-processor --replicas=0 -n 3dgs  # Stop
kubectl scale deployment/3dgs-processor --replicas=1 -n 3dgs  # Start

# Auto-scale based on CPU (future enhancement)
kubectl autoscale deployment/3dgs-processor \
  --cpu-percent=50 \
  --min=0 \
  --max=3 \
  -n 3dgs
```

## Security Hardening

### Container Security

1. **Run as Non-Root User** (when possible):

```dockerfile
USER 1000:1000
```

1. **Read-Only Root Filesystem**:

```yaml
security_opt:
  - no-new-privileges:true
read_only: true
tmpfs:
  - /tmp
  - /var/tmp
```

1. **Limit Capabilities**:

```yaml
cap_drop:
  - ALL
cap_add:
  - SYS_ADMIN  # Required for Blobfuse2 mounting
```

### Secret Management

**Never hardcode credentials**. Use secrets management:

```yaml
# Docker Compose with secrets
secrets:
  azure_connection_string:
    file: ./secrets/azure_conn.txt

services:
  3dgs-processor:
    secrets:
      - azure_connection_string
    environment:
      AZURE_STORAGE_CONNECTION_STRING_FILE: /run/secrets/azure_connection_string
```

**Kubernetes Secrets:**

```bash
kubectl create secret generic azure-storage \
  --from-literal=connection-string="DefaultEndpointsProtocol=..." \
  -n 3dgs

# Reference in deployment
env:
- name: AZURE_STORAGE_CONNECTION_STRING
  valueFrom:
    secretKeyRef:
      name: azure-storage
      key: connection-string
```

### Network Security

1. **Restrict Ingress**: Only health check port (8080) if needed
2. **Use Private Endpoints**: Azure Storage private endpoints
3. **Firewall Rules**: Whitelist container IPs in storage account

### Credential Redaction

Logs automatically redact Azure credentials:

```
[INFO] Mounting Azure Blob Storage: account=mystorageaccount, container=3dgs-input, auth=[REDACTED]
```

## Monitoring and Logging

### Structured Logging

Logs are JSON-formatted for easy parsing:

```json
{
  "timestamp": "2024-01-01T12:00:00Z",
  "level": "INFO",
  "target": "three_dgs_processor::processor::job",
  "message": "Job completed successfully",
  "job_id": "scene_001",
  "duration_secs": 245.3,
  "frames_extracted": 450,
  "gaussian_count": 150000
}
```

### Log Aggregation

**ELK Stack:**

```yaml
logging:
  driver: "fluentd"
  options:
    fluentd-address: "fluentd.example.com:24224"
    tag: "3dgs-processor"
```

**Azure Monitor:**

```bash
docker run -d \
  --log-driver=azuremonitor \
  --log-opt WorkspaceId=<workspace-id> \
  --log-opt WorkspaceKey=<workspace-key> \
  ...
```

### Metrics

Key metrics to monitor:

* **Job Success Rate**: `processed/` vs. `error/` folder counts
* **Processing Duration**: Time from upload to output
* **Disk Usage**: `/data` partition utilization
* **Memory Usage**: Container RSS
* **Frame Extraction Rate**: Frames/second
* **Training Loss**: Final loss value per job

**Prometheus Integration** (future):

```yaml
# Expose metrics endpoint
-e METRICS_PORT=9090

# Scrape config
scrape_configs:
  - job_name: '3dgs-processor'
    static_configs:
      - targets: ['processor:9090']
```

### Health Checks

HTTP health endpoint:

```bash
curl http://localhost:8080/health

# Response
{
  "status": "healthy",
  "uptime_secs": 86400,
  "jobs_processed": 42,
  "disk_free_gb": 150.5
}
```

## Backup and Disaster Recovery

### Backup Strategy

1. **Configuration**: Version control `config.yaml` and env files
2. **Processed Data**: Archive to cold storage after retention period
3. **Error Folder**: Backup before manual deletion
4. **Logs**: Retain for 30-90 days

### Disaster Recovery

**Restart Resilience:**

* Service checks `processed/` and `error/` on startup
* Duplicate detection prevents reprocessing
* In-progress jobs resume from last checkpoint

**Data Loss Prevention:**

* Use Azure Blob Storage geo-redundant replication
* Regular snapshots of persistent volumes
* Separate processed/error archives from active processing

## Scaling Considerations

**Horizontal Scaling**: Not recommended (sequential processing model)

**Vertical Scaling**: Increase CPU/RAM/GPU for faster processing

**Alternative Approach**: Deploy multiple instances with different input folders

```yaml
# Instance 1
-e INPUT_PATH=/data/input-1

# Instance 2
-e INPUT_PATH=/data/input-2
```

Route uploads to different instances based on load balancing.

## Azure Troubleshooting

### Authentication Errors

**Error:** `Key based authentication is not permitted on this storage account`

**Cause:** Shared key access is disabled (enterprise security policy)

**Solution:** Use Azure AD authentication or managed identity:

```bash
# Option 1: Azure AD
docker run -d --privileged \
  -v $HOME/.azure:/root/.azure:ro \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  -e AZURE_USE_AZURE_AD=true \
  youracr.azurecr.io/3dgs-processor:gpu

# Option 2: Service Principal
docker run -d --privileged \
  -e AZURE_TENANT_ID=$TENANT_ID \
  -e AZURE_CLIENT_ID=$CLIENT_ID \
  -e AZURE_CLIENT_SECRET=$CLIENT_SECRET \
  -e AZURE_STORAGE_ACCOUNT=$STORAGE_ACCOUNT \
  youracr.azurecr.io/3dgs-processor:gpu
```

**Error:** `AuthorizationFailed` or `This request is not authorized to perform this operation`

**Cause:** Missing role assignment

**Solution:** Grant Storage Blob Data Contributor role:

```bash
# For user
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<account>"

# For service principal
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee <sp-object-id> \
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<account>"

# For managed identity (from ACI/VM)
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id <managed-identity-principal-id> \
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<account>"
```

**Wait 5 minutes** for role propagation before retrying.

**Error:** `SAS token expired` or `Server failed to authenticate the request`

**Cause:** SAS token expired or malformed

**Solution:** Generate new SAS token:

```bash
# User delegation SAS (works with shared key disabled)
az storage container generate-sas \
  --name input \
  --account-name $STORAGE_ACCOUNT \
  --permissions racwdl \
  --expiry 2026-12-31 \
  --auth-mode login \
  --as-user
```

### Blobfuse2 Mount Errors

**Error:** `fusermount: command not found` or `FUSE device not found`

**Cause:** Running on macOS or Windows (FUSE requires Linux kernel)

**Solution:** Deploy to Linux environment:
- Azure Container Instances (Linux)
- Azure VM (Ubuntu/Debian)
- Local Linux machine via Docker/Podman

**Error:** `operation not permitted` when mounting

**Cause:** Container not running in privileged mode

**Solution:** Add `--privileged` flag:

```bash
docker run -d --privileged ...  # Required for FUSE
```

**Error:** `blobfuse2: No such file or directory`

**Cause:** Running ARM64 image (blobfuse2 only available on AMD64)

**Solution:** Use AMD64 image:

```bash
docker pull --platform linux/amd64 youracr.azurecr.io/3dgs-processor:cpu
```

**Error:** Slow mount performance or timeouts

**Cause:** Insufficient cache configuration

**Solution:** Increase cache size:

```bash
# Add caching environment variables
-e BLOBFUSE_CACHE_SIZE_MB=10240 \
-e BLOBFUSE_FILE_CACHE_TIMEOUT_SECS=120
```

### Container Deployment Issues

**Error:** `No space left on device`

**Cause:** Insufficient disk space in container or host

**Solution:** 

```bash
# 1. Check host disk space
df -h

# 2. Clean old containers/images
docker system prune -a

# 3. Increase container disk quota (if using overlay2)
docker run -d --storage-opt size=100G ...

# 4. Check retention policy removes old jobs
-e RETENTION_DAYS=7 \
-e MIN_DISK_SPACE_GB=50
```

**Error:** `Container exits immediately` or `processor crashes on startup`

**Cause:** Missing required environment variables

**Solution:** Check logs and verify minimum required variables:

```bash
# View logs
docker logs 3dgs-processor

# Minimum required variables
-e INPUT_PATH=/mnt/blobfuse/input \
-e OUTPUT_PATH=/mnt/blobfuse/output \
-e PROCESSED_PATH=/mnt/blobfuse/processed \
-e ERROR_PATH=/mnt/blobfuse/error \
-e AZURE_STORAGE_ACCOUNT=<account> \
-e AZURE_STORAGE_CONNECTION_STRING=<connection-string>  # OR other auth method
```

### Network and Connectivity

**Error:** `Connection timeout` or `Unable to connect to Azure`

**Cause:** Firewall, private endpoint, or network policy

**Solution:**

```bash
# 1. Check firewall rules on storage account
az storage account show \
  --name $STORAGE_ACCOUNT \
  --query networkRuleSet

# 2. Add container IP to whitelist (if restricted)
az storage account network-rule add \
  --account-name $STORAGE_ACCOUNT \
  --ip-address <container-public-ip>

# 3. Enable service endpoint (for ACI/AKS)
az storage account update \
  --name $STORAGE_ACCOUNT \
  --default-action Deny \
  --bypass AzureServices

# 4. Use private endpoint (VNet deployment)
az network private-endpoint create \
  --name 3dgs-private-endpoint \
  --resource-group $RESOURCE_GROUP \
  --vnet-name <vnet> --subnet <subnet> \
  --private-connection-resource-id <storage-account-id> \
  --group-id blob \
  --connection-name 3dgs-blob-connection
```

**Error:** `DNS resolution failed` for storage account

**Cause:** Private endpoint DNS not configured

**Solution:** Configure private DNS zone:

```bash
az network private-dns zone create \
  --resource-group $RESOURCE_GROUP \
  --name privatelink.blob.core.windows.net

az network private-dns link vnet create \
  --resource-group $RESOURCE_GROUP \
  --zone-name privatelink.blob.core.windows.net \
  --name 3dgs-dns-link \
  --virtual-network <vnet> \
  --registration-enabled false
```

### Performance Issues

**Slow blob upload/download**

**Causes & Solutions:**

1. **Geographic distance:** Deploy container in same region as storage account
   ```bash
   # Check storage account location
   az storage account show --name $STORAGE_ACCOUNT --query location
   
   # Deploy to same region
   az container create --location <same-region> ...
   ```

2. **Insufficient bandwidth:** Upgrade storage account tier
   ```bash
   # Upgrade to Premium (better IOPS)
   az storage account update \
     --name $STORAGE_ACCOUNT \
     --sku Premium_LRS
   ```

3. **Cache not configured:** Add blobfuse2 cache settings (see above)

4. **Concurrent operations throttled:** Azure storage limits operations per second
   ```bash
   # Monitor throttling
   az monitor metrics list \
     --resource <storage-account-id> \
     --metric "Throttling"
   ```

### Debugging Commands

**Check container status:**

```bash
# Container logs
docker logs 3dgs-processor --tail 100 --follow

# Container exec for debugging
docker exec -it 3dgs-processor /bin/bash

# Check mounted blobfuse
df -h  # Inside container
mount | grep blobfuse

# Test Azure connectivity
az storage blob list \
  --account-name $STORAGE_ACCOUNT \
  --container-name input \
  --auth-mode login
```

**Check Azure resources:**

```bash
# Storage account status
az storage account show \
  --name $STORAGE_ACCOUNT \
  --query '{name:name, location:location, sku:sku.name, allowSharedKey:allowSharedKeyAccess}'

# List containers
az storage container list \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode login

# Check role assignments
az role assignment list \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/$STORAGE_ACCOUNT"

# View activity logs (recent operations)
az monitor activity-log list \
  --resource-group $RESOURCE_GROUP \
  --offset 1h
```

### Getting Help

If issues persist:

1. **Review Documentation:**
   - [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - General troubleshooting
   - [scripts/AZURE_TESTING.md](../scripts/AZURE_TESTING.md) - Azure test scripts
   - [USER_GUIDE.md](USER_GUIDE.md) - Configuration reference

2. **Test with Scripts:**
   ```bash
   # Validate Azure setup
   ./scripts/azure-setup.sh
   source azure-test-config.env
   ./scripts/azure-test.sh
   ```

3. **Check Logs:**
   - Container logs: `docker logs 3dgs-processor`
   - Azure Activity Logs: Azure Portal → Storage Account → Activity log
   - Health endpoint: `curl http://localhost:8080/health`

4. **File Issue:**
   - GitHub Issues: Include logs, configuration (redact credentials), and error messages
