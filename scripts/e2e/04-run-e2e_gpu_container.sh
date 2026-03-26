#!/usr/bin/env bash
# 04-run-e2e_gpu_container.sh — Run the full GPU E2E pipeline in a Docker container
#
# Runs the GPU Docker image in batch mode against Azurite (Azure Storage emulator).
# No compose — uses standalone docker run for both Azurite and the processor.
#
# Flow:
#   1. Download test data (if needed)
#   2. Build GPU Docker image
#   3. Start Azurite container
#   4. Create blob containers + upload test videos
#   5. Run GPU processor container in batch mode
#   6. Verify outputs in Azurite
#   7. Cleanup
#
# Prerequisites:
#   - Docker with NVIDIA GPU support (nvidia-container-toolkit)
#   - Python 3 with azure-storage-blob (auto-installed in venv)
#
# Usage:
#   ./scripts/e2e/04-run-e2e_gpu_container.sh
#   ./scripts/e2e/04-run-e2e_gpu_container.sh --skip-build    # reuse existing image
#   ./scripts/e2e/04-run-e2e_gpu_container.sh --timeout 600   # custom timeout

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../.."

SKIP_BUILD=false
TIMEOUT=900
SCENE_NAME="south_building"
BATCH_PREFIX="${SCENE_NAME}/"
AZURITE_PORT=10000
NETWORK_NAME="3dgs-gpu-e2e-net"
AZURITE_CONTAINER="azurite-gpu-e2e"
PROCESSOR_CONTAINER="3dgs-gpu-e2e"
GPU_IMAGE="3dgs-processor:gpu-latest"
VIDEO_SRC="$PROJECT_ROOT/testdata/south_building_videos"

for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    --timeout) TIMEOUT="$2"; shift ;;
  esac
done

echo "============================================"
echo "  3DGS GPU Container E2E Test"
echo "============================================"
echo ""
echo "  Scene:   $SCENE_NAME"
echo "  Image:   $GPU_IMAGE"
echo "  Timeout: ${TIMEOUT}s"
echo ""

# ── Cleanup function ────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "Cleaning up..."
  docker stop "$PROCESSOR_CONTAINER" 2>/dev/null || true
  docker rm "$PROCESSOR_CONTAINER" 2>/dev/null || true
  docker stop "$AZURITE_CONTAINER" 2>/dev/null || true
  docker rm "$AZURITE_CONTAINER" 2>/dev/null || true
  docker network rm "$NETWORK_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ── Step 1: Download test data ──────────────────────────────────────────────
echo "[1/7] Checking test data..."
if [ ! -d "$VIDEO_SRC" ] || [ "$(find "$VIDEO_SRC" -name '*.mp4' 2>/dev/null | wc -l)" -lt 3 ]; then
  echo "  Downloading South Building dataset..."
  "$SCRIPT_DIR/01-download-testdata.sh"
else
  echo "  Test videos found: $VIDEO_SRC"
fi
echo ""

# ── Step 2: Build GPU image ─────────────────────────────────────────────────
echo "[2/7] Building GPU Docker image..."
if [ "$SKIP_BUILD" = true ]; then
  echo "  Skipping build (--skip-build)"
else
  docker build --target gpu -t "$GPU_IMAGE" "$PROJECT_ROOT"
  echo "  GPU image built"
fi
echo ""

# ── Step 3: Create Docker network + start Azurite ───────────────────────────
echo "[3/7] Starting Azurite..."

# Clean up any prior run
docker stop "$AZURITE_CONTAINER" 2>/dev/null || true
docker rm "$AZURITE_CONTAINER" 2>/dev/null || true
docker network rm "$NETWORK_NAME" 2>/dev/null || true

docker network create "$NETWORK_NAME"

docker run -d --rm \
  --name "$AZURITE_CONTAINER" \
  --network "$NETWORK_NAME" \
  -p "${AZURITE_PORT}:10000" \
  mcr.microsoft.com/azure-storage/azurite \
  azurite-blob --blobHost 0.0.0.0 --blobPort 10000 --skipApiVersionCheck

# Wait for Azurite to be ready
echo "  Waiting for Azurite..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s "http://127.0.0.1:${AZURITE_PORT}/" >/dev/null 2>&1; then
    echo "  Azurite ready"
    break
  fi
  if [ "$i" -eq 10 ]; then
    echo "  ERROR: Azurite failed to start"
    exit 1
  fi
  sleep 2
done
echo ""

