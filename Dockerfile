# Multi-stage Dockerfile for 3DGS Video Processor
#
# Two build targets:
#   cpu  — Lightweight, multi-arch (amd64 + arm64). Uses apt COLMAP + CPU PyTorch, but
#           still defaults to BACKEND=gsplat (GPU-only). On CPU-only hosts, override
#           BACKEND (e.g., BACKEND=mock) at runtime.
#   gpu  — NVIDIA CUDA runtime, COLMAP from source with CUDA, CUDA PyTorch. amd64 only.
#
# Usage:
#   docker build --target cpu -t 3dgs-processor:cpu .
#   docker build --target gpu -t 3dgs-processor:gpu .
#   docker build --target gpu --build-arg CUDA_ARCHITECTURES="75" -t 3dgs-processor:gpu-t4 .
#
# Without --target, builds the cpu target (last stage = default).
#
# GPU build args:
#   CUDA_VERSION        — CUDA toolkit version (default: 12.6.3)
#   COLMAP_VERSION      — COLMAP git tag to build (default: 3.11.1)
#   CUDA_ARCHITECTURES  — semicolon-separated SM codes (default: "75;80;86;89;90")
#                         See docs/cuda-architecture-guide.md for the full mapping.
#   PYTORCH_CUDA_TAG    — PyTorch wheel index suffix (default: cu126)

# ============================================================================
# Global build args
# ============================================================================
ARG CUDA_VERSION=12.6.3
ARG COLMAP_VERSION=3.11.1
ARG CUDA_ARCHITECTURES="75;80;86;89;90"
ARG PYTORCH_CUDA_TAG=cu126

# ============================================================================
# Stage: Rust build (shared by cpu and gpu targets)
# ============================================================================
FROM rust:1.93-bookworm AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock ./
COPY src ./src

RUN cargo build --release --locked && \
    strip target/release/3dgs-processor

# ============================================================================
# Stage: Python environment — CPU-only PyTorch (used by cpu target)
# ============================================================================
FROM python:3.12-slim-bookworm AS python-cpu

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir \
    gsplat \
    numpy

# ============================================================================
# Stage: Python environment — CUDA PyTorch (used by gpu target)
# ============================================================================
FROM python:3.12-slim-bookworm AS python-gpu

ARG PYTORCH_CUDA_TAG

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/${PYTORCH_CUDA_TAG} && \
    pip install --no-cache-dir \
    gsplat \
    numpy

# ============================================================================
# Stage: Build COLMAP from source with CUDA (used by gpu target only)
# ============================================================================
ARG CUDA_VERSION
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu24.04 AS colmap-builder

ARG COLMAP_VERSION
ARG CUDA_ARCHITECTURES

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake ninja-build build-essential \
    libboost-program-options-dev libboost-graph-dev \
    libboost-system-dev libeigen3-dev \
    libgoogle-glog-dev libgtest-dev \
    libsqlite3-dev libceres-dev \
    libflann-dev libfreeimage-dev \
    libsuitesparse-dev libmetis-dev \
    libcgal-dev \
    # COLMAP cmake probes for OpenGL/GLEW even with OPENGL_ENABLED=OFF
    libegl-dev libopengl-dev libglew-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch ${COLMAP_VERSION} \
    https://github.com/colmap/colmap.git /colmap

WORKDIR /colmap

RUN cmake -B build -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCUDA_ENABLED=ON \
      -DGUI_ENABLED=OFF \
      -DOPENGL_ENABLED=OFF \
      -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
    && cmake --build build --config Release -j"$(nproc)" \
    && cmake --install build --prefix /colmap-install

# ============================================================================
# Target: gpu — NVIDIA CUDA runtime with COLMAP from source
# ============================================================================
ARG CUDA_VERSION
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu24.04 AS gpu

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

RUN apt-get update && \
    ARCH=$(dpkg --print-architecture) && \
    apt-get install -y --no-install-recommends software-properties-common && \
    add-apt-repository -y universe && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/repos/microsoft-ubuntu-noble-prod noble main" | \
        tee /etc/apt/sources.list.d/microsoft.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        python3 \
        python3-venv \
        libpython3.12 \
        # COLMAP runtime shared-library dependencies
        libboost-program-options1.83.0 \
        libboost-graph1.83.0 \
        libceres4t64 \
        libflann1.9 \
        libfreeimage3 \
        libsqlite3-0 \
        libgoogle-glog0v6t64 \
        libsuitesparseconfig7 \
        # SiftGPU links against OpenGL/GLEW even with OPENGL_ENABLED=OFF
        libopengl0 libglew2.2 libglx0 libgl1 \
        libmetis5 \
        fuse3 \
        libfuse3-3 && \
    if [ "$ARCH" = "amd64" ]; then \
        apt-get install -y --no-install-recommends blobfuse2 || true; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    ffmpeg -version > /dev/null

