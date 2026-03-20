# Backend Validation Testing

## Overview

This document describes the backend validation testing infrastructure implemented for the 3DGS video processor.

## Implementation Date

January 2025

## Test Suite

Created comprehensive backend validation tests in `tests/integration/backend_validation.rs` with the following test coverage:

### Test Categories

1. **Test Data Validation** (`test_test_data_exists`)
   - Verifies COLMAP test data is present
   - Checks for required test frames (5 JPEGs)
   - Validates directory structure

2. **Frame Collection** (`test_collect_frame_paths`)
   - Tests frame path collection from test data
   - Verifies correct ordering (frame_000000.jpg to frame_000004.jpg)
   - Ensures all 5 test frames are found

3. **Input Validation** (`test_mock_backend_rejects_empty_frames`)
   - Validates that backends reject empty frame arrays
   - Ensures proper error handling for invalid input

4. **Training Pipeline** (`test_mock_backend_with_frames`)
   - Tests backend training with real test data
   - Validates BackendOutput structure
   - Verifies model_path exists on disk
   - Confirms gaussian_count is populated
   - Checks metadata fields (training_time, backend_version, gpu_device)

5. **PLY Export** (`test_mock_backend_ply_export`)
   - Tests PLY format export functionality
   - Verifies file creation and size (~42KB for test data)
   - Validates export path handling

6. **SPLAT Export** (`test_mock_backend_splat_export`)
   - Tests SPLAT format export functionality
   - Verifies file creation and size (~16KB for test data)
   - Validates binary format output

7. **Gsplat Backend on CPU** (`test_gsplat_backend_cpu`) 🆕
   - Tests real gsplat backend with CPU-only PyTorch
   - Validates training with 100 iterations (~3-8 seconds)
   - Confirms PLY export (~41KB output)
   - SPLAT export optional (requires converter tools)
   - **No GPU required!** Proves graceful degradation works

## Test Results

### MockBackend Tests (Always Run)
All 6 MockBackend validation tests pass:
```
test backend_validation::test_mock_backend_rejects_empty_frames ... ok
test backend_validation::test_test_data_exists ... ok
test backend_validation::test_collect_frame_paths ... ok
test backend_validation::test_mock_backend_with_frames ... ok
test backend_validation::test_mock_backend_ply_export ... ok (42442 bytes)
test backend_validation::test_mock_backend_splat_export ... ok (16013 bytes)
```

### Gsplat CPU Test (Requires Setup)
Real gsplat backend test with CPU-only training:
```bash
# Setup (one-time):
python3 -m venv .venv
source .venv/bin/activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
pip install gsplat

# Run test:
GSPLAT_PYTHON=$PWD/.venv/bin/python \
GSPLAT_BIN=$PWD/scripts/gsplat_train.py \
cargo test --test integration test_gsplat_backend_cpu -- --ignored --nocapture
```

Results:
```
✅ Gsplat training successful:
  Model path: testdata/sample_scene/test_run/output/point_cloud.ply
  Iterations: 100
  Gaussians: Some(1000)
  Training time: ~3-8 seconds on CPU

✅ PLY export successful:
  Size: 40676 bytes

⚠️  SPLAT export skipped (converter not available)
  This is expected - requires ply-to-splat conversion tools
```

### Overall Test Suite
- **Library tests**: 216 passed (+ 3 ignored)
- **Integration tests**: 161 passed
- **Backend validation (MockBackend)**: 6 passed
- **Backend validation (Gsplat CPU)**: 1 passed
- **Total**: 384 tests passing

## MockBackend Implementation Fix

### Issue
Originally, `MockBackend.train()` returned a `BackendOutput` with a model_path pointing to a non-existent file, causing test failures.

### Solution
Updated `src/backends/mock.rs` to:
1. Generate unique model filenames using UUID v4
2. Create actual mock checkpoint files with JSON metadata
3. Write model data to disk before returning BackendOutput
4. Include model_path in training completion logs

