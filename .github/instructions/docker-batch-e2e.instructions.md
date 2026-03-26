---
applyTo: 'Dockerfile, compose.yaml, scripts/e2e/**, **/e2e*, **/*batch*, **/azure/**, **/docker*'
description: 'Docker container batch-mode E2E testing with Azurite (Azure Storage emulator)'
---

# Docker Container Batch-Mode E2E Testing

## When to apply
This instruction applies when building the CPU Docker image, running the processor
container in batch mode against Azurite, or debugging container-based E2E issues.

## Overview

The **batch mode** runs the processor inside the `3dgs-processor:cpu` Docker image,
connecting to Azure Blob Storage (or Azurite emulator) via the **Azure SDK** — no
BlobFuse2 FUSE mounts, no privileged containers, no file watching.

Flow: download blobs → process → upload outputs → move inputs to processed → exit.

## CPU Image: BACKEND must be `mock`

The `cpu` target in the Dockerfile **must** set `BACKEND=mock` (not `gsplat`).
The `gsplat` backend requires a CUDA GPU which the CPU image does not have.
The Dockerfile header documents this at lines 5-6.

```dockerfile
# In the cpu target ENV block:
BACKEND=mock
```

The `gpu` target correctly keeps `BACKEND=gsplat`.

## Prerequisites

| Requirement | Purpose |
|-------------|---------|
| Docker | Build image + run Azurite + run processor |
| Python 3 + `azure-storage-blob` | Upload test videos, generate SAS, verify outputs |
| Test videos in `testdata/south_building_videos/` | Real multi-view imagery (run `scripts/e2e/01-download-testdata.sh`) |

## Step-by-Step: Docker Batch E2E

### 1. Build the CPU image

```bash
docker build --target cpu -t 3dgs-processor:cpu .
```

Verify the default BACKEND:
```bash
docker inspect 3dgs-processor:cpu --format '{{range .Config.Env}}{{println .}}{{end}}' | grep BACKEND
# Expected: BACKEND=mock
```

### 2. Create a Docker network

The processor container must reach Azurite by hostname (not `127.0.0.1`).

```bash
docker network create 3dgs-e2e-net
```

### 3. Start Azurite

```bash
docker run -d --rm --name azurite-e2e \
  --network 3dgs-e2e-net \
  -p 10000:10000 \
  mcr.microsoft.com/azure-storage/azurite \
  azurite-blob --blobHost 0.0.0.0 --blobPort 10000 --skipApiVersionCheck
```

Wait for it:
```bash
curl -s http://127.0.0.1:10000/ > /dev/null && echo "Azurite ready"
```

### 4. Upload test videos and generate SAS token

Use the existing `azurite_helper.py` (requires a Python venv with `azure-storage-blob`):

```bash
# Create venv if needed
python3 -m venv output/.e2e-venv
source output/.e2e-venv/bin/activate
pip install --quiet azure-storage-blob

# Create containers (input, output, processed, error) and upload videos
python3 scripts/e2e/azurite_helper.py setup testdata/south_building_videos "my_scene/"

# Generate SAS token
SAS_TOKEN=$(python3 scripts/e2e/azurite_helper.py sas)
```

### 5. Run the processor container in batch mode

**Critical:** Use `--network 3dgs-e2e-net` so the container can reach `azurite-e2e:10000`.

```bash
docker run --rm --name 3dgs-e2e-batch \
  --network 3dgs-e2e-net \
  -v /path/to/container-test/config.yaml:/config/config.yaml:ro \
  -e RUN_MODE=batch \
  -e AZURE_STORAGE_ACCOUNT=devstoreaccount1 \
  -e AZURE_STORAGE_ENDPOINT=http://azurite-e2e:10000/devstoreaccount1 \
  -e "AZURE_STORAGE_SAS_TOKEN=$SAS_TOKEN" \
  -e BATCH_INPUT_PREFIX=my_scene/ \
  -e BACKEND=mock \
  -e FORCE_CPU_BACKEND=1 \
  -e COLMAP_USE_CPU=1 \
  -e COLMAP_MATCHER=sequential \
  -e COLMAP_MAX_NUM_FEATURES=2048 \
  -e FRAME_RATE=2 \
  -e MIN_VIDEO_FRAMES=5 \
  -e MIN_VIDEO_DURATION=0.5 \
  -e MIN_RECONSTRUCTION_POINTS=100 \
  -e RECONSTRUCTION_BACKEND=colmap \
  -e MAX_RETRIES=1 \
  -e LOG_LEVEL=info \
  -e TEMP_PATH=/tmp/3dgs-work \
  3dgs-processor:cpu
```

The container will:
1. Download 3 MP4s from Azurite `input` container
2. Extract frames (FFmpeg), extract metadata (ffprobe)
3. Generate manifest, run COLMAP reconstruction (~2 min CPU)
4. Mock-train 3DGS model, export PLY + SPLAT
5. Upload outputs to Azurite `output` container
6. Move inputs to `processed` container
7. Exit with code 0

### 6. Verify outputs

