# User Guide: 3DGS Video Processor

Complete guide for configuring and using the 3DGS Video Processor.

## Table of Contents

* [Quick Start (Recommended)](#quick-start-recommended)
* [Configuration](#configuration)
* [Input Preparation](#input-preparation)
* [Running the Service](#running-the-service)
* [Output Format](#output-format)
* [Advanced Usage](#advanced-usage)

## Quick Start (Recommended)

The fastest way to get the full pipeline running is with the **numbered E2E scripts** in `scripts/e2e/`. These handle dependency installation, test data download, building, and running an end-to-end pipeline test — no GPU or Docker required.

### Prerequisites

* Ubuntu 24.04 (or compatible Debian-based system) with `sudo` access
* [Rust toolchain](https://rustup.rs/) installed (`cargo`, `rustc`)

### Run the Scripts

From the project root, run each script in order:

```bash
# Step 1: Install system dependencies (ffmpeg, colmap, unzip)
./scripts/e2e/00-install-deps.sh

# Step 2: Download COLMAP South Building dataset & create 3 test videos
./scripts/e2e/01-download-testdata.sh

# Step 3: Build the Rust binary in release mode
./scripts/e2e/02-build.sh

# Step 4: Clean output directories (ensures a fresh starting state)
./scripts/e2e/03-cleanup.sh

# Step 5: Run the full E2E pipeline test
./scripts/e2e/04-run-e2e.sh --mode file
```

### What Happens

1. **00-install-deps.sh** — Installs `ffmpeg`, `colmap`, and `unzip` via apt
2. **01-download-testdata.sh** — Downloads 128 real multi-view images (~20 MB), creates 3 test videos at 1280×960
3. **02-build.sh** — Runs `cargo build --release`, outputs `target/release/3dgs-processor`
4. **03-cleanup.sh** — Wipes `./output/data/{input,processed,error,output}` and `/tmp/3dgs-work`
5. **04-run-e2e.sh** — Starts the processor in watch mode, copies test videos to trigger a job, waits for COLMAP reconstruction + mock training, verifies output

### Expected Output

```
📊 Output verification:
  ✅ PLY file(s):      1 (44K)
  ✅ SPLAT file(s):    1 (32K)
  ✅ manifest.json:    present

🎉 ALL E2E TESTS PASSED!
```

Output files in `./output/data/output/`:
* `my_scene.ply` — PLY point cloud (mock-generated synthetic geometry)
* `my_scene.splat` — SPLAT file (mock-generated, valid 32-byte/gaussian format)
* `manifest.json` — Real video metadata from ffprobe

The input folder moves to `./output/data/processed/my_scene` on success.

### E2E Modes

```bash
./scripts/e2e/04-run-e2e.sh --mode file     # File/watch mode (local directories)
./scripts/e2e/04-run-e2e.sh --mode batch    # Batch mode (Azurite Azure emulator, requires Docker)
./scripts/e2e/04-run-e2e.sh                  # Both modes
./scripts/e2e/04-run-e2e.sh --timeout 600   # Custom timeout in seconds
```

> **Note**: The E2E scripts use `BACKEND=mock` (no GPU). Real 3DGS training requires a CUDA GPU and `BACKEND=gsplat` or `BACKEND=gaussian-splatting`.

## Configuration

### Environment Variables

All runtime configuration is done through environment variables.

#### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `INPUT_PATH` | Directory to watch for new videos | `/data/input` |
| `OUTPUT_PATH` | Directory for processed outputs | `/data/output` |
| `PROCESSED_PATH` | Archive directory for completed jobs | `/data/processed` |
| `ERROR_PATH` | Quarantine directory for failed jobs | `/data/error` |
| `BACKEND` | 3DGS backend to use | `gaussian-splatting`, `gsplat`, or `3dgs-cpp` |

#### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STABILITY_TIMEOUT_SECS` | `30` | Seconds to wait for upload completion |
| `MAX_RETRIES` | `3` | Maximum retry attempts for failed jobs |
| `RETRY_BASE_DELAY_SECS` | `2` | Base delay for exponential backoff (seconds) |
| `RETRY_MAX_DELAY_SECS` | `60` | Maximum delay cap for retries (seconds) |
| `RETENTION_DAYS` | `30` | Days to keep processed data before cleanup |
| `MIN_DISK_SPACE_GB` | `10` | Minimum free disk space (GB) before pausing |
| `CONFIG_FILE` | `config.yaml` | Path to YAML configuration file |
| `LOG_LEVEL` | `info` | Logging level: `trace`, `debug`, `info`, `warn`, `error` |

#### Video Validation Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MIN_VIDEO_WIDTH` | `640` | Minimum video width in pixels |
| `MIN_VIDEO_HEIGHT` | `480` | Minimum video height in pixels |
| `MIN_VIDEO_FRAMES` | `30` | Minimum frame count required |
| `MIN_VIDEO_DURATION` | `1.0` | Minimum video duration in seconds |

#### Azure Blob Storage Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `AZURE_STORAGE_CONNECTION_STRING` | Connection string | Yes (or SAS/MI) |
| `AZURE_STORAGE_SAS_TOKEN` | SAS token | Alternative to connection string |
| `AZURE_STORAGE_ACCOUNT` | Account name (for Managed Identity) | Alternative auth method |
| `AZURE_CONTAINER_NAME` | Blob container name | Yes for Azure mode |

### YAML Configuration

Optional `config.yaml` for 3DGS training hyperparameters only:

```yaml
training:
  iterations: 30000         # Training iterations
  learning_rate: 0.0002    # Initial learning rate
  position_lr: 0.00016     # Position learning rate
  feature_lr: 0.0025       # Feature learning rate
  opacity_lr: 0.05         # Opacity learning rate
  scaling_lr: 0.005        # Scaling learning rate
  rotation_lr: 0.001       # Rotation learning rate
  
  densification_interval: 100   # Steps between densification
  opacity_reset_interval: 3000  # Steps between opacity resets
  densify_from_iter: 500        # Start densification iteration
  densify_until_iter: 15000     # Stop densification iteration
  densify_grad_threshold: 0.0002  # Gradient threshold for densification
  
  export_formats:
    - ply
    - splat
```

**Note**: Environment variables always override YAML settings.

## Input Preparation

### Directory Structure

Create a job directory containing multiple video files:

```
input/
└── scene_001/               # Job folder
    ├── view1.mp4           # Video from angle 1
    ├── view2.mp4           # Video from angle 2
    └── view3.mp4           # Video from angle 3 (optional)
```

### Video Requirements

* **Format**: MP4, MOV, AVI, MKV, WebM (any FFmpeg-supported format)
* **Resolution**: Minimum configurable via `MIN_VIDEO_WIDTH`/`MIN_VIDEO_HEIGHT` (default: 640x480, 1920x1080 recommended)
* **Frame Count**: Minimum configurable via `MIN_VIDEO_FRAMES` (default: 30 frames)
* **Duration**: Minimum configurable via `MIN_VIDEO_DURATION` (default: 1 second, 5-60 seconds recommended)
* **Frame Rate**: 24-60 fps
* **Camera Overlap**: Videos should show the same scene from different angles
* **Lighting**: Consistent lighting across all videos
* **Motion**: Smooth camera movement (no sudden jerks)

**Note**: Videos failing validation checks will be rejected and moved to `ERROR_PATH` with detailed error messages in the manifest.

### Multi-View Guidelines

For best 3DGS reconstruction quality:

* **Minimum 2 videos** (3+ recommended)
* **50-70% overlap** between viewpoints
* *Capture the full object/scene** from all angles
* **Consistent settings** (exposure, white balance, focus)
* **Stable mounting** or smooth handheld capture

## Running the Service

### E2E Scripts (Recommended for First Run)

See [Quick Start](#quick-start-recommended) above. The `scripts/e2e/` scripts are the easiest way to run the full pipeline.

### Docker Compose

<details>
<summary>Docker Compose setup</summary>

Create `docker-compose.yml`:

```yaml
version: '3.8'
services:
  3dgs-processor:
    image: 3dgs-processor:latest
    container_name: 3dgs-processor
    restart: unless-stopped
    volumes:
      - ./input:/data/input
      - ./output:/data/output
      - ./processed:/data/processed
      - ./error:/data/error
      - ./config.yaml:/app/config.yaml:ro
    environment:
      INPUT_PATH: /data/input
      OUTPUT_PATH: /data/output
      PROCESSED_PATH: /data/processed
      ERROR_PATH: /data/error
      BACKEND: gaussian-splatting
      LOG_LEVEL: info
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

Run:

```bash
docker-compose up -d
docker-compose logs -f
```

</details>

### Direct Docker Run

<details>
<summary>Direct Docker run</summary>

```bash
docker run -d \
  --name 3dgs-processor \
  -v $(pwd)/input:/data/input \
  -v $(pwd)/output:/data/output \
  -v $(pwd)/processed:/data/processed \
  -v $(pwd)/error:/data/error \
  -e INPUT_PATH=/data/input \
  -e OUTPUT_PATH=/data/output \
  -e PROCESSED_PATH=/data/processed \
  -e ERROR_PATH=/data/error \
  -e BACKEND=gaussian-splatting \
  3dgs-processor:latest
```

</details>

### Native Binary

<details>
<summary>Native binary setup</summary>

```bash
# Set environment variables
export INPUT_PATH=./input
export OUTPUT_PATH=./output
export PROCESSED_PATH=./processed
export ERROR_PATH=./error
export BACKEND=gaussian-splatting

# Run
./target/release/3dgs-processor
```

</details>

## Output Format

### Directory Structure

Processed outputs are written to `OUTPUT_PATH/JOB_NAME/`:

```
output/
└── scene_001/
    ├── manifest.json       # Job metadata
    ├── model-TIMESTAMP.ply # Point cloud model
    └── model-TIMESTAMP.splat  # Web-optimized format
```

### Manifest JSON

Example `manifest.json`:

```json
{
  "job_id": "scene_001",
  "processing_timestamp": "2024-01-01T12:00:00Z",
  "videos": [
    {
      "filename": "view1.mp4",
      "frame_count": 150,
      "resolution": "1920x1080",
      "fps": 30.0,
      "duration_secs": 5.0,
      "frames": [/* frame metadata */]
    }
  ],
  "camera_intrinsics": {
    "model": "OPENCV",
    "fx": 1500.0,
    "fy": 1500.0,
    "cx": 960.0,
    "cy": 540.0
  }
}
```

### Model Files

* **PLY**: Standard 3D point cloud format (viewable in MeshLab, CloudCompare)
* **SPLAT**: Web-optimized format (viewable in browser via three.js)

## Advanced Usage

### Backend Selection

Choose backend based on your needs:

| Backend | Speed | Quality | GPU Required | Best For |
|---------|-------|---------|--------------|----------|
| `gaussian-splatting` | Medium | High | Yes | Reference implementation |
| `gsplat` | Fast | High | Yes | Production (optimized) |
| `3dgs-cpp` | Fast | Medium | No | CPU-only environments |

### Retry Logic

Failed jobs are automatically retried up to `MAX_RETRIES` times with configurable exponential backoff.

**Configuration:**

* `MAX_RETRIES`: Maximum number of retry attempts (default: 3)
* `RETRY_BASE_DELAY_SECS`: Base delay for exponential backoff (default: 2 seconds)
* `RETRY_MAX_DELAY_SECS`: Maximum delay cap (default: 60 seconds)

**Retry Delays (with default settings):**

* Retry 1: 2 seconds
* Retry 2: 4 seconds
* Retry 3: 8 seconds
* Retry 4+: Doubles each time, capped at 60 seconds

**Error Classification:**

The system distinguishes between retryable and non-retryable errors:

* **Retryable** (transient): Network errors, disk space issues, temporary failures
* **Non-retryable** (permanent): Validation errors (bad input), configuration errors

Non-retryable errors skip retries and move directly to `ERROR_PATH`.

After max retries, the job folder moves to `ERROR_PATH`.

### Disk Space Management

The system monitors disk space and takes automatic action:

**Thresholds:**

* **Warning (20% free)**: Logs warning messages
* **Critical (10% free)**: Triggers automatic cleanup of oldest folders

**Automatic Cleanup:**

When disk space drops below 10%:

1. System scans `PROCESSED_PATH` and `ERROR_PATH`
2. Deletes oldest folders first (by modification time)
3. Continues until space reaches 20% free

**Retention Policy:**

In addition to space-based cleanup, folders older than `RETENTION_DAYS` (default: 30) are automatically deleted during scheduled cleanup (runs every 24 hours).

### Graceful Shutdown

Stop the service cleanly:

```bash
docker stop 3dgs-processor  # Sends SIGTERM
```

The service will:

1. Stop accepting new jobs
2. Complete current processing
3. Save state and clean up temporary files
4. Exit (typically within 30 seconds)

### Progress Monitoring

The processor tracks job progress through 8 stages and saves checkpoints for restart resilience.

#### Enable Health Endpoint

```bash
docker run -d \
  -e HEALTH_CHECK_ENABLED=true \
  -e HEALTH_CHECK_PORT=8080 \
  -p 8080:8080 \
  3dgs-processor:latest
```

#### Query Progress

```bash
# Check current job status
curl http://localhost:8080/health | jq .

# Example response:
{
  "state": "processing",
  "last_update": "2026-02-24T12:30:00Z",
  "current_job": {
    "job_id": "scene-001",
    "stage": "Training",
    "progress_percentage": 62.5,
    "video_count": 3,
    "total_frames": 450,
    "started_at": "2026-02-24T12:00:00Z"
  }
}
```

#### Checkpoint Resumption

Jobs automatically resume from the last checkpoint after restarts:

```bash
# Job fails or container restarts
docker restart 3dgs-processor

# Processor automatically resumes from last completed stage
docker logs 3dgs-processor | grep "Resuming from checkpoint"
```

Checkpoints are stored in `{OUTPUT_PATH}/{job_id}/.checkpoint.json`.

For detailed progress tracking documentation, see [PROGRESS_TRACKING.md](PROGRESS_TRACKING.md).

## Viewing Outputs

### PLY Files

Use MeshLab, CloudCompare, or Blender:

```bash
open output/scene_001/model-*.ply  # macOS
meshlab output/scene_001/model-*.ply  # Linux
```


### PLY Files

Web Viewers:
* [TRELLIS 3D AI PLY viewer](https://trellis3d.co/online-viewer/ply)


### SPLAT Files

Use web viewers:
* [antimatter15.com/splat](https://antimatter15.com/splat/)
* [playcanvas.com/supersplat](https://playcanvas.com/supersplat)

Drag and drop `.splat` file into the viewer.
