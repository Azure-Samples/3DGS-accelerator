# Testing with Tanks and Temples Dataset

This guide explains how to test the 3DGS Video Processor with the public [Tanks and Temples](https://www.tanksandtemples.org/) benchmark dataset.

## Overview

**Tanks and Temples** is a comprehensive benchmark for image-based 3D reconstruction that includes:

- High-quality multi-view images
- Camera poses and intrinsics
- Ground truth 3D models for evaluation
- Both outdoor and indoor scenes

## Why Use Python Script vs. Full Rust Processor?

**TL;DR**: Tanks and Temples provides **pre-processed images and COLMAP data**, so we test the training backend directly.

### What Each Tool Does

| Component | Input | Processing | Output |
|-----------|-------|------------|--------|
| **Full Rust Processor** | Video files (.mp4) | FFmpeg extraction → COLMAP reconstruction → Training → Export | .ply, .splat |
| **Python Training Script** | Pre-extracted images + COLMAP data | Training → Export | .ply, .splat |

### Tanks and Temples Dataset Structure

Tanks and Temples provides:

```
barn/
├── images/              ✅ Already extracted (no videos)
│   ├── 0000.jpg
│   └── ...
└── colmap/sparse/0/     ✅ Already reconstructed (COLMAP done)
    ├── cameras.bin
    ├── images.bin
    └── points3D.bin
```

Since **frames are already extracted** and **COLMAP reconstruction is already done**, we:

- ✅ Use the Python script to **test training quality directly**
- ✅ Skip redundant FFmpeg extraction (no videos to extract)
- ✅ Skip redundant COLMAP (reconstruction already computed)

### When to Use Each Approach

**Use Python Script** (what we do for Tanks and Temples):

- ✅ Testing with pre-processed datasets (Tanks and Temples, Mip-NeRF 360)
- ✅ Benchmarking training speed and quality
- ✅ Iterating on training hyperparameters
- ✅ Comparing against published papers (apples-to-apples)

**Use Full Rust Processor** (what you'd do in production):

- ✅ Processing raw multi-view videos (.mp4 files)
- ✅ Testing complete pipeline (watch → extract → reconstruct → train)
- ✅ Production deployments with video uploads
- ✅ Automated processing workflows

### Testing the Full Rust Processor

For testing the **complete pipeline** with actual videos, see:

```bash
# Generate synthetic test videos
./scripts/generate-test-videos.sh

# Process with full pipeline (watch mode)
export INPUT_PATH=$PWD/testdata/sample_scene
export OUTPUT_PATH=$PWD/outputs
export BACKEND=auto

cargo run --release
# Or: ./target/release/3dgs-processor

# Copy videos to trigger processing
mkdir -p testdata/sample_scene/my_scene
cp testdata/*.mp4 testdata/sample_scene/my_scene/
```

**Summary**:

- **Tanks and Temples** = Quality benchmarking with pre-processed data → Use Python script
- **Your own videos** = Full pipeline testing → Use Rust processor

## How the Backend System Works

It's important to understand that **the Python script is the actual training implementation**:

```
┌─────────────────────────────────────────┐
│   Rust 3DGS Processor (Orchestrator)    │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │ Watch directories for videos       │ │
│  └──────────────┬─────────────────────┘ │
│                 ↓                        │
│  ┌────────────────────────────────────┐ │
│  │ Extract frames with FFmpeg         │ │
│  └──────────────┬─────────────────────┘ │
│                 ↓                        │
│  ┌────────────────────────────────────┐ │
│  │ Run COLMAP reconstruction          │ │
│  └──────────────┬─────────────────────┘ │
│                 ↓                        │
│  ┌────────────────────────────────────┐ │
│  │ Call Backend Training              │ │
│  │                                    │ │
│  │  GsplatBackend::train() calls:    │ │
│  │  → python3 scripts/gsplat_train.py│ │  ← Python script!
│  │  → --data frames/                 │ │
│  │  → --colmap-dir colmap/sparse/0   │ │
│  │  → --iterations 7000              │ │
│  └──────────────┬─────────────────────┘ │
│                 ↓                        │
│  ┌────────────────────────────────────┐ │
│  │ Export outputs (PLY, SPLAT)        │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

**Key insight**: When you set `BACKEND=gsplat`, the Rust processor:

1. Does all the orchestration (watch, FFmpeg, COLMAP, job management)
2. **Calls `scripts/gsplat_train.py`** for the actual training
3. Handles the results (export, cleanup, error handling)

So the Python script **IS** the backend - we're just calling it directly for Tanks and Temples to skip the preprocessing steps that are already done.

**See the code**: [src/backends/gsplat.rs](../src/backends/gsplat.rs) - Line ~200 shows the subprocess call to the Python script.

## Dataset Scenes

### Training Scenes (Outdoor)

- **Barn** - Rural barn structure
- **Caterpillar** - Construction vehicle
- **Church** - Stone church exterior
- **Courthouse** - Government building
- **Ignatius** - Statue
- **Meetingroom** - Indoor conference room
- **Truck** - Industrial truck

### Advanced Scenes (More Complex)

- **Auditorium** - Large indoor space
- **Ballroom** - Ornate room with reflections
- **Courtroom** - Interior with complex geometry
- **Museum** - Gallery space
- **Palace** - Detailed architectural scene
- **Temple** - Historic building

## Prerequisites

1. **Disk Space**: ~2-20GB per scene (varies by scene complexity)
2. **COLMAP Installed**: For format conversion if needed
3. **Python 3**: For download script

## Quick Start

### Option A: Test Training Quality (Recommended for Benchmarking)

**Use when**: You want to benchmark training speed/quality against published papers.

This uses the **Python training script** with pre-existing COLMAP data:

```bash
# 1. Download a scene
./scripts/download-tanks-and-temples.sh barn

# 2. Run benchmark (automated)
./scripts/benchmark-tanks-and-temples.sh barn

# 3. Or run training directly
python3 scripts/gsplat_train.py \
  --data testdata/tanks-and-temples/barn/images \
  --colmap-dir testdata/tanks-and-temples/barn/colmap/sparse/0 \
  --model-dir outputs/barn \
  --iterations 7000 \
  --save-ply --save-splat
```

**Why this approach?** Tanks and Temples provides pre-processed images and COLMAP reconstructions, so we test the training backend directly (skipping redundant frame extraction and COLMAP steps).

### Option B: Test Full Pipeline (Video Processing)

**Use when**: You want to test the complete Rust processor with actual videos.

This uses the **full Rust processor** with video files:

```bash
# 1. Generate or obtain multi-view videos
./scripts/generate-test-videos.sh  # Creates view1.mp4, view2.mp4, view3.mp4

# 2. Run the full processor in watch mode
export INPUT_PATH=$PWD/testdata/sample_scene
export OUTPUT_PATH=$PWD/outputs
export PROCESSED_PATH=$PWD/processed
export ERROR_PATH=$PWD/error
export BACKEND=auto

cargo run --release
# Or: ./target/release/3dgs-processor

# 3. In another terminal, trigger processing
mkdir -p testdata/sample_scene/my_scene
cp testdata/*.mp4 testdata/sample_scene/my_scene/

# 4. Monitor logs
# Watch as processor: extracts frames → runs COLMAP → trains model → exports outputs

# 5. Check results
ls outputs/my_scene/
# -> manifest.json, model.ply, model.splat
```

**Why this approach?** Tests the complete pipeline including FFmpeg extraction, COLMAP reconstruction, and training - exactly as it would run in production.

## Manual Download and Setup

If you prefer to download manually:

### 1. Download from Official Source

Visit: <https://www.tanksandtemples.org/download/>

Download either:

- **Training Dataset** (recommended for testing): Easier scenes
- **Advanced Dataset**: More challenging reconstructions

### 2. Expected Data Structure

Tanks and Temples provides different data formats. The ideal structure for our processor is:

```
testdata/tanks-and-temples/barn/
├── images/              # RGB images
│   ├── 0000.jpg
│   ├── 0001.jpg
│   └── ...
├── colmap/             # COLMAP reconstruction
│   └── sparse/
│       └── 0/
│           ├── cameras.bin
│           ├── images.bin
│           └── points3D.bin
└── manifest.json       # Optional: processor manifest
```

### 3. Format Conversion

If the dataset comes in a different format (e.g., bundler, OpenMVG):

```bash
# Convert from bundler to COLMAP
colmap model_converter \
  --input_path testdata/tanks-and-temples/barn/bundler \
  --input_type bundler \
  --output_path testdata/tanks-and-temples/barn/colmap/sparse/0 \
  --output_type bin

# Or from text to binary COLMAP format
colmap model_converter \
  --input_path testdata/tanks-and-temples/barn/colmap/sparse/0 \
  --input_type txt \
  --output_path testdata/tanks-and-temples/barn/colmap/sparse/0 \
  --output_type bin
```

## Processing Configuration

### Recommended Settings for Tanks and Temples

Create a custom `config.yaml` for high-quality reconstruction:

```yaml
training:
  iterations: 30000          # More iterations for detailed scenes
  densification_interval: 100
  opacity_reset_interval: 3000
  densify_grad_threshold: 0.0002
  position_lr_init: 0.00016
  position_lr_final: 0.0000016
  
export:
  formats:
    - ply                    # For evaluation
    - splat                  # For web viewing

validation:
  min_images: 10            # Tanks scenes have 100+ images
  min_resolution: 1920      # High-res images
  max_video_size_gb: 50     # Large input sizes
```

### Backend Selection

For best results with Tanks and Temples:

```bash
# NVIDIA GPU (recommended)
export BACKEND=gsplat
export CUDA_VISIBLE_DEVICES=0

# CPU fallback (slow)
export BACKEND=gaussian-splatting
export FORCE_CPU_BACKEND=1
```
<!-- # AMD/Apple GPU: export BACKEND=gaussian-splatting -->

## Expected Results

### Training Time

Typical training times on M1 Max (32GB):

| Scene | Images | Training Time | Output Size |
|-------|--------|---------------|-------------|
| Barn | 252 | ~45 min | ~150MB PLY |
| Truck | 251 | ~40 min | ~130MB PLY |
| Church | 327 | ~60 min | ~200MB PLY |

With NVIDIA RTX 4090:

| Scene | Images | Training Time | Output Size |
|-------|--------|---------------|-------------|
| Barn | 252 | ~8 min | ~150MB PLY |
| Truck | 251 | ~7 min | ~130MB PLY |
| Church | 327 | ~12 min | ~200MB PLY |

### Output Files

After processing, expect:

```
output/barn/
├── model.ply              # 3D Gaussian model (100-300MB)
├── model.splat            # Web-optimized format
├── manifest.json          # Pipeline metadata
├── cameras.json           # Camera parameters
└── metrics.json           # Training metrics
```

### Visual Quality

Tanks and Temples scenes should produce:

- ✅ **High detail** in geometric structures
- ✅ **Good texture** reproduction
- ✅ **Accurate camera poses** (pre-calibrated)
- ⚠️ **Some artifacts** in reflective/transparent areas
- ⚠️ **View-dependent effects** in complex lighting

## Evaluation Against Ground Truth

Tanks and Temples provides ground truth meshes for quantitative evaluation:

```bash
# Download evaluation tools (optional)
git clone https://github.com/isl-org/TanksAndTemples.git
cd TanksAndTemples/python_toolbox/evaluation

# Compare your reconstruction to ground truth
python evaluate.py \
  --pred /path/to/output/barn/model.ply \
  --gt /path/to/tanks-and-temples/barn/ground_truth.ply \
  --output evaluation_results.json
```

Typical F-Score ranges for 3DGS on Tanks and Temples:

- **Training Set**: 0.50 - 0.70
- **Advanced Set**: 0.40 - 0.60

## Troubleshooting

### Issue: Out of Memory

**Symptom**: Training crashes with OOM error

**Solutions**:

```bash
# Reduce Gaussian density
# Edit config.yaml:
training:
  densify_grad_threshold: 0.0004  # Higher = fewer Gaussians

# Or reduce image resolution
# Resize images before processing:
mogrify -resize 50% testdata/tanks-and-temples/barn/images/*.jpg
```

### Issue: Poor Reconstruction Quality

**Symptom**: Blurry or incomplete reconstruction

**Solutions**:

1. Increase training iterations (30000+)
2. Check camera poses are correct:

   ```bash
   # Verify cameras.bin contains proper poses
   colmap model_analyzer \
     --path testdata/tanks-and-temples/barn/colmap/sparse/0
   ```

3. Ensure images are high quality (not compressed)

### Issue: COLMAP Format Mismatch

**Symptom**: Processor fails to read COLMAP data

**Solution**:

```bash
# Verify binary format
file testdata/tanks-and-temples/barn/colmap/sparse/0/cameras.bin
# Should output: "data"

# If it's text format, convert to binary
colmap model_converter --input_path ... --output_type bin
```

## Comparison with Synthetic Test Data

| Aspect | Synthetic Test Data | Tanks and Temples |
|--------|-------------------|-------------------|
| **Purpose** | Unit/integration tests | Quality validation |
| **Size** | <1MB | 2-20GB per scene |
| **Training Time** | <1 minute (mock) | 5-60 minutes (GPU) |
| **Image Quality** | Minimal placeholders | High-res photography |
| **COLMAP Quality** | Synthetic, unrealistic | Real reconstruction |
| **Output Quality** | N/A (mock backend) | Production-ready |
| **Use Case** | CI/CD, development | Benchmarking, demos |

## Best Scenes for Testing

Recommended scenes for different test scenarios:

### 1. Quick Sanity Check (~10 min)

- **Truck**: Simple geometry, good textures, 251 images

### 2. Medium Complexity (~30 min)

- **Barn**: Outdoor scene, standard benchmark, 252 images
- **Ignatius**: Statue with fine details, 318 images

### 3. Challenging Scenes (~60+ min)

- **Church**: Complex architecture, many images (327)
- **Auditorium**: Indoor, lighting challenges, 459 images

### 4. Algorithm Stress Test

- **Ballroom**: Reflections, transparent glass
- **Museum**: Large scale, repetitive patterns

## Integration with CI/CD

For automated testing with Tanks and Temples:

```yaml
# .github/workflows/benchmark.yml
name: Benchmark with Tanks and Temples

on:
  workflow_dispatch:  # Manual trigger only (large download)
  
jobs:
  benchmark:
    runs-on: [self-hosted, gpu]
    steps:
      - uses: actions/checkout@v3
      
      - name: Download Truck scene
        run: ./scripts/download-tanks-and-temples.sh truck
      
      - name: Build processor
        run: cargo build --release
      
      - name: Run benchmark
        run: |
          export BACKEND=gsplat
          timeout 30m ./scripts/benchmark-tanks-and-temples.sh truck
      
      - name: Upload results
        uses: actions/upload-artifact@v3
        with:
          name: benchmark-results
          path: outputs/
```

## Resources

- **Official Website**: <https://www.tanksandtemples.org/>
- **Paper**: [Tanks and Temples: Benchmarking Large-Scale Scene Reconstruction](https://www.tanksandtemples.org/) -- see Google Drive Link
- **Data Download**: <https://www.tanksandtemples.org/download/>
- **Evaluation Tools**: <https://github.com/isl-org/TanksAndTemples>

## Next Steps

After validating with Tanks and Temples:

1. **Document Performance**: Record processing times and quality metrics
2. **Create Benchmark Script**: Automate evaluation workflow
3. **Add to CI/CD**: Optional GPU-based benchmark jobs
4. **Generate Demo Outputs**: Use for documentation and presentations

---

*For quick synthetic testing during development, continue using the minimal test data in `testdata/sample_scene/test_run/`.*
