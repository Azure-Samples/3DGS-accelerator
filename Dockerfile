# Multi-stage Dockerfile for 3DGS Video Processor
# Optimized for small image size using Docker best practices
# Supports multi-arch builds (linux/amd64 and linux/arm64)
# Build with: docker buildx build --platform linux/amd64,linux/arm64 -t 3dgs-processor:latest .

# ============================================================================
# Stage 1: Rust build (Bookworm toolchain, binary is glibc-compatible with Ubuntu 24.04)
# ============================================================================
FROM rust:1.93-bookworm AS builder

WORKDIR /build

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Copy source and build
COPY Cargo.toml Cargo.lock ./
COPY src ./src

# Build with locked dependencies and strip binary for smaller size
RUN cargo build --release --locked && \
    strip target/release/3dgs-processor

# ============================================================================
# Stage 2: Python environment with gsplat (optional backend)
# ============================================================================
FROM python:3.12-slim-bookworm AS python-builder

# Install build dependencies for Python packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install PyTorch CPU-only (smaller image, works without GPU)
# For GPU support, change to: torch torchvision --index-url https://download.pytorch.org/whl/cu121
RUN pip install --no-cache-dir \
    torch torchvision --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir \
    gsplat \
    numpy

# ============================================================================
# Stage 3: Final runtime image (Ubuntu 24.04 with apt-installed COLMAP)
# ============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

WORKDIR /app

# Install runtime dependencies + COLMAP + FFmpeg + Blobfuse2 in a single layer
RUN apt-get update && \
    ARCH=$(dpkg --print-architecture) && \
    # Install base tools needed for Microsoft repo setup
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release && \
    # Add Microsoft repository for Blobfuse2
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/repos/microsoft-ubuntu-noble-prod noble main" | \
        tee /etc/apt/sources.list.d/microsoft.list && \
    apt-get update && \
    # Install runtime dependencies
    apt-get install -y --no-install-recommends \
        # COLMAP from Ubuntu universe repo (3.9.1, CPU-only, pulls all deps)
        colmap \
        # FFmpeg for frame extraction and metadata
        ffmpeg \
        # Python runtime for gsplat backend
        python3 \
        python3-venv \
        libpython3.12 \
        # FUSE for Azure Blob Storage mounting
        fuse3 \
        libfuse3-3 && \
    # Install blobfuse2 only on amd64 (not available for arm64)
    if [ "$ARCH" = "amd64" ]; then \
        apt-get install -y --no-install-recommends blobfuse2 && \
        blobfuse2 --version > /dev/null; \
    else \
        echo "WARNING: blobfuse2 not available for ${ARCH} - Azure Blob mounting will not work" >&2; \
    fi && \
    # Cleanup in the same layer to reduce image size
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    # Verify installations
    ffmpeg -version > /dev/null && \
    colmap help > /dev/null 2>&1

# Copy Python virtual environment with gsplat from python-builder
COPY --from=python-builder /opt/venv /opt/venv

# Fix venv Python symlinks to point to system Python 3.12
RUN cd /opt/venv/bin && \
    rm -f python python3 python3.12 && \
    ln -s /usr/bin/python3.12 python3.12 && \
    ln -s python3.12 python3 && \
    ln -s python3 python && \
    /opt/venv/bin/python --version

# Copy compiled Rust binary from builder
COPY --from=builder /build/target/release/3dgs-processor /usr/local/bin/3dgs-processor

# Copy gsplat training script
COPY scripts/gsplat_train.py /app/scripts/gsplat_train.py

# Copy Azure mounting helper script
COPY scripts/mount-azure.sh /usr/local/bin/mount-azure.sh

# Create directories and set permissions in a single layer
RUN mkdir -p /config /tmp/3dgs-work /tmp/blobfuse-cache /tmp/blobfuse-configs && \
    chmod +x /usr/local/bin/mount-azure.sh /usr/local/bin/3dgs-processor

# Copy example config
COPY config.example.yaml /config/config.example.yaml

# Set environment variables with defaults
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

# Required environment variables (must be provided at runtime)
# INPUT_PATH, OUTPUT_PATH, PROCESSED_PATH, ERROR_PATH

# Azure Blob Storage support via Blobfuse2
# Note: Running with Azure Blob Storage requires:
#   - Privileged mode: --privileged flag
#   - Device access: --device /dev/fuse --cap-add SYS_ADMIN
#   - One of the following authentication methods:
#     1. AZURE_STORAGE_CONNECTION_STRING
#     2. AZURE_STORAGE_ACCOUNT + AZURE_STORAGE_SAS_TOKEN
#     3. AZURE_STORAGE_ACCOUNT + AZURE_USE_MANAGED_IDENTITY=true

# Health check (optional)
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD pgrep -f 3dgs-processor || exit 1

ENTRYPOINT ["/usr/local/bin/3dgs-processor"]
