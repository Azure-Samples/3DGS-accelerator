#!/usr/bin/env bash
# local-build.sh — Build the GPU image locally and push to ACR.
#
# Uses Docker BuildKit with layer caching for fast incremental rebuilds.
# On subsequent builds, only changed layers (e.g., Rust source) are rebuilt;
# base images, apt packages, pip packages, and COLMAP compilation are cached.
#
# Requires: Docker with buildx, az login to ACR
#
# Usage:
#   ./infra/scripts/hooks/local-build.sh              # build + push
#   ./infra/scripts/hooks/local-build.sh --no-push     # build only (local testing)
#   ./infra/scripts/hooks/local-build.sh --no-cache    # force full rebuild
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PUSH=true
NO_CACHE=""

for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=false ;;
    --no-cache) NO_CACHE="--no-cache" ;;
  esac
done

# ── Read ACR coordinates from azd env ────────────────────────────────────────
ACR_NAME=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME 2>/dev/null || echo "")
ACR_ENDPOINT=$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT 2>/dev/null || echo "")

if [[ -z "$ACR_NAME" || -z "$ACR_ENDPOINT" ]]; then
  echo "❌ AZURE_CONTAINER_REGISTRY_NAME / ENDPOINT not set in azd env."
  echo "   Run 'azd provision' first to create the infrastructure."
  exit 1
fi

# ── Build tag ────────────────────────────────────────────────────────────────
GIT_SHA=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nogit")
IMAGE_TAG="${GIT_SHA}-$(date +%s)"
IMAGE_REPO="3dgs-processor"
LOCAL_IMAGE="${ACR_ENDPOINT}/${IMAGE_REPO}:${IMAGE_TAG}"
LATEST_IMAGE="${ACR_ENDPOINT}/${IMAGE_REPO}:gpu-latest"

echo ""
echo "🐳 Building GPU image locally with Docker BuildKit"
echo "   Registry : $ACR_NAME ($ACR_ENDPOINT)"
echo "   Image    : ${LOCAL_IMAGE}"
echo "   Target   : gpu"
echo "   Push     : $PUSH"
echo ""

# ── Login to ACR ─────────────────────────────────────────────────────────────
if [[ "$PUSH" == "true" ]]; then
  echo "🔑 Logging in to ACR..."
  az acr login --name "$ACR_NAME" --output none 2>&1
  echo ""
fi

# ── Build with BuildKit ──────────────────────────────────────────────────────
cd "$ROOT_DIR"

BUILD_START=$(date +%s)

DOCKER_BUILDKIT=1 docker build \
  --target gpu \
  --build-arg CUDA_ARCHITECTURES="75" \
  --build-arg BUILDKIT_INLINE_CACHE=1 \
  --tag "$LOCAL_IMAGE" \
  --tag "$LATEST_IMAGE" \
  --file Dockerfile \
  $NO_CACHE \
  .

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

echo ""
echo "✅ Local build completed in ${BUILD_DURATION}s"
echo ""

# ── Push to ACR ──────────────────────────────────────────────────────────────
if [[ "$PUSH" == "true" ]]; then
  echo "📤 Pushing image to ACR..."
  PUSH_START=$(date +%s)

  docker push "$LOCAL_IMAGE"
  docker push "$LATEST_IMAGE"

  PUSH_END=$(date +%s)
  PUSH_DURATION=$((PUSH_END - PUSH_START))

  echo ""
  echo "✅ Push completed in ${PUSH_DURATION}s"

  azd env set JOB_IMAGE "$LOCAL_IMAGE"

  echo ""
  echo "📊 Summary:"
  echo "   Build : ${BUILD_DURATION}s"
  echo "   Push  : ${PUSH_DURATION}s"
  echo "   Total : $((BUILD_DURATION + PUSH_DURATION))s"
  echo ""
  echo "✅ Image pushed: $LOCAL_IMAGE"
  echo "   Also tagged : $LATEST_IMAGE"
else
  echo "⏭️  Skipping push (--no-push). Image available locally as:"
  echo "   $LOCAL_IMAGE"
  echo "   $LATEST_IMAGE"
fi
