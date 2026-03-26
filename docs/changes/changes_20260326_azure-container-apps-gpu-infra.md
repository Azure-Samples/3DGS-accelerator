# Changelog: Azure Container Apps Job GPU Infrastructure

**Date:** 2026-03-26
**Branch:** `adding-infra`
**Commits:** `4cd1333`, `fa566b3`, `15f5212`

## Summary

Added full Azure Developer CLI (`azd`) infrastructure to deploy the 3DGS video processor
as a serverless GPU Container Apps Job on Azure. Includes Bicep modules, operational
scripts, RBAC separation, and bug fixes required for GPU batch mode. Verified with a
successful end-to-end run on an NVIDIA Tesla T4 GPU using the South Building test dataset.

## New Files

### Infrastructure as Code (`infra/`)

| File | Purpose |
|------|---------|
| `main.bicep` | Subscription-scoped main template orchestrating all modules |
| `main.parameters.json` | Parameter bindings from azd environment variables |
| `abbreviations.json` | Resource naming conventions |
| `modules/managed-identity.bicep` | User-Assigned Managed Identity |
| `modules/monitoring.bicep` | Log Analytics Workspace |
| `modules/acr.bicep` | Azure Container Registry (Basic SKU) |
| `modules/storage.bicep` | Storage Account with 4 blob containers (input/output/processed/error) |
| `modules/container-apps-env.bicep` | Container Apps Environment with optional GPU workload profile |
| `modules/container-apps-job.bicep` | Container Apps Job (Manual trigger, batch mode env vars) |
| `modules/acr-pull-role.bicep` | AcrPull RBAC assignment for Managed Identity |
| `modules/storage-blob-role.bicep` | Storage Blob Data Contributor RBAC for Managed Identity |
| `modules/deployer-roles.bicep` | AcrPush + Storage Blob RBAC for the deployer user |
| `rbac/main.bicep` | Standalone RBAC deployment (alternative to CLI-based assignment) |
| `rbac/main.parameters.json` | Parameter bindings for standalone RBAC deployment |

### Scripts (`infra/scripts/`)

| File | Purpose |
|------|---------|
| `hooks/preprovision.sh` | azd pre-provision hook: captures deployer identity, RBAC preflight |
| `hooks/postprovision.sh` | azd post-provision hook: builds GPU image on ACR, updates job |
| `hooks/acr-build.sh` | Creates minimal staging directory, runs `az acr build --target gpu` |
| `assign-rbac.sh` | Assigns AcrPull + Storage Blob Data Contributor to Managed Identity |
| `verify-rbac.sh` | Verifies required RBAC role assignments exist |
| `cleanup-rbac.sh` | Removes RBAC role assignments (run before `azd down`) |
| `run-job.sh` | Starts job execution with `--wait` / `--logs` options |
| `deploy-job.sh` | Rebuilds GPU image on ACR and updates the Container Apps Job |
| `upload-testdata.sh` | Downloads South Building dataset and uploads test videos to blob storage |

### Root

| File | Purpose |
|------|---------|
| `azure.yaml` | azd project definition with pre/post-provision hooks |

## Modified Files

### Bug Fixes (required for GPU batch mode)

**`src/azure/sdk.rs`** — User-assigned managed identity support
- `ManagedIdentityCredential::new(None)` was ignoring `AZURE_CLIENT_ID`, causing
  authentication failures in Container Apps (which use user-assigned identities).
- Fixed to read `AZURE_CLIENT_ID` and pass `UserAssignedId::ClientId(...)` to the
  credential options.

**`src/backends/gsplat.rs`** — COLMAP and images directory resolution
- The gsplat backend derived workspace paths from frame file locations, which breaks
  in batch mode where frames are in temporary directories (`/tmp/.tmpXXXXXX/`).
- Added fallback path resolution:
  - COLMAP sparse dir: checks `COLMAP_SPARSE_DIR` env var, then `TEMP_PATH/reconstruction/output/sparse/0`
  - Images dir: checks `TEMP_PATH/frames/`, then workspace-relative `images/`, then frame parent dir
- Added inline Python PLY-to-SPLAT converter as fallback when no external converter
  tool is available (the `ply-to-splat` binary and `gsplat.utils.ply_to_splat` module
  do not exist in the container image).

**`scripts/gsplat_train.py`** — COLMAP binary format parser
- `cameras.bin` parser used `np.fromfile(f, dtype=np.float64, count=-1)` which reads
  ALL remaining bytes. This consumed the entire file on the first camera entry.
- Fixed to read the correct number of parameters per camera model (e.g., 4 for OPENCV,
  3 for SIMPLE_PINHOLE) using a lookup table.

**`src/logging/mod.rs`** — ANSI escape code cleanup
- Container logs contained raw ANSI codes (`[2m[`, `[0m`, `[32m`) that rendered as
  garbage in Azure Log Analytics and other non-terminal log sinks.
- Added `std::io::IsTerminal` check: ANSI colors enabled for TTY, disabled for
  containers and log aggregators. No external dependency required (stable since Rust 1.70).

**`.dockerignore`** — Build context optimization
- Added exclusions for `.venv/` directories (6.9 GB `scripts/gsplat_check/.venv/`),
  `output/`, `infra/`, `container-test/`, and `scripts/gsplat_check/`.
- Removed `Dockerfile` from exclusions (required by ACR Tasks remote builds).
- Reduced Docker context from ~2.1 GB to ~160 KB.

**`.gitignore`** — Added `.azure/` directory (azd state).

### Documentation

**`docs/DEPLOYMENT.md`** — Added "Azure Container Apps Job (GPU) — azd" section with:
- Quick start walkthrough (7 steps)
- Resource provisioning table
- Detailed RBAC requirements with role definition IDs
- Deployer vs Managed Identity permission separation
- Failure symptoms for each missing role
- Scripts reference with privilege requirements
- Configuration variables and GPU region availability
- Troubleshooting guide

## Verified E2E Pipeline

The full pipeline was run successfully on Azure Container Apps with a Tesla T4 GPU:

```
Pipeline Step          Duration    Result
─────────────────────  ──────────  ──────────────────────────
Download 3 videos      ~3s         3 MP4s from Azure Blob Storage
FFmpeg frame extract   ~1s         51 frames (17 per video, 2 fps)
FFprobe metadata       <1s         Resolution, duration, codec
COLMAP reconstruction  ~50s        1654 points, 17 registered images
gsplat GPU training    ~73s        30,000 iterations, 1654 Gaussians
PLY export             <1s         65 KB point cloud
SPLAT export           <1s         53 KB web-optimized format
Upload outputs         ~2s         4 files to output container
Move to processed      ~2s         3 videos archived
TOTAL                  ~2.2 min
```
