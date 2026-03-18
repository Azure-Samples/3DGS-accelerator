# CUDA Architecture Guide for 3DGS Processor

This document maps NVIDIA CUDA compute capability codes (`CMAKE_CUDA_ARCHITECTURES`)
to GPU hardware, and then to Azure VM SKUs and Azure Container Apps GPU workload
profiles. Use this when choosing which `CUDA_ARCHITECTURES` build-arg to pass to
the `gpu` target in `Dockerfile`.

## Quick Reference

When building the GPU Docker image, specify the target architectures:

```bash
# Single GPU target (smallest/fastest build):
docker build --target gpu --build-arg CUDA_ARCHITECTURES="75" -t 3dgs-processor:gpu-t4 .

# Multi-GPU support (covers T4 through H100):
docker build --target gpu --build-arg CUDA_ARCHITECTURES="75;80;86;89;90" -t 3dgs-processor:gpu .
```

> **Tip:** Fewer architectures = faster build and smaller binary. Target only what you deploy to.

---

## CUDA Compute Capabilities ↔ NVIDIA GPUs

| SM Code | Architecture | Notable GPUs | VRAM | Use Case |
|---------|-------------|-------------|------|----------|
| **50** | Maxwell | Tesla M60, Quadro M6000 | 8–24 GB | Legacy (not recommended) |
| **60** | Pascal | Tesla P100 (SXM2) | 16 GB | HPC, older cloud |
| **61** | Pascal | Tesla P4, GTX 1080 Ti | 8–11 GB | Inference, older cloud |
| **70** | Volta | Tesla V100 | 16–32 GB | HPC, training |
| **75** | Turing | **Tesla T4**, RTX 2080 Ti, Quadro RTX 5000 | 16 GB | **Azure Container Apps GPU**, inference |
| **80** | Ampere | **A100** (SXM4/PCIe), A30 | 40–80 GB | Training, HPC |
| **86** | Ampere | RTX 3090, A10, A40 | 24–48 GB | Training, rendering |
| **89** | Ada Lovelace | RTX 4090, L40, L4 | 24–48 GB | Training, inference, rendering |
| **90** | Hopper | **H100** (SXM5/PCIe), H200 | 80–141 GB | Large-scale training |
| **100** | Blackwell | B100, B200, GB200 | 192+ GB | Next-gen (when available) |

### How SM Codes Work

- Each SM (Streaming Multiprocessor) code represents a GPU micro-architecture generation.
- Native CUDA machine code (“SASS”) compiled for a given SM (e.g., **75**) is only guaranteed
  to run on GPUs that provide that same SM version; a binary that contains **only** SM 75
  code will run on Turing (SM 7.5) but will **not** run on newer major architectures such
  as Ampere (SM 8.x), Ada (SM 8.9), or Hopper (SM 9.0) unless PTX is also available.
- Specifying multiple **real** SM codes (e.g., `"75;80;86;89;90"`) embeds multiple native
  code images in one binary (**fat binary**) — larger, but it can run on any GPU whose SM
  is included in that list.
- Including PTX (“virtual” architectures, e.g., `"75-virtual"`) allows the CUDA driver to
  JIT-compile code for newer GPUs that do not have a matching native image, at the cost of
  additional startup latency. For production, include native code for every SM you deploy to,
  and optionally PTX for forward-compatibility with future GPUs.

---

## Azure GPU VM SKUs

| VM Series | GPU | Count | GPU Memory | SM Code | Typical Use |
|-----------|-----|-------|------------|---------|-------------|
| **NC4as T4 v3** | Tesla T4 | 1 | 16 GB | **75** | Dev/test, inference |
| **NC8as T4 v3** | Tesla T4 | 1 | 16 GB | **75** | General GPU workloads |
| **NC16as T4 v3** | Tesla T4 | 1 | 16 GB | **75** | CPU-heavy + GPU |
| **NC64as T4 v3** | Tesla T4 | 4 | 64 GB | **75** | Multi-GPU inference |
| **NC24ads A100 v4** | A100 (PCIe) | 1 | 80 GB | **80** | Training, HPC |
| **NC48ads A100 v4** | A100 (PCIe) | 2 | 160 GB | **80** | Large training |
| **NC96ads A100 v4** | A100 (PCIe) | 4 | 320 GB | **80** | Multi-GPU training |
| **ND96asr A100 v4** | A100 (SXM4) | 8 | 320 GB | **80** | Distributed training |
| **ND96amsr A100 v4** | A100 (SXM4) | 8 | 640 GB | **80** | Large models |
| **NV36ads A10 v5** | A10 | 1 | 24 GB | **86** | Rendering, VDI |
| **NV72ads A10 v5** | A10 | 2 | 48 GB | **86** | Multi-GPU rendering |
| **NC40ads H100 v5** | H100 (PCIe) | 1 | 80 GB | **90** | Next-gen training |
| **NC80adis H100 v5** | H100 (PCIe) | 2 | 160 GB | **90** | HPC |
| **ND96isr H100 v5** | H100 (SXM5) | 8 | 640 GB | **90** | Frontier AI training |