```bash
python3 scripts/e2e/azurite_helper.py verify "my_scene/"
```

Expected output:
```
✅ PLY:          my_scene/my_scene.ply (42443 bytes)
✅ SPLAT:        my_scene/my_scene.splat (32000 bytes)
✅ manifest:     present
✅ processed:    3 input video(s) archived
✅ input:        cleaned (all blobs moved)
✅ error:        empty (no failures)
```

### 7. Cleanup

```bash
docker stop azurite-e2e
docker network rm 3dgs-e2e-net
```

## Key Environment Variables for Batch Mode

### Required

| Variable | Value | Purpose |
|----------|-------|---------|
| `RUN_MODE` | `batch` | Enables batch mode (SDK-based, no file watching) |
| `AZURE_STORAGE_ACCOUNT` | `devstoreaccount1` | Azurite well-known account name |
| `AZURE_STORAGE_ENDPOINT` | `http://azurite-e2e:10000/devstoreaccount1` | Azurite endpoint **by Docker hostname** |
| `AZURE_STORAGE_SAS_TOKEN` | *(from helper)* | SAS token for auth |
| `BATCH_INPUT_PREFIX` | `my_scene/` | Blob prefix identifying the job |

### Processing (CPU-safe)

| Variable | Value | Why |
|----------|-------|-----|
| `BACKEND` | `mock` | No GPU in CPU image |
| `COLMAP_USE_CPU` | `1` | Headless-safe, no OpenGL |
| `COLMAP_MATCHER` | `sequential` | Fast on CPU (~30s vs 30min for exhaustive) |
| `COLMAP_MAX_NUM_FEATURES` | `2048` | Limit SIFT features for speed |
| `FRAME_RATE` | `2` | ~50 frames total, enough for 1000+ COLMAP points |
| `RECONSTRUCTION_BACKEND` | `colmap` | Real COLMAP (not mock) |

### Container names (defaults)

| Variable | Default |
|----------|---------|
| `AZURE_BLOB_CONTAINER_INPUT` | `input` |
| `AZURE_BLOB_CONTAINER_OUTPUT` | `output` |
| `AZURE_BLOB_CONTAINER_PROCESSED` | `processed` |
| `AZURE_BLOB_CONTAINER_ERROR` | `error` |

## Config file mount

The container expects a YAML config at `CONFIG_PATH` (default: `/config/config.yaml`).
Mount the project's `container-test/config.yaml` (a **file**, not a directory):

```bash
-v /absolute/path/to/container-test/config.yaml:/config/config.yaml:ro
```

## Batch mode vs Watch mode (in Docker)

| Aspect | Batch Mode | Watch Mode |
|--------|-----------|------------|
| Storage | Azure SDK (direct HTTP) | BlobFuse2 or local bind mount |
| Detection | Explicit `BATCH_INPUT_PREFIX` | inotify + polling fallback |
| Lifecycle | Runs once → exits | Long-running daemon |
| Privileged | No | Yes (if BlobFuse2) |
| Docker network | Required (reach Azurite) | Not needed (bind mount) |
| inotify issues | N/A | Host events may not propagate |

**Recommendation:** Use **batch mode** for Docker-based E2E testing. It avoids
inotify propagation issues with bind mounts and doesn't require privileged containers.

## Common Failure Modes

### "Is a directory (os error 21)" on config
**Cause:** Mounting a directory (not a file) to `/config/config.yaml`.
**Fix:** Ensure the source path is a regular file: `stat container-test/config.yaml`

### Container can't reach Azurite
**Cause:** Not on the same Docker network; using `127.0.0.1` instead of hostname.
**Fix:** Both containers must be on the same `docker network`. Use the Azurite
container name (e.g., `azurite-e2e`) as the hostname in `AZURE_STORAGE_ENDPOINT`.

### "Reconstruction quality too low"
**Cause:** Too few frames or bad test data (synthetic videos won't work).
**Fix:** Use `testdata/south_building_videos/` (real imagery). Set `FRAME_RATE=2`.

### COLMAP timeout
**Cause:** Exhaustive matcher on CPU with many images.
**Fix:** `COLMAP_MATCHER=sequential` and `COLMAP_MAX_NUM_FEATURES=2048`.

## Authentication Methods (priority order)

1. **SAS Token** (`AZURE_STORAGE_SAS_TOKEN`) — used for Azurite and CI/CD
2. **Managed Identity** (`AZURE_USE_MANAGED_IDENTITY=true`) — production on Azure
3. **Azure CLI** (default) — local dev with `az login`

> Connection strings are **not supported** in batch mode.

## Performance Expectations (CPU-only, South Building dataset)

| Phase | Duration |
|-------|----------|
| Download 3 videos from Azurite | ~1s |
| FFmpeg frame extraction (51 frames) | ~2s |
| COLMAP feature extraction | ~40s |
| COLMAP sequential matching | ~40s |
| COLMAP sparse reconstruction | ~50s |
| Mock training + export | <1s |
| Upload outputs to Azurite | <1s |
| **Total** | **~2.5 min** |
