#!/bin/bash
# 3DGS Video Processor - Local GPU Batch Run Script (south_building scene)
# Runs the GPU container in batch mode: process once and exit.

set -e

SCENE_NAME="south_building"

echo "=========================================="
echo "3DGS Video Processor - GPU Batch Mode"
echo "  Scene: $SCENE_NAME"
echo "=========================================="

# Step 1: Create directory structure
echo ""
echo "[1/5] Creating directory structure..."
mkdir -p ./output/data/{input,processed,error,output}
mkdir -p ./output/tmp
echo "  Created: ./output/data/{input,processed,error,output}, ./output/tmp"

# Step 2: Copy test videos
echo ""
echo "[2/5] Setting up test scene..."
if [ -d "testdata/south_building_videos" ]; then
    mkdir -p "./output/data/input/$SCENE_NAME"
    cp testdata/south_building_videos/view*.mp4 "./output/data/input/$SCENE_NAME/" 2>/dev/null || true
    echo "  Copied test videos to ./output/data/input/$SCENE_NAME/"
else
    echo "  ERROR: testdata/south_building_videos not found."
    echo "  Run: ./scripts/e2e/01-download-testdata.sh"
    exit 1
fi

# Step 3: Build GPU image
echo ""
echo "[3/5] Building GPU Docker image..."
docker build --target gpu -t 3dgs-processor:gpu-latest .
echo "  GPU image built"

# Step 4: Prepare config
echo ""
echo "[4/5] Setting up configuration..."
if [ ! -f "container-test/config.1.yaml" ]; then
    cp config.example.yaml container-test/config.1.yaml
fi
echo "  Config: container-test/config.1.yaml"

# Step 5: Run in batch mode
echo ""
echo "[5/5] Running GPU container in BATCH mode..."
echo "  Scene: $SCENE_NAME"
echo ""

docker-compose --profile gpu run --rm \
  -e RUN_MODE=batch \
  -e "BATCH_INPUT_PREFIX=$SCENE_NAME/" \
  -e COLMAP_MATCHER=sequential \
  -e COLMAP_MAX_NUM_FEATURES=2048 \
  -e FRAME_RATE=2 \
  -e MIN_VIDEO_FRAMES=5 \
  -e MIN_VIDEO_DURATION=0.5 \
  -e MIN_RECONSTRUCTION_POINTS=100 \
  -e RECONSTRUCTION_BACKEND=colmap \
  3dgs-processor-gpu

echo ""
echo "=========================================="
echo "  Batch job complete"
echo "=========================================="
echo ""
echo "  Output: ./output/data/output/"
echo "  Expected: ${SCENE_NAME}.ply, ${SCENE_NAME}.splat, manifest.json"
echo "  Processed videos moved to: ./output/data/processed/$SCENE_NAME/"

