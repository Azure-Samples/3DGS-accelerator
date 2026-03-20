# Configuration Reference

The 3DGS Video Processor uses **two configuration sources**:

| Source | Purpose | File |
|--------|---------|------|
| **Environment variables** | Deployment settings: paths, timeouts, Azure, health checks | N/A (shell / container env) |
| **YAML config file** | Training hyperparameters: frame extraction, COLMAP, 3DGS training, export | `config.yaml` (see `config.example.yaml`) |

**Precedence rule:** Environment variables always win. If both the YAML file and an env var specify the same setting (e.g., `BACKEND` / `backend`), the env var value is used.

---

## Table of Contents

- [YAML Configuration (config.yaml)](#yaml-configuration-configyaml)
  - [Backend Selection](#backend-selection)
  - [Frame Extraction](#frame-extraction)
  - [COLMAP (Structure-from-Motion)](#colmap-structure-from-motion)
  - [3DGS Training](#3dgs-training)
  - [Export](#export)
- [Environment Variables](#environment-variables)
  - [Required Paths](#required-paths)
  - [Optional Paths](#optional-paths)
  - [Processing Settings](#processing-settings)
  - [Reconstruction Backend](#reconstruction-backend)
  - [Video Validation](#video-validation)
  - [Retry / Backoff](#retry--backoff)
  - [Health Check Server](#health-check-server)
  - [Logging](#logging)
  - [Azure Blob Storage](#azure-blob-storage)
  - [Azure Blob Containers (Blobfuse2)](#azure-blob-containers-blobfuse2)

---

## YAML Configuration (`config.yaml`)

The YAML file is loaded from the path specified by the `CONFIG_PATH` environment variable (default: `/config/config.yaml`). If the file does not exist, all settings fall back to their defaults. A copy is provided at `config.example.yaml` in the repository root.

Every field is optional — you only need to specify values you want to change from the defaults.

---

### Backend Selection

**Stage:** 3DGS Training (selects which Gaussian Splatting implementation runs the training step)

| YAML Key | Type | Default | Env Override |
|----------|------|---------|-------------|
| `backend` | string | `"auto"` ¹ | `BACKEND` |

**Valid values:**

| Value | Description |
|-------|-------------|
| `auto` | Auto-select based on GPU detection (recommended) |
| `gaussian-splatting` | Reference Python implementation; supports CPU and GPU (CUDA) |
| `gsplat` | Python/CUDA-optimized implementation; requires an NVIDIA GPU |
| `3dgs-cpp` | Experimental C++ implementation |
| `mock` | Fast mock backend for testing — no real training is performed |

**Auto-selection logic** (when `backend: auto`):

| Detected GPU | Backend selected |
|-------------|-----------------|
| NVIDIA (CUDA) | `gsplat` |
<!-- | Apple Silicon (Metal) | `gaussian-splatting` | -->
<!-- | AMD (ROCm) | `gaussian-splatting` | -->
| None | `mock` |

**Special env var:** Set `FORCE_CPU_BACKEND=1` to force the `mock` backend regardless of GPU detection.

> ¹ The YAML default in `config.example.yaml` is `auto`. The Rust code default (when no YAML file is present) is `"gaussian-splatting"`.

---

### Frame Extraction

**Stage:** Pre-processing — FFmpeg extracts individual frames from each input video before COLMAP and training.

| YAML Key | Type | Default | Env Override |
|----------|------|---------|-------------|
| `frame_extraction.rate` | float | `1.0` | `FRAME_RATE` |
| `frame_extraction.count` | integer or `null` | `null` | `FRAME_COUNT` |

**Behavior:**

- **`rate`** — Frames per second to extract. E.g., `1` = one frame per second, `2.5` = 2.5 frames per second.
- **`count`** — If set, extracts exactly this many frames (evenly spaced) from each video. **Overrides `rate`** when both are specified.
- When `count` is `null` (default), `rate` is used instead.

**Example — extract 200 evenly-spaced frames per video:**

```yaml
frame_extraction:
  count: 200
```

---

### COLMAP (Structure-from-Motion)

**Stage:** Reconstruction — COLMAP computes camera poses and sparse 3D point clouds from the extracted frames.

| YAML Key | Type | Default | Env Override |
|----------|------|---------|-------------|
| `colmap.matcher` | string | `"exhaustive"` | `COLMAP_MATCHER` |
| `colmap.camera_model` | string | `"OPENCV"` | — |

> **CPU-only mode:** Set `COLMAP_USE_CPU=1` to force COLMAP to use CPU for SIFT feature extraction and matching (passes `--SiftExtraction.use_gpu 0` and `--SiftMatching.use_gpu 0`). This is useful for headless servers without OpenGL or when the GPU should be reserved for 3DGS training. This setting is independent of `FORCE_CPU_BACKEND`, which only affects the 3DGS training backend.

#### `colmap.matcher`

Feature matching strategy that determines how COLMAP pairs images for finding correspondences.

| Value | Speed | Quality | Best For |
|-------|-------|---------|----------|
| `exhaustive` | Slowest | Best | Small to medium datasets (< 500 images); all image pairs are compared |
| `sequential` | Medium | Good | Video sequences with temporal ordering (frames are consecutive) |
| `vocab_tree` | Fastest | Good | Large datasets (> 500 images); requires a pre-built vocabulary file |

#### `colmap.camera_model`

Camera intrinsic model used during feature extraction and bundle adjustment.

| Value | Parameters | Best For |
|-------|-----------|----------|
| `SIMPLE_PINHOLE` | fx, cx, cy | Simple cameras with no lens distortion |
| `OPENCV` | fx, fy, cx, cy, k1, k2, p1, p2 | Most consumer cameras (handles radial + tangential distortion) |
| `FULL_OPENCV` | fx, fy, cx, cy, k1–k6, p1, p2 | Wide-angle / fisheye lenses with complex distortion |

> **Recommendation:** Use `OPENCV` unless you know your cameras are distortion-free (`SIMPLE_PINHOLE`) or have extreme distortion (`FULL_OPENCV`).

---

### 3DGS Training

**Stage:** 3DGS Training — these parameters control the Gaussian Splatting optimization loop (quality vs. speed trade-off).

| YAML Key | Type | Default | Env Override |
|----------|------|---------|-------------|
| `training.iterations` | integer | `30000` | — |
| `training.learning_rate` | float | `0.0025` | — |
| `training.densification_interval` | integer | `100` | — |
| `training.densification_start` | integer | `500` | — |
| `training.densification_stop` | integer | `15000` | — |
| `training.opacity_reset_interval` | integer | `3000` | — |

#### Parameter Details

| Parameter | Description | Guidance |
|-----------|-------------|----------|
| `iterations` | Total number of training iterations. More iterations = higher quality but longer training time. | 7,000 for quick preview; 30,000 for production quality; 50,000+ for maximum quality |
| `learning_rate` | Step size for the optimizer. Controls how aggressively Gaussians are updated each iteration. | Lower values (0.001) are more stable; higher values (0.005) converge faster but may overshoot |
| `densification_interval` | Number of iterations between densification checks (adding/splitting Gaussians to fill gaps). | Smaller values fill detail faster but increase Gaussian count more quickly |
| `densification_start` | Iteration at which densification begins. Allows initial coarse fitting before adding detail. | Increase if initial training is unstable |
| `densification_stop` | Iteration at which densification stops. After this, only position/color optimization continues. | Should be ≤ `iterations`. Keep well below total iterations for final refinement |
| `opacity_reset_interval` | Iterations between opacity resets. Periodically resetting opacity helps remove "floater" artifacts (semi-transparent Gaussians that don't contribute to the scene). | Lower values remove floaters more aggressively but may temporarily reduce quality |

**Presets:**

```yaml
# Fast preview (lower quality, quick results)
training:
  iterations: 7000
  densification_stop: 5000

# Production quality (default)
training:
  iterations: 30000

# Maximum quality (slow)
training:
  iterations: 50000
  densification_stop: 25000
  opacity_reset_interval: 5000
```

---

### Export

**Stage:** Post-processing — converts the trained 3DGS model into output file formats.

| YAML Key | Type | Default | Env Override |
|----------|------|---------|-------------|
| `export.formats` | list of strings | `["ply", "splat"]` | — |
| `export.ply_precision` | string | `"float32"` | — |

#### `export.formats`

Output file formats to generate. At least one format must be specified.

| Format | Description | Use Case |
|--------|-------------|----------|
| `ply` | Standard 3D point cloud format (PLY). Widely supported by 3D tools. | Archival, post-processing in MeshLab/Blender/CloudCompare |
| `splat` | Web-optimized format for real-time Gaussian Splatting rendering in browsers. | Web viewers, real-time demos |

#### `export.ply_precision`

Numeric precision for PLY output files.

| Value | Description |
|-------|-------------|
| `float32` | 32-bit floating point. Higher precision, larger file size. |
| `float16` | 16-bit floating point. ~50% smaller files with minimal quality loss. |

---

## Environment Variables

These control deployment, runtime behavior, and infrastructure. They are **not** set in the YAML file.

---

### Required Paths

These **must** be set. The processor will fail to start without them.

| Variable | Type | Description |
|----------|------|-------------|
| `INPUT_PATH` | path | Directory to watch for new video folders. New subfolders trigger processing jobs. |
| `OUTPUT_PATH` | path | Directory where 3DGS output files (PLY, SPLAT) are written. |
| `PROCESSED_PATH` | path | Directory where successfully processed input folders are moved. |
| `ERROR_PATH` | path | Directory where failed input folders are moved after exhausting retries. |

> All paths are auto-created at startup if they don't exist.

---

### Optional Paths

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `TEMP_PATH` | path | `/tmp/3dgs-work` | Working directory for intermediate files (extracted frames, COLMAP workspace). Cleaned up after each job. |
| `CONFIG_PATH` | path | `/config/config.yaml` | Path to the YAML configuration file. If the file doesn't exist, all YAML settings use defaults. |

---

### Processing Settings

| Variable | Type | Default | Stage | Description |
|----------|------|---------|-------|-------------|
| `BACKEND` | string | `"gaussian-splatting"` | 3DGS Training | 3DGS backend to use. Overrides the `backend` field in the YAML file. Values: `auto`, `gaussian-splatting`, `gsplat`, `3dgs-cpp`, `mock`. |
| `FORCE_CPU_BACKEND` | flag | unset | 3DGS Training | If set to any value (e.g., `1`), forces the `mock` backend regardless of GPU detection or `BACKEND` setting. |
| `COLMAP_USE_CPU` | flag | unset | Reconstruction | If set to any value (e.g., `1`), forces COLMAP to use CPU-only mode by passing `--SiftExtraction.use_gpu 0` and `--SiftMatching.use_gpu 0`. Makes COLMAP headless-safe (no OpenGL/display required). Independent of `FORCE_CPU_BACKEND` and GPU detection for the 3DGS training backend. |
| `FRAME_RATE` | float | — | Frame Extraction | Overrides `frame_extraction.rate` from the YAML file. |
| `FRAME_COUNT` | integer | — | Frame Extraction | Overrides `frame_extraction.count` from the YAML file. |
| `UPLOAD_STABILITY_TIMEOUT_SECS` | integer | `60` | File Watcher | Seconds to wait with no new file events before considering an upload "stable" and starting processing. Prevents processing incomplete uploads. |
| `POLL_INTERVAL_SECS` | integer | `10` | File Watcher | Seconds between polling cycles when checking for new folders in `INPUT_PATH`. |
| `MAX_RETRIES` | integer | `3` | Job Processing | Maximum retry attempts for transient failures (not counting the initial attempt). Permanent errors (validation, config) are never retried. |
| `RETENTION_DAYS` | integer | `30` | Cleanup | Number of days to keep folders in `PROCESSED_PATH` and `ERROR_PATH` before automatic deletion. |

---

### Reconstruction Backend

| Variable | Type | Default | Stage | Description |
|----------|------|---------|-------|-------------|
| `RECONSTRUCTION_BACKEND` | string | `"colmap"` | Reconstruction | Which reconstruction backend computes camera poses. |

**Available reconstruction backends:**

| Value | Description |
|-------|-------------|
| `colmap` | COLMAP Structure-from-Motion (primary, most tested) |
| `nerfstudio` | Nerfstudio `transforms.json` format |
| `precalibrated` | Use pre-existing camera calibration data (known poses) |

---

### Video Validation

**Stage:** Pre-processing — videos are validated before frame extraction begins.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `MIN_VIDEO_WIDTH` | integer | `640` | Minimum video width in pixels. Videos below this are rejected. |
| `MIN_VIDEO_HEIGHT` | integer | `480` | Minimum video height in pixels. Videos below this are rejected. |
| `MIN_VIDEO_FRAMES` | integer | `30` | Minimum number of frames required. Short clips are rejected. |
| `MIN_VIDEO_DURATION` | float | `1.0` | Minimum video duration in seconds. |

---

### Retry / Backoff

**Stage:** Job Processing — controls exponential backoff when transient errors occur.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `MAX_RETRIES` | integer | `3` | Maximum retry attempts for transient failures. |
| `RETRY_BASE_DELAY_SECS` | integer | `2` | Base delay in seconds. Actual delay = `base × 2^(attempt-1)`. |
| `RETRY_MAX_DELAY_SECS` | integer | `60` | Maximum delay cap in seconds (prevents unbounded backoff). |

**Backoff schedule** (with defaults):

| Attempt | Delay |
|---------|-------|
| 1 (first retry) | 2 s |
| 2 | 4 s |
| 3 | 8 s |
| 4+ | capped at 60 s |

---

### Health Check Server

**Stage:** Runtime — optional HTTP health endpoint for container orchestration (Kubernetes liveness/readiness probes).

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `HEALTH_CHECK_ENABLED` | boolean | `false` | Set to `true` to start the HTTP health check server. |
| `HEALTH_CHECK_PORT` | integer | `8080` | TCP port for the health check endpoint. |

When enabled, exposes `GET /health` which returns the current processor state (idle, processing, error).

---

### Logging

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `LOG_LEVEL` | string | `"info"` | Log verbosity level. Values: `trace`, `debug`, `info`, `warn`, `error`. |
| `RUST_LOG` | string | — | Standard Rust tracing filter. `LOG_LEVEL` takes priority if both are set. |

---

### Azure Blob Storage

**Stage:** Startup — optional Azure integration for mounting Blob containers as local filesystems via Blobfuse2.

Azure configuration is only activated when at least one of `AZURE_STORAGE_CONNECTION_STRING`, `AZURE_STORAGE_ACCOUNT`, or `AZURE_USE_MANAGED_IDENTITY` is set.

#### Authentication (choose one method)

| Variable | Type | Description |
|----------|------|-------------|
| `AZURE_STORAGE_CONNECTION_STRING` | string | Full connection string (includes account name + key). Simplest option. |
| `AZURE_STORAGE_ACCOUNT` + `AZURE_STORAGE_SAS_TOKEN` | string | Account name + SAS token. Use for scoped, time-limited access. |
| `AZURE_STORAGE_ACCOUNT` + `AZURE_USE_MANAGED_IDENTITY=true` | string + bool | Account name + Azure Managed Identity. Recommended for production (no secrets to manage). |

> ⚠️ **Security:** Connection strings and SAS tokens are credentials. Never log them. The processor redacts them in log output.

---

### Azure Blob Containers (Blobfuse2)

These specify which Blob containers to mount and where. The container is mounted to the corresponding path variable (`INPUT_PATH`, etc.) via Blobfuse2 FUSE.

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `AZURE_BLOB_CONTAINER_INPUT` | string | `"input"` | Blob container name for input videos. |
| `AZURE_BLOB_CONTAINER_OUTPUT` | string | `"output"` | Blob container name for output 3DGS files. |
| `AZURE_BLOB_CONTAINER_PROCESSED` | string | `"processed"` | Blob container name for processed inputs. |
| `AZURE_BLOB_CONTAINER_ERROR` | string | `"error"` | Blob container name for failed inputs. |

> ⚠️ **Privileged mode required:** Blobfuse2 requires FUSE access. The container must run with `--privileged` or appropriate device/capability settings.

---

## Full YAML Example

```yaml
# Backend: auto-detect GPU or specify explicitly
backend: auto

# Frame extraction from input videos
frame_extraction:
  rate: 1                    # Frames per second (used when count is null)
  count: null                # Total frames per video (overrides rate)

# COLMAP Structure-from-Motion
colmap:
  matcher: exhaustive        # exhaustive | sequential | vocab_tree
  camera_model: OPENCV       # SIMPLE_PINHOLE | OPENCV | FULL_OPENCV

# 3DGS Training parameters
training:
  iterations: 30000
  learning_rate: 0.0025
  densification_interval: 100
  densification_start: 500
  densification_stop: 15000
  opacity_reset_interval: 3000

# Output export formats
export:
  formats:
    - ply
    - splat
  ply_precision: float32     # float32 | float16
```

---

## Full Environment Variable Example

```bash
# Required paths
export INPUT_PATH=/data/input
export OUTPUT_PATH=/data/output
export PROCESSED_PATH=/data/processed
export ERROR_PATH=/data/error

# Optional paths
export TEMP_PATH=/tmp/3dgs-work
export CONFIG_PATH=/config/config.yaml

# Processing
export BACKEND=auto
export RECONSTRUCTION_BACKEND=colmap
export UPLOAD_STABILITY_TIMEOUT_SECS=60
export POLL_INTERVAL_SECS=10
export MAX_RETRIES=3
export RETENTION_DAYS=30

# Frame extraction overrides
export FRAME_RATE=2.0
# export FRAME_COUNT=200   # Uncomment to override rate

# Video validation
export MIN_VIDEO_WIDTH=640
export MIN_VIDEO_HEIGHT=480
export MIN_VIDEO_FRAMES=30
export MIN_VIDEO_DURATION=1.0

# Retry backoff
export RETRY_BASE_DELAY_SECS=2
export RETRY_MAX_DELAY_SECS=60

# Health check
export HEALTH_CHECK_ENABLED=true
export HEALTH_CHECK_PORT=8080

# Logging
export LOG_LEVEL=info

# Azure (choose one auth method)
export AZURE_STORAGE_CONNECTION_STRING="DefaultEndpointsProtocol=https;AccountName=..."
# OR
# export AZURE_STORAGE_ACCOUNT=myaccount
# export AZURE_STORAGE_SAS_TOKEN="sv=2021-06-08&..."
# OR
# export AZURE_STORAGE_ACCOUNT=myaccount
# export AZURE_USE_MANAGED_IDENTITY=true

# Azure containers
export AZURE_BLOB_CONTAINER_INPUT=input
export AZURE_BLOB_CONTAINER_OUTPUT=output
export AZURE_BLOB_CONTAINER_PROCESSED=processed
export AZURE_BLOB_CONTAINER_ERROR=error
```
