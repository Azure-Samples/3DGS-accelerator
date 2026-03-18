---
applyTo: 'scripts/e2e/**, tests/e2e/**, **/e2e*, **/*test*'
description: 'E2E testing setup, configuration, and troubleshooting for the 3DGS video processor pipeline'
maturity: stable
---

# E2E Testing Instructions for 3DGS Video Processor

## When to apply
This instruction applies when working on E2E tests, integration tests, test scripts,
or debugging pipeline issues in this project.

## E2E Test Infrastructure

### Numbered scripts in `scripts/e2e/`
| Script | Purpose |
|--------|---------|
| `00-install-deps.sh` | Install ffmpeg + colmap via `sudo apt install` (Ubuntu 24.04) |
| `01-download-testdata.sh` | Download COLMAP South Building dataset (128 images), create 3 test videos at 1280×960 |
| `02-build.sh` | `cargo build --release` |
| `03-cleanup.sh` | Wipe `./output/data/{input,processed,error,output}` and `/tmp/3dgs-work` |
| `04-run-e2e.sh` | Full orchestration: start processor → copy videos → wait for output → verify PLY/SPLAT/manifest → shutdown |

### Quick run
```bash
./scripts/e2e/04-run-e2e.sh          # full E2E (~3 min on CPU)
./scripts/e2e/04-run-e2e.sh --timeout 600  # custom timeout
```

## Test Data

### Source: COLMAP South Building dataset
- 128 multi-view images of UNC Chapel Hill's South Building
- Downloaded from: `https://github.com/colmap/colmap/releases/download/3.11.1/south-building.zip`
- Stored in: `testdata/south_building/images/` (raw images)
- Converted to: `testdata/south_building_videos/view{1,2,3}.mp4` (1280×960, 5fps, ~43 frames each)

### Why NOT the sample_scene videos
The `testdata/sample_scene/view*.mp4` files are synthetic FFmpeg test patterns (hue-shifted).
They do **not** contain real 3D scene imagery. COLMAP cannot produce the minimum 1000 3D points
required by `src/reconstruction/backend.rs` (`total_points < 1000` check).

## Pipeline Steps (what actually runs)

The processor executes an 8-step pipeline for each job. In the E2E test with `BACKEND=mock`,
steps 1–5 run **real tools**, while steps 6–8 use the **mock backend** (no GPU needed).

| Step | Name | What runs | Real or Mock? | Code |
|------|------|-----------|---------------|------|
| 1 | **Validate** | Discover `.mp4` files in the input folder, check min frames/duration | ✅ Real | `src/processor/job.rs` |
| 2 | **Extract frames** | FFmpeg extracts JPEG frames at `FRAME_RATE` fps | ✅ Real (ffmpeg) | `src/extractors/ffmpeg.rs` |
| 3 | **Extract metadata** | ffprobe reads resolution, duration, codec info per video | ✅ Real (ffprobe) | `src/extractors/metadata.rs` |
| 4 | **Generate manifest** | Write `manifest.json` with video metadata and frame paths | ✅ Real | `src/processor/job.rs` |
| 5 | **Reconstruction** | COLMAP: feature extraction → sequential matching → sparse mapping. Produces real 3D points + camera poses | ✅ Real (colmap) | `src/colmap/runner.rs` |
| 6 | **Train 3DGS model** | Mock: sleeps 100ms, writes fake checkpoint JSON. Real backends (`gsplat`, `gaussian-splatting`) require a CUDA GPU | ❌ Mock | `src/backends/mock.rs` |
| 7 | **Export PLY** | Mock: writes ASCII PLY with 1,000 synthetic vertices (evenly spaced grid, not real scene geometry) | ❌ Mock | `src/backends/mock.rs` |
| 8 | **Export SPLAT** | Mock: writes 32KB binary with 1,000 synthetic 32-byte Gaussian records (valid format, not real scene data) | ❌ Mock | `src/backends/mock.rs` |

### What the mock outputs contain
- **PLY**: Structurally valid ASCII PLY file, but vertices are a synthetic grid — not derived from the actual COLMAP reconstruction
- **SPLAT**: Structurally valid `.splat` file (32 bytes/gaussian: position + scale + RGBA + rotation quaternion), but also synthetic data
- **manifest.json**: Real metadata from the actual videos (resolution, duration, frame count, codec)
- **COLMAP output**: Real sparse point cloud and camera poses are produced in `/tmp/3dgs-work/reconstruction/output/` but the mock backend does not use them