# ── Step 4: Setup Python venv + upload test data ────────────────────────────
echo "[4/7] Uploading test videos to Azurite..."

VENV_DIR="$PROJECT_ROOT/output/.e2e-venv"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --quiet azure-storage-blob 2>/dev/null

python3 "$SCRIPT_DIR/azurite_helper.py" setup "$VIDEO_SRC" "$BATCH_PREFIX"
SAS_TOKEN=$(python3 "$SCRIPT_DIR/azurite_helper.py" sas)
deactivate

echo "  Uploaded test videos with prefix: $BATCH_PREFIX"
echo ""

# ── Step 5: Run GPU processor container ─────────────────────────────────────
echo "[5/7] Running GPU processor in batch mode..."
echo "  BACKEND=gsplat"
echo "  RUN_MODE=batch"
echo "  BATCH_INPUT_PREFIX=$BATCH_PREFIX"
echo "  AZURE_STORAGE_ENDPOINT=http://${AZURITE_CONTAINER}:10000/devstoreaccount1"
echo ""

CONTAINER_EXIT=0
docker run --rm --gpus all \
  --name "$PROCESSOR_CONTAINER" \
  --network "$NETWORK_NAME" \
  -v "$PROJECT_ROOT/container-test/config.1.yaml:/app/config.yaml:ro" \
  -e CONFIG_PATH=/app/config.yaml \
  -e INPUT_PATH=/data/input \
  -e OUTPUT_PATH=/data/output \
  -e PROCESSED_PATH=/data/processed \
  -e ERROR_PATH=/data/error \
  -e BACKEND=gsplat \
  -e TEMP_PATH=/tmp/3dgs-work \
  -e LOG_LEVEL=info \
  -e NVIDIA_VISIBLE_DEVICES=all \
  -e RUN_MODE=batch \
  -e "BATCH_INPUT_PREFIX=$BATCH_PREFIX" \
  -e AZURE_STORAGE_ACCOUNT=devstoreaccount1 \
  -e "AZURE_STORAGE_ENDPOINT=http://${AZURITE_CONTAINER}:10000/devstoreaccount1" \
  -e "AZURE_STORAGE_SAS_TOKEN=$SAS_TOKEN" \
  -e AZURE_BLOB_CONTAINER_INPUT=input \
  -e AZURE_BLOB_CONTAINER_OUTPUT=output \
  -e AZURE_BLOB_CONTAINER_PROCESSED=processed \
  -e AZURE_BLOB_CONTAINER_ERROR=error \
  -e COLMAP_MATCHER=sequential \
  -e COLMAP_MAX_NUM_FEATURES=2048 \
  -e FRAME_RATE=2 \
  -e MIN_VIDEO_FRAMES=5 \
  -e MIN_VIDEO_DURATION=0.5 \
  -e MIN_RECONSTRUCTION_POINTS=100 \
  -e RECONSTRUCTION_BACKEND=colmap \
  -e MAX_RETRIES=1 \
  "$GPU_IMAGE" || CONTAINER_EXIT=$?

echo ""
if [ "$CONTAINER_EXIT" -ne 0 ]; then
  echo "  ERROR: GPU container exited with code $CONTAINER_EXIT"
fi

# ── Step 6: Verify outputs ──────────────────────────────────────────────────
echo "[6/7] Verifying outputs in Azurite..."

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
VERIFY_EXIT=0
python3 "$SCRIPT_DIR/azurite_helper.py" verify "$BATCH_PREFIX" || VERIFY_EXIT=$?
deactivate

echo ""

# ── Step 7: Summary ─────────────────────────────────────────────────────────
echo "[7/7] Cleanup (automatic via trap)"
echo ""
echo "============================================"
echo "  GPU Container E2E Results"
echo "============================================"

if [ "$CONTAINER_EXIT" -eq 0 ] && [ "$VERIFY_EXIT" -eq 0 ]; then
  echo "  RESULT: PASSED"
  echo ""
  echo "  Pipeline completed successfully:"
  echo "    - Videos downloaded from Azurite"
  echo "    - COLMAP reconstruction on GPU"
  echo "    - gsplat training on GPU"
  echo "    - PLY + SPLAT exported"
  echo "    - Outputs uploaded to Azurite"
  echo "    - Input videos moved to processed"
  echo "============================================"
  exit 0
else
  echo "  RESULT: FAILED"
  echo "    Container exit code: $CONTAINER_EXIT"
  echo "    Verify exit code:   $VERIFY_EXIT"
  echo "============================================"
  exit 1
fi
