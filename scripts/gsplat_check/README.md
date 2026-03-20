# gsplat_check — CUDA / gsplat Environment Verifier

Lightweight Python script that validates whether the current machine can run the
**gsplat** 3DGS training backend. It mirrors the checks performed by the Rust
preflight binary (`target/release/3dgs-preflight`) but runs entirely in Python.

## What it checks

| Check | Details |
|-------|---------|
| **CUDA GPU** | Detects GPU via `nvidia-smi`, probes PyTorch CUDA support, runs a tensor smoke-test |
| **gsplat library** | Verifies import and exercises the `rasterization()` kernel with 8 tiny Gaussians |
| **External tools** | `nvidia-smi`, `python3`, `ffmpeg`, `colmap` |

Exits **0** on success, **1** on failure.

## Prerequisites

* Python 3.11+
* [uv](https://docs.astral.sh/uv/) package manager
* NVIDIA GPU with CUDA drivers installed

## Quick start

```bash
cd scripts/gsplat_check

# First run — uv creates the venv and installs torch + gsplat automatically
uv run main.py
```

### Example output (passing)

```
CUDA GPU
────────
  ✓ CUDA GPU         NVIDIA RTX 4090 (24.0GB VRAM)
  Platform        : CUDA
  Device          : NVIDIA RTX 4090
  VRAM            : 24.0 GB
  PyTorch         : 2.10.0+cu128
  CUDA runtime    : 12.8
  Usable          : yes

gsplat Library
──────────────
  ✓ gsplat           1.5.3
  ✓ CUDA kernels     rasterization smoke-test passed

External Tools
──────────────
  ✓ nvidia-smi       NVIDIA-SMI version  : 580.126.10
  ✓ python3          Python 3.11.15
  ✓ ffmpeg           ffmpeg version 6.1.1
  ✓ colmap           COLMAP 3.9.1

Environment Verdict
───────────────────

  ✅ ENVIRONMENT CHECK PASSED
     CUDA and gsplat are functional on this device.
```

### Example output (failing — unsupported GPU arch)

```
CUDA GPU
────────
  ✗ CUDA GPU         not detected or unusable
  Platform        : CUDA
  Device          : NVIDIA GeForce GTX 1060
  VRAM            : 6.0 GB
  PyTorch         : 2.10.0+cu128
  CUDA runtime    : 12.8
  Usable          : no

  ❌ ENVIRONMENT CHECK FAILED
     • No usable CUDA GPU
```

## How it relates to the Rust preflight tool

The Rust binary `3dgs-preflight` (built via `cargo build --release`) performs the
same checks but also validates the full backend resolution logic. This Python
script focuses specifically on the CUDA + gsplat layer and is useful for:

* Verifying a new GPU / driver before deploying the full pipeline
* Debugging gsplat kernel compilation issues
* Quick sanity checks in CI or on remote machines