### To get real PLY/SPLAT output
Replace `BACKEND=mock` with a real backend. This requires a CUDA GPU:
- `BACKEND=gsplat` — Python-based gsplat training (needs `gsplat` + PyTorch + CUDA)
- `BACKEND=gaussian-splatting` — Original 3DGS implementation
- `BACKEND=3dgs-cpp` — C++ implementation

## Pipeline Configuration for E2E

### Required environment variables
```bash
INPUT_PATH=./output/data/input
OUTPUT_PATH=./output/data/output
PROCESSED_PATH=./output/data/processed
ERROR_PATH=./output/data/error
BACKEND=mock                    # No GPU required
FORCE_CPU_BACKEND=1
COLMAP_USE_CPU=1                # Force COLMAP to CPU-only (headless-safe)
RECONSTRUCTION_BACKEND=colmap   # Real COLMAP
COLMAP_MATCHER=sequential       # Much faster than exhaustive on CPU
COLMAP_MAX_NUM_FEATURES=2048    # Limit features for speed
FRAME_RATE=2                    # 2 fps extraction (balances speed vs point count)
UPLOAD_STABILITY_TIMEOUT_SECS=5 # Short for testing
POLL_INTERVAL_SECS=2            # Short for testing
MAX_RETRIES=1
MIN_VIDEO_FRAMES=5              # Relaxed for test videos
MIN_VIDEO_DURATION=0.5
```

### Triggering a job
```bash
mkdir -p ./output/data/input/my_scene
cp testdata/south_building_videos/view*.mp4 ./output/data/input/my_scene/
```

### Expected outputs in `./output/data/output/`
- `my_scene.ply` — PLY point cloud (**mock-generated synthetic geometry**, not real scene data)
- `my_scene.splat` — SPLAT file (**mock-generated**, valid 32-byte/gaussian format but synthetic)
- `manifest.json` — Video metadata manifest (**real** — actual video metadata from ffprobe)
- `.checkpoint.json` — Processing checkpoint (pipeline progress tracking)

### After success
- Input folder moves to `./output/data/processed/my_scene`
- On failure, moves to `./output/data/error/my_scene`

## Key Performance Constraints (CPU-only)

| Setting | Why |
|---------|-----|
| `COLMAP_MATCHER=sequential` | Exhaustive matching on 26+ images at 1280×960 takes 30+ minutes on CPU; sequential takes ~30 seconds |
| `COLMAP_MAX_NUM_FEATURES=2048` | Limits SIFT features per image, speeds up matching |
| `FRAME_RATE=2` | Extracts ~50 frames total (enough for 1000+ COLMAP points); higher rates slow down COLMAP |
| Video resolution 1280×960 | Original dataset is 3072×2304; downscaled in video creation for COLMAP speed |

## Common Failure Modes

### "Reconstruction quality too low: only N points (minimum 1000 required)"
- **Cause:** Too few frames or poor overlap between views
- **Fix:** Increase `FRAME_RATE` (e.g., from 1 to 2 or 3) to extract more frames
- **Check:** `src/reconstruction/backend.rs` line 51 — `total_points < 1000`

### COLMAP matching timeout
- **Cause:** Too many high-res images with exhaustive matcher
- **Fix:** Set `COLMAP_MATCHER=sequential` and `COLMAP_MAX_NUM_FEATURES=2048`

### "FRAME_RATE env var has no effect"
- **Fixed in:** `src/extractors/ffmpeg.rs` — `ExtractionOptions::from_env_config()` now reads env vars
- **Previously:** Function name was misleading; it ignored env vars entirely

## System Dependencies (Ubuntu 24.04)
```bash
sudo apt-get install -y ffmpeg colmap unzip
```
- FFmpeg 6.1.1 (frame extraction + ffprobe metadata)
- COLMAP 3.9.1 (Structure-from-Motion, CPU-only, no CUDA)

## Testing Rules

- **No GPU required** — use `BACKEND=mock` and `FORCE_CPU_BACKEND=1`
- **No container required** — run natively with system-installed ffmpeg/colmap
- **No git submodules** — test data downloaded as zip, not cloned
- **Clean before each run** — always run `03-cleanup.sh` first (or let `04-run-e2e.sh` do it)
- **Idempotent** — scripts detect existing downloads/builds and skip them
