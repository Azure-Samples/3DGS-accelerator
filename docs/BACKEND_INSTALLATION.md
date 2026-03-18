# Backend Installation Guide

Complete installation guide for all 3D Gaussian Splatting backends supported by the processor.

## Table of Contents

* [Overview](#overview)
* [Mock Backend](#mock-backend)
* [Gaussian Splatting (Original)](#gaussian-splatting-original)
* [Gsplat](#gsplat)
* [3DGS.cpp](#3dgscpp)
* [Backend Selection](#backend-selection)
* [Troubleshooting](#troubleshooting)

---

## Overview

The 3DGS Video Processor supports multiple backend implementations:

| Backend | Language | GPU Support | Status | Best For |
|---------|----------|-------------|--------|----------|
| **Mock** | Rust | N/A | ✅ Production | Testing, development |
| **gaussian-splatting** | Python/CUDA | NVIDIA, AMD, Apple | ✅ Production | Metal GPUs, research |
| **gsplat** | Python/CUDA | NVIDIA | ✅ Production | CUDA GPUs, performance |
| **3dgs-cpp** | C++ | NVIDIA, CPU | 🚧 Reference | Future C++ integration |

### Automatic Backend Selection

The processor automatically selects the best backend for your hardware:

```bash
# Auto-detection (default)
BACKEND=auto

# Detected GPU → Recommended backend:
# - NVIDIA CUDA → gsplat
# - Apple Metal → gaussian-splatting
# - AMD ROCm → gaussian-splatting
# - No GPU → mock (testing only)
```

Force a specific backend:

```bash
BACKEND=gsplat           # Force gsplat
BACKEND=gaussian-splatting  # Force gaussian-splatting
FORCE_CPU_BACKEND=1      # Force mock backend (testing)
COLMAP_USE_CPU=1         # Force COLMAP to CPU-only (headless-safe)
```

---

## Mock Backend

**Purpose**: Testing and development without GPU requirements.

### Features

- ✅ No external dependencies
- ✅ Pure Rust implementation
- ✅ Fast execution (~100ms)
- ✅ Validates pipeline without training
- ⚠️ Produces placeholder outputs (not real 3DGS models)

### Installation

No installation required - included in the Rust binary.

### Usage

```bash
# Automatic when no GPU detected
BACKEND=auto

# Or force explicitly
BACKEND=mock
# OR
FORCE_CPU_BACKEND=1
```

### Output

Creates valid PLY/SPLAT files with minimal Gaussians for testing pipeline integration.

---

## Gaussian Splatting (Original)

**Repository**: https://github.com/graphdeco-inria/gaussian-splatting

The original implementation from INRIA. Best for Metal GPUs and research.

### Prerequisites

- Python 3.8+
- CUDA Toolkit 11.8+ (NVIDIA), Metal (Apple), or ROCm (AMD)
- Git

### Installation

#### Option 1: System-wide Installation

```bash
# Clone repository
git clone https://github.com/graphdeco-inria/gaussian-splatting.git
cd gaussian-splatting

# Install dependencies
pip install -r requirements.txt

# Install package in development mode
pip install -e .

# Verify installation
python -c "import diff_gaussian_rasterization; print('✅ Installation successful')"
```

#### Option 2: Virtual Environment (Recommended)

```bash
# Create virtual environment
python3 -m venv ~/gaussian-splatting-env
source ~/gaussian-splatting-env/bin/activate

# Install gaussian-splatting
pip install git+https://github.com/graphdeco-inria/gaussian-splatting.git

# Set environment variable
export GAUSSIAN_SPLATTING_BIN=$(which python)
```

#### Option 3: Docker (Easiest)

The provided Dockerfile bundles gaussian-splatting:

```bash
docker build -t 3dgs-processor:latest .
# gaussian-splatting included automatically
```

### Configuration

Set the binary path if not using standard location:

```bash
export GAUSSIAN_SPLATTING_BIN=/path/to/train.py
export BACKEND=gaussian-splatting
```

### Verification

Test the backend:

```bash
# Run backend validation tests
cargo test --test integration backend_validation

# Expected: gaussian_splatting backend available
```

### GPU Support

**NVIDIA CUDA**:
```bash
# Verify CUDA
nvidia-smi
python -c "import torch; print(torch.cuda.is_available())"
```

**Apple Metal**:
```bash
# Verify Metal
python -c "import torch; print(torch.backends.mps.is_available())"
```

**AMD ROCm**:
```bash
# Verify ROCm
rocm-smi
python -c "import torch; print(torch.cuda.is_available())"
```

---

## Gsplat

**Repository**: https://github.com/nerfstudio-project/gsplat

High-performance CUDA implementation. Best for NVIDIA GPUs.

### Prerequisites

- Python 3.8+
- CUDA Toolkit 11.8+ (NVIDIA only)
- PyTorch 2.0+ with CUDA support

### Installation

#### Option 1: pip (Recommended)

```bash
# Install PyTorch with CUDA
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu118

# Install gsplat
pip install gsplat

# Verify installation
python -c "import gsplat; print(f'✅ gsplat {gsplat.__version__} installed')"
```

#### Option 2: From Source

```bash
# Clone repository
git clone https://github.com/nerfstudio-project/gsplat.git
cd gsplat

# Install in development mode
pip install -e .

# Run tests
pytest tests/
```

#### Option 3: Docker (Included)

The provided Dockerfile bundles gsplat with PyTorch CPU:

```bash
docker build -t 3dgs-processor:latest .
# gsplat included automatically

# For CUDA support, use NVIDIA container runtime:
docker run --gpus all 3dgs-processor:latest
```

### Configuration

```bash
export BACKEND=gsplat
export GSPLAT_BIN=/path/to/custom/gsplat_train.py  # Optional
```

The processor includes `scripts/gsplat_train.py` by default.

### Verification

```bash
# Check CUDA availability
python -c "import torch; print(f'CUDA available: {torch.cuda.is_available()}')"
python -c "import gsplat; print(f'gsplat version: {gsplat.__version__}')"

# Run validation tests
cargo test --test integration backend_validation::test_gsplat_training_with_real_data

# Expected output: ~1000 Gaussians, ~41KB PLY file
```

### Performance

**CPU Mode** (tested):
- Training: 3-8 seconds (100 iterations)
- Output: ~1000 Gaussians, 41KB PLY

**CUDA Mode** (expected):
- Training: 10-30x faster (same iterations)
- Recommended: 30,000 iterations for production quality

### CPU Fallback

Gsplat gracefully falls back to CPU when no CUDA GPU is detected:

```bash
# CPU-only training (slower but functional)
BACKEND=gsplat cargo run

# Log output:
# "CUDA not available, using CPU (slow)"
```

---

## 3DGS.cpp

**Status**: Reference implementation template

The 3DGS.cpp backend is implemented as a reference template for future C++ backend integration. It's not connected to a real C++ implementation but provides a complete integration pattern.

### Current Status

- ✅ Full trait implementation
- ✅ Unit tests passing
- ✅ Registered in backend registry
- ⚠️ Creates placeholder outputs (not real training)

### Documentation

See `docs/3DGS_CPP_IMPLEMENTATION.md` for complete implementation details.

### Future Integration

To integrate a real C++ backend:

1. Replace placeholder binary path with real executable
2. Update training command construction
3. Parse C++ training output
4. Update export commands for PLY/SPLAT

The existing code provides the complete integration structure.

---

## Backend Selection

### Environment Variables

```bash
# Auto-detect best backend (default)
BACKEND=auto

# Force specific backend
BACKEND=gsplat              # CUDA GPUs
BACKEND=gaussian-splatting  # Metal/ROCm GPUs
BACKEND=mock                # Testing only

# Force CPU mode (testing)
FORCE_CPU_BACKEND=1
```

### Selection Logic

The processor automatically selects backends based on detected hardware:

```
Detect GPU:
├─ NVIDIA CUDA detected → gsplat (optimized for CUDA)
├─ Apple Metal detected → gaussian-splatting (Metal support)
├─ AMD ROCm detected → gaussian-splatting (ROCm support)
└─ No GPU detected → mock (testing only, logs warning)
```

View selection on startup:

```bash
docker logs 3dgs-processor | grep -i gpu

# Example output:
# INFO GPU detected: NVIDIA GeForce RTX 3090 (24GB VRAM)
# INFO Selected backend: gsplat (optimal for CUDA)
```

### Override Auto-Detection

```bash
# Force gsplat even if Metal GPU detected
BACKEND=gsplat

# Use mock backend for testing pipeline
FORCE_CPU_BACKEND=1
```

---

## Troubleshooting

### Backend Not Found

**Error**: `Backend 'gsplat' not found in registry`

**Solution**:

```bash
# Check available backends
docker exec 3dgs-processor \
  /app/3dgs-processor --help | grep -A 5 "Available backends"

# Verify environment variable
docker inspect 3dgs-processor | grep BACKEND
```

### Import Errors

**Error**: `ModuleNotFoundError: No module named 'gsplat'`

**Solution**:

```bash
# Rebuild Docker image
docker build -t 3dgs-processor:latest .

# Or install in virtual environment
pip install gsplat torch
```

### CUDA Not Available

**Error**: `CUDA not available, using CPU (slow)`

**Solution**:

```bash
# Verify CUDA installation
nvidia-smi
python -c "import torch; print(torch.cuda.is_available())"

# Use NVIDIA container runtime
docker run --gpus all 3dgs-processor:latest

# Or use Metal/CPU backend
BACKEND=gaussian-splatting  # For Metal GPUs
BACKEND=mock                # For testing without GPU
```

### Performance Issues

**Symptom**: Training takes hours instead of minutes

**Solutions**:

1. **Check GPU usage**:
   ```bash
   # NVIDIA
   nvidia-smi
   
   # Apple
   sudo powermetrics --samplers gpu_power
   ```

2. **Reduce iterations** (for testing):
   ```yaml
   # config.yaml
   training:
     iterations: 1000  # Instead of 30000
   ```

3. **Use appropriate backend**:
   ```bash
   # CUDA GPU → gsplat (fastest)
   BACKEND=gsplat
   
   # Metal GPU → gaussian-splatting
   BACKEND=gaussian-splatting
   ```

### Backend Validation

Run the backend validation test suite:

```bash
# Test all backends with real COLMAP data
cargo test --test integration backend_validation

# Test specific backend
cargo test --test integration backend_validation::test_gsplat_training_with_real_data

# Expected: 7 tests passing
# - 6 mock backend tests
# - 1 gsplat CPU test
```

Successful output:
```
test backend_validation::test_gsplat_training_with_real_data ... ok
test backend_validation::test_ply_export_validation ... ok
test backend_validation::test_splat_export_validation ... ok
```

---

## Container Best Practices

### Production Deployment

Use the official multi-arch image:

```bash
docker pull 3dgs-processor:latest

# Auto-detects platform (arm64/amd64)
# Auto-detects GPU (CUDA/Metal/ROCm)
```

### GPU Support

**NVIDIA CUDA**:
```bash
docker run --gpus all \
  -e BACKEND=gsplat \
  3dgs-processor:latest
```

**Apple Metal** (Docker Desktop):
```bash
docker run \
  -e BACKEND=gaussian-splatting \
  3dgs-processor:latest
# Note: Metal support via Docker is limited
```

**CPU-Only**:
```bash
docker run \
  -e FORCE_CPU_BACKEND=1 \
  3dgs-processor:latest
# Uses mock backend for testing
```

### Verification

After deployment, verify backend selection:

```bash
# Check logs
docker logs 3dgs-processor | head -20

# Expected output:
# INFO GPU detected: [GPU name]
# INFO Selected backend: [backend name]
# INFO Starting 3DGS Video Processor
```

---

## Additional Resources

- [User Guide](USER_GUIDE.md) - Complete usage documentation
- [Deployment Guide](DEPLOYMENT.md) - Azure and production deployment
- [Troubleshooting](TROUBLESHOOTING.md) - Common issues and solutions
- [Backend Validation](BACKEND_VALIDATION.md) - Testing documentation

---

**Questions or Issues?**

Check the [Troubleshooting Guide](TROUBLESHOOTING.md) or file an issue on GitHub.
