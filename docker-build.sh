#!/bin/bash
set -euo pipefail

# Build script for 3DGS Video Processor Docker image
# Supports multi-arch builds using Docker Buildx (default builder)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

IMAGE_NAME="${IMAGE_NAME:-3dgs-processor}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-false}"

echo "========================================="
echo "Building 3DGS Video Processor"
echo "========================================="
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"
echo "Platforms: ${PLATFORMS}"
echo "Push: ${PUSH}"
echo "========================================="

# Check if buildx is available
if ! docker buildx version &> /dev/null; then
    echo "ERROR: Docker Buildx is not available"
    echo "Please install Docker Buildx or use Docker Desktop"
    exit 1
fi

# Build arguments
BUILD_ARGS=(
    -t "${IMAGE_NAME}:${IMAGE_TAG}"
)

# Add push flag if enabled
if [ "${PUSH}" = "true" ]; then
    BUILD_ARGS+=(--platform "${PLATFORMS}" --push)
else
    echo ""
    echo "NOTE: Building for single platform (--load) since multi-arch requires --push"
    echo "To build multi-arch, set PUSH=true and ensure you have a registry configured"
    BUILD_ARGS+=(--platform linux/amd64 --load)
fi

# Build the image
echo ""
echo "Building Docker image..."
docker buildx build "${BUILD_ARGS[@]}" .

echo ""
echo "========================================="
echo "Build complete!"
echo "========================================="
if [ "${PUSH}" = "false" ]; then
    echo ""
    echo "To run the container:"
    echo "  docker run --rm ${IMAGE_NAME}:${IMAGE_TAG}"
    echo ""
    echo "To build for multiple architectures and push:"
    echo "  PUSH=true ./docker-build.sh"
fi
