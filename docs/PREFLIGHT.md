# Preflight Check

## Overview

The **3DGS Preflight Check** is a standalone Rust binary (`3dgs-preflight`) that validates the runtime environment before long-running Gaussian Splatting training jobs. It detects GPU hardware, probes external tools, and compares findings against the backend you intend to use — reporting clear, numbered failure reasons when the environment falls short.

Run it before committing GPU hours to catch misconfigurations early.

## Quick Start

### Native Binary

```bash
# Build
cargo build --release --bin 3dgs-preflight

# Detect and report (always exits 0)
./target/release/3dgs-preflight

# Assert a specific backend is usable (exits 1 with reasons on failure)
./target/release/3dgs-preflight --expect gsplat
```

### Docker Container

```bash
# Build the preflight image
docker build -f Dockerfile.preflight -t 3dgs-preflight:latest .

# Run with GPU access
docker run --rm --gpus all 3dgs-preflight

# Assert backend inside the container
docker run --rm --gpus all 3dgs-preflight --expect gsplat

# Or via environment variable
docker run --rm --gpus all -e BACKEND=gsplat 3dgs-preflight
```

## What It Checks

The preflight tool performs four categories of checks:

### 1. GPU Detection

Probes for GPU hardware in priority order:

| Platform | Detection Method | Recommended Backend |
|----------|-----------------|---------------------|
| NVIDIA CUDA | `nvidia-smi` → PyTorch fallback | `gsplat` |
| Apple Metal | `sysctl` (macOS only) | `gaussian-splatting` |
| AMD ROCm | `rocm-smi` | `gaussian-splatting` |
| None (CPU) | — | `mock` |

Reports: device name, VRAM (GB), platform, and usability.

### 2. Backend Resolution

Shows which backend would be selected using the same logic as the main processor:

1. `BACKEND` environment variable (highest priority)
2. Auto-detection based on GPU capabilities
3. `FORCE_CPU_BACKEND` override → `mock`

### 3. External Tool Availability

Checks that required tools are installed and reports their versions:

| Tool | Required By |
|------|------------|
| `nvidia-smi` | CUDA GPU detection |
| `python3` | gsplat backend |
| `gsplat` (Python package) | gsplat backend |
| `ffmpeg` | Frame extraction (all backends) |
| `colmap` | Reconstruction (all backends) |

### 4. Backend Compatibility Verdict

When `--expect` is provided (or `BACKEND` env var is set), the tool validates that the detected environment can actually run the requested backend:

| Backend | Requirements |
|---------|-------------|
| `gsplat` | CUDA GPU + `python3` + `gsplat` Python package |
| `gaussian-splatting` | Any GPU (CUDA, Metal, or ROCm) |
| `3dgs-cpp` | CUDA GPU |
| `mock` | None (always passes) |

It also catches conflicting configuration (e.g., `FORCE_CPU_BACKEND=1` with `--expect gsplat`).

## CLI Reference

```text
USAGE:
    3dgs-preflight [OPTIONS]

OPTIONS:
    -e, --expect <BACKEND>  Assert that this backend is usable (exit 1 if not)
    -h, --help              Print help message
    -V, --version           Print version

ENVIRONMENT:
    BACKEND               Same as --expect (CLI flag takes precedence)
    FORCE_CPU_BACKEND     If set, forces mock/CPU backend selection
    COLMAP_USE_CPU        If set, forces COLMAP to CPU-only mode (headless-safe)
    GSPLAT_PYTHON         Python interpreter for gsplat check (default: python3)
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Preflight passed (or detection-only mode) |
| `1` | Preflight failed — environment cannot satisfy the expected backend |

## Example Output

### Detection Only (no `--expect`)

```text
╔══════════════════════════════════════════════════════════╗
║           3DGS Preflight Environment Check              ║
╚══════════════════════════════════════════════════════════╝

GPU Detection
─────────────
  ✓ CUDA GPU: NVIDIA GeForce RTX 4090 (24.0GB VRAM)
  Platform   : CUDA
  Device     : NVIDIA GeForce RTX 4090
  VRAM       : 24.0 GB
  Usable     : yes
  Recommended: gsplat

Backend Resolution
──────────────────
  Resolved backend : gsplat

External Tools
──────────────
  ✓ nvidia-smi     NVIDIA-SMI version  : 550.54.14
  ✓ python3        Python 3.12.3
  ✓ ffmpeg         ffmpeg version 6.1.1
  ✓ colmap         COLMAP 3.9.1
  ✓ gsplat         1.5.0

ℹ  No --expect flag or BACKEND env var set. Reporting detection only.
   Recommended backend: gsplat
```

### Failed Assertion

```text
Preflight Verdict
─────────────────
  Expected backend: gsplat
  Resolved backend: mock

  ❌ PREFLIGHT FAILED

  1. gsplat requires a CUDA GPU, but detected platform is: None (CPU-only)
  2. gsplat Python package is not installed (pip install gsplat)
  3. FORCE_CPU_BACKEND is set, which forces 'mock' backend, but you expect 'gsplat'.
     Unset FORCE_CPU_BACKEND to use a real backend.

  The environment cannot satisfy backend 'gsplat'.
  Resolve the issues above before starting training.
```

## Integration with CI/CD

Run the preflight check as a gate before training jobs:

```yaml
# GitHub Actions example
jobs:
  preflight:
    runs-on: self-hosted-gpu
    steps:
      - uses: actions/checkout@v4
      - run: cargo build --release --bin 3dgs-preflight
      - run: ./target/release/3dgs-preflight --expect gsplat

  train:
    needs: preflight
    runs-on: self-hosted-gpu
    steps:
      - run: ./target/release/3dgs-processor
```

```bash
# Docker Compose — run preflight before the processor
docker compose run --rm preflight --expect gsplat && \
docker compose up processor
```

## Dockerfile

The `Dockerfile.preflight` is a separate, lightweight image (~800MB vs ~2-3GB for the main processor) that includes only what's needed for environment probing:

- Rust binary (`3dgs-preflight`)
- Python 3.12 (for gsplat package detection)
- FFmpeg and COLMAP (for tool availability checks)

It intentionally does **not** include PyTorch or gsplat — it only checks if they're available in the target runtime. When checking GPU backends in a container, pass `--gpus all` to expose the host GPU:

```bash
docker run --rm --gpus all 3dgs-preflight --expect gsplat
```

## Source Files

| File | Purpose |
|------|---------|
| [`src/bin/preflight.rs`](../src/bin/preflight.rs) | Preflight binary entry point |
| [`src/backends/gpu_detect.rs`](../src/backends/gpu_detect.rs) | GPU detection logic (shared with main processor) |
| [`src/backends/registry.rs`](../src/backends/registry.rs) | Backend resolution logic (shared with main processor) |
| [`Dockerfile.preflight`](../Dockerfile.preflight) | Standalone container for preflight checks |

## Related Documentation

- [Docker Build Guide](DOCKER_BUILD.md) — Building the main processor container
- [Backend Validation](BACKEND_VALIDATION.md) — Backend testing infrastructure
- [Deployment Guide](DEPLOYMENT.md) — Cloud deployment patterns
- [Architecture](ARCHITECTURE.md) — System design overview