> **Source:** [Azure VM sizes — GPU accelerated](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/overview)

---

## Azure Container Apps GPU Workload Profiles

Azure Container Apps currently offers **serverless GPU** via Consumption-GPU profiles:

| Workload Profile | GPU | GPU Memory | vCPU | RAM | SM Code |
|-----------------|-----|------------|------|-----|---------|
| **Consumption-GPU-NC8as-T4** | Tesla T4 | 16 GB | 8 | 56 GB | **75** |
| **Consumption-GPU-NC16as-T4** | Tesla T4 | 16 GB | 16 | 112 GB | **75** |

### Key Constraints for Container Apps GPU

- **No X11/GLX** — containers run headless; COLMAP must be built without OpenGL
- **No `/dev/fuse`** — blobfuse2 will not work; use batch mode with Azure Blob SDK
- **No `nvidia-container-toolkit`** — GPU is exposed directly, not via Docker `--gpus`
- **NVIDIA driver ~550.x** pre-installed by Azure; container needs matching CUDA toolkit
- **Only T4 (SM 75) currently available** as of early 2026

> For the latest workload profiles, see:
> [Azure Container Apps GPU overview](https://learn.microsoft.com/en-us/azure/container-apps/gpu-serverless-overview)

---

## Recommended Build Configurations

### Minimal — Azure Container Apps T4 Only

```bash
docker build --target gpu \
  --build-arg CUDA_ARCHITECTURES="75" \
  -t 3dgs-processor:gpu-t4 .
```

Smallest binary, fastest build. Use this for Container Apps deployments.

### Standard — T4 + A100 (Most Azure VMs)

```bash
docker build --target gpu \
  --build-arg CUDA_ARCHITECTURES="75;80" \
  -t 3dgs-processor:gpu .
```

Covers the two most common Azure GPU SKUs.

### Broad — All Current Architectures

```bash
docker build --target gpu \
  --build-arg CUDA_ARCHITECTURES="75;80;86;89;90" \
  -t 3dgs-processor:gpu-all .
```

Works on T4, A100, A10, L4/L40, H100. Larger binary, longer build.

---

## Build Matrix Script

Use `scripts/docker-build-matrix.sh` to build multiple image variants in one go:

```bash
# Build both CPU and GPU images:
./scripts/docker-build-matrix.sh

# Build GPU only, for T4:
./scripts/docker-build-matrix.sh --gpu-only --cuda-arch "75"

# Build and push to a registry:
REGISTRY=myregistry.azurecr.io ./scripts/docker-build-matrix.sh --push
```

See [scripts/docker-build-matrix.sh](../scripts/docker-build-matrix.sh) for all options.

---

## COLMAP-Specific Notes

### `CMAKE_CUDA_ARCHITECTURES` in COLMAP

This CMake variable controls which GPU code paths are compiled into the COLMAP binary:

```cmake
cmake -B build \
  -DCUDA_ENABLED=ON \
  -DGUI_ENABLED=OFF \
  -DOPENGL_ENABLED=OFF \
  -DCMAKE_CUDA_ARCHITECTURES="75;80"
```

- **`CUDA_ENABLED=ON`** — enables CUDA-accelerated SIFT feature extraction and matching
- **`GUI_ENABLED=OFF`** — disables Qt GUI (not needed in containers)
- **`OPENGL_ENABLED=OFF`** — removes the GLX/X11 dependency that causes the
  `Check failed: context_.create()` crash in headless environments
- **`CMAKE_CUDA_ARCHITECTURES`** — must include the SM code for your target GPU

### COLMAP GPU Performance Impact

| Operation | CPU Time | GPU Time (T4) | Speedup |
|-----------|----------|---------------|---------|
| SIFT Feature Extraction | ~60s/image | ~2s/image | ~30× |
| Exhaustive Matching (100 images) | ~30 min | ~1 min | ~30× |
| Sequential Matching (100 images) | ~2 min | ~10s | ~12× |
| Sparse Reconstruction (mapper) | ~5 min | ~5 min | ~1× (CPU-bound) |

> The mapper step is CPU-bound regardless. GPU acceleration primarily benefits
> feature extraction and matching.

---

## References

- [NVIDIA CUDA Compute Capabilities](https://developer.nvidia.com/cuda-gpus)
- [COLMAP Installation — Build from Source](https://colmap.github.io/install.html)
- [COLMAP CMake Configuration](https://github.com/colmap/colmap/blob/main/CMakeLists.txt)
- [Azure VM GPU sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/overview)
- [Azure Container Apps GPU](https://learn.microsoft.com/en-us/azure/container-apps/gpu-serverless-overview)
- [PyTorch CUDA Wheels](https://download.pytorch.org/whl/)
- [NVIDIA CUDA Docker Images](https://hub.docker.com/r/nvidia/cuda)
