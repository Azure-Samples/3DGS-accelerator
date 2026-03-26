#!/usr/bin/env bash
# acr-build.sh — Build the 3DGS GPU container image via ACR Tasks (remote build).
#
# Creates a minimal Docker context staging directory and uploads it to ACR.
# No local Docker daemon required.
#
# Usage: ./infra/scripts/hooks/acr-build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ── Read ACR coordinates from azd env ────────────────────────────────────────
ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
ACR_ENDPOINT=$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT 2>/dev/null || echo "")

if [[ -z "$ACR_NAME" || -z "$ACR_ENDPOINT" ]]; then
  echo "❌ AZURE_CONTAINER_REGISTRY_NAME / ENDPOINT not set in azd env."
  echo "   Run 'azd provision' first to create the infrastructure."
  exit 1
fi

# ── Build tag: short git SHA + epoch seconds for uniqueness ──────────────────
GIT_SHA=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")
IMAGE_TAG="${GIT_SHA}-$(date +%s)"
IMAGE_REPO="3dgs-processor"

echo ""
echo "🐳 Building GPU image via ACR Tasks (remote build)"
echo "   Registry : $ACR_NAME ($ACR_ENDPOINT)"
echo "   Image    : ${IMAGE_REPO}:${IMAGE_TAG}"
echo "   Target   : gpu"
echo ""
echo "   ⚠️  GPU image build takes ~15-25 min (COLMAP from source + PyTorch CUDA)"
echo ""

# ── Create a minimal staging directory with only what the Dockerfile needs ───
# The repo has large directories (target/, .venv/) that the az acr build CLI
# scans slowly even when excluded by .dockerignore. We create a clean staging
# directory with only the files required by the GPU Dockerfile.
STAGING_DIR=$(mktemp -d /tmp/acr-staging-XXXXXX)
trap "rm -rf $STAGING_DIR" EXIT

echo "📦 Creating minimal Docker context..."
cd "$ROOT_DIR"

# Copy only what the Dockerfile needs
cp Dockerfile "$STAGING_DIR/"
cp Cargo.toml "$STAGING_DIR/"
cp Cargo.lock "$STAGING_DIR/"
cp config.example.yaml "$STAGING_DIR/"
cp -r src "$STAGING_DIR/src"
mkdir -p "$STAGING_DIR/scripts"
cp scripts/gsplat_train.py "$STAGING_DIR/scripts/"
cp scripts/mount-azure.sh "$STAGING_DIR/scripts/"
cp -r docker "$STAGING_DIR/docker" 2>/dev/null || true
cp -r plugins "$STAGING_DIR/plugins" 2>/dev/null || true
cp -r .cargo "$STAGING_DIR/.cargo" 2>/dev/null || true

CONTEXT_SIZE=$(du -sh "$STAGING_DIR" | cut -f1)
echo "   Context size: $CONTEXT_SIZE"
echo ""

# Build the GPU target with T4-optimized CUDA architectures
az acr build \
  --registry "$ACR_NAME" \
  --image "${IMAGE_REPO}:${IMAGE_TAG}" \
  --image "${IMAGE_REPO}:gpu-latest" \
  --file Dockerfile \
  --build-arg CUDA_ARCHITECTURES="75" \
  --target gpu \
  --platform linux/amd64 \
  --timeout 3600 \
  "$STAGING_DIR"

FULL_IMAGE="${ACR_ENDPOINT}/${IMAGE_REPO}:${IMAGE_TAG}"
azd env set JOB_IMAGE "$FULL_IMAGE"

echo ""
echo "✅ Image built and pushed: $FULL_IMAGE"
echo "   Also tagged: ${ACR_ENDPOINT}/${IMAGE_REPO}:gpu-latest"