```rust
// Create a mock model file in temp directory
let model_path = std::env::temp_dir().join(format!("mock_checkpoint_{}.pth", uuid::Uuid::new_v4()));

// Write a minimal mock checkpoint file
let mock_checkpoint_data = format!(
    "{{\"version\":\"1.0\",\"backend\":\"mock\",\"gaussian_count\":{},\"iterations\":1000}}",
    gaussian_count
);
fs::write(&model_path, mock_checkpoint_data.as_bytes()).await?;
```

## Test Data Structure

The backend validation tests use real COLMAP test data located at:
```
testdata/sample_scene/test_run/
├── colmap/
│   └── sparse/
│       └── 0/
│           ├── cameras.bin
│           ├── images.bin
│           └── points3D.bin
└── images/
    ├── frame_000000.jpg
    ├── frame_000001.jpg
    ├── frame_000002.jpg
    ├── frame_000003.jpg
    └── frame_000004.jpg
```

## Helper Functions

### `collect_frame_paths()`
Collects and sorts all frame paths from the test data directory:
```rust
fn collect_frame_paths() -> Result<Vec<PathBuf>>
```

Returns paths in sorted order for deterministic testing.

## Validation Script

Created `scripts/validate-backend.sh` for manual backend testing:

### Usage
```bash
# Test mock backend (always works, no dependencies)
./scripts/validate-backend.sh mock

# Test gsplat backend on CPU (requires Python + venv setup)
# First-time setup:
python3 -m venv .venv
source .venv/bin/activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
pip install gsplat

# Then run:
GSPLAT_PYTHON=$PWD/.venv/bin/python \
GSPLAT_BIN=$PWD/scripts/gsplat_train.py \
./scripts/validate-backend.sh gsplat 100

# Test all available backends
./scripts/validate-backend.sh all
```

### Features
- Validates test data presence
- Runs backend training with real frames
- Checks output files and metadata
- Provides detailed logging

## Backend API

The validation tests exercise the following backend API:

### Training
```rust
async fn train(
    &self,
    frames: &[&Path],
    config: &TrainingConfig,
) -> Result<BackendOutput>
```

### Export Methods
```rust
async fn export_ply(&self, output: &BackendOutput, path: &Path) -> Result<()>
async fn export_splat(&self, output: &BackendOutput, path: &Path) -> Result<()>
```

### BackendOutput Structure
```rust
pub struct BackendOutput {
    pub model_path: PathBuf,          // Must exist on disk
    pub iterations_completed: usize,
    pub backend_name: String,
    pub final_loss: Option<f64>,
    pub gaussian_count: Option<usize>,
    pub metadata: BackendMetadata,
}
```

## Future Work

### GPU Backend Testing
- [x] Test with real `gsplat` backend on CPU ✅ **COMPLETED**
- [ ] Test with real `gsplat` backend on CUDA GPU for performance comparison
- [ ] Test with `gaussian-splatting` backend (requires CUDA GPU)
- [ ] Benchmark training performance across backends
- [ ] Compare quality metrics (PSNR, SSIM) between backends

### End-to-End Testing
- Full pipeline test with video → frames → COLMAP → training → export
- Multi-video processing validation
- Azure blob storage integration testing

### Docker Validation
- Build multi-arch container images
- Test container with FFmpeg, COLMAP, and backend plugins
- Validate GPU passthrough in containers

## Related Files

- [tests/integration/backend_validation.rs](../tests/integration/backend_validation.rs) - Test implementation
- [scripts/validate-backend.sh](../scripts/validate-backend.sh) - Manual validation script
- [src/backends/mock.rs](../src/backends/mock.rs) - MockBackend implementation
- [src/backends/mod.rs](../src/backends/mod.rs) - Backend trait definition
- [testdata/sample_scene/test_run/](../testdata/sample_scene/test_run/) - Test data

## References

- [3DGS Video Processor PRD](3dgs-video-processor-prd.md)
- [Architecture Documentation](ARCHITECTURE.md)
- [Integration Tests README](../tests/README.md)