COPY --from=colmap-builder /colmap-install /usr/local
RUN ldconfig && colmap help > /dev/null 2>&1

COPY --from=python-gpu /opt/venv /opt/venv
RUN cd /opt/venv/bin && \
    rm -f python python3 python3.12 && \
    ln -s /usr/bin/python3.12 python3.12 && \
    ln -s python3.12 python3 && \
    ln -s python3 python && \
    /opt/venv/bin/python --version

COPY --from=builder /build/target/release/3dgs-processor /usr/local/bin/3dgs-processor
COPY scripts/gsplat_train.py /app/scripts/gsplat_train.py
COPY scripts/mount-azure.sh /usr/local/bin/mount-azure.sh
RUN mkdir -p /config /tmp/3dgs-work /tmp/blobfuse-cache /tmp/blobfuse-configs && \
    chmod +x /usr/local/bin/mount-azure.sh /usr/local/bin/3dgs-processor
COPY config.example.yaml /config/config.example.yaml

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    LOG_LEVEL=info \
    TEMP_PATH=/tmp/3dgs-work \
    CONFIG_PATH=/config/config.yaml \
    UPLOAD_STABILITY_TIMEOUT_SECS=60 \
    MAX_RETRIES=3 \
    POLL_INTERVAL_SECS=10 \
    BACKEND=gsplat \
    GSPLAT_PYTHON=/opt/venv/bin/python \
    GSPLAT_BIN=/app/scripts/gsplat_train.py \
    RETENTION_DAYS=30

ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    QT_QPA_PLATFORM=offscreen

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD pgrep -f 3dgs-processor || exit 1

ENTRYPOINT ["/usr/local/bin/3dgs-processor"]

# ============================================================================
# Target: cpu — Lightweight Ubuntu with apt COLMAP (default when no --target)
# ============================================================================
FROM ubuntu:24.04 AS cpu

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

RUN apt-get update && \
    ARCH=$(dpkg --print-architecture) && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/repos/microsoft-ubuntu-noble-prod noble main" | \
        tee /etc/apt/sources.list.d/microsoft.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        colmap \
        ffmpeg \
        python3 \
        python3-venv \
        libpython3.12 \
        fuse3 \
        libfuse3-3 && \
    if [ "$ARCH" = "amd64" ]; then \
        apt-get install -y --no-install-recommends blobfuse2 && \
        blobfuse2 --version > /dev/null; \
    else \
        echo "WARNING: blobfuse2 not available for ${ARCH} - Azure Blob mounting will not work" >&2; \
    fi && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    ffmpeg -version > /dev/null && \
    colmap help > /dev/null 2>&1

COPY --from=python-cpu /opt/venv /opt/venv
RUN cd /opt/venv/bin && \
    rm -f python python3 python3.12 && \
    ln -s /usr/bin/python3.12 python3.12 && \
    ln -s python3.12 python3 && \
    ln -s python3 python && \
    /opt/venv/bin/python --version

COPY --from=builder /build/target/release/3dgs-processor /usr/local/bin/3dgs-processor
COPY scripts/gsplat_train.py /app/scripts/gsplat_train.py
COPY scripts/mount-azure.sh /usr/local/bin/mount-azure.sh
RUN mkdir -p /config /tmp/3dgs-work /tmp/blobfuse-cache /tmp/blobfuse-configs && \
    chmod +x /usr/local/bin/mount-azure.sh /usr/local/bin/3dgs-processor
COPY config.example.yaml /config/config.example.yaml

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    LOG_LEVEL=info \
    TEMP_PATH=/tmp/3dgs-work \
    CONFIG_PATH=/config/config.yaml \
    UPLOAD_STABILITY_TIMEOUT_SECS=60 \
    MAX_RETRIES=3 \
    POLL_INTERVAL_SECS=10 \
    BACKEND=gsplat \
    GSPLAT_PYTHON=/opt/venv/bin/python \
    GSPLAT_BIN=/app/scripts/gsplat_train.py \
    RETENTION_DAYS=30

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD pgrep -f 3dgs-processor || exit 1

ENTRYPOINT ["/usr/local/bin/3dgs-processor"]
