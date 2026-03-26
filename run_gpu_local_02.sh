#!/bin/bash
# 3DGS Video Processor - Local GPU Setup & Run Script
# Pure bash script for local GPU container execution

set -e  # Exit on error

echo "=========================================="
echo "3DGS Video Processor - GPU Local Setup"
echo "=========================================="

# Step 1: Create directory structure
echo ""
echo "[1/5] Creating directory structure..."
mkdir -p ./output/data/{input,processed,error,output}
mkdir -p ./output/tmp
echo "✓ Directories created:"
echo "  - ./output/data/input/        (PUT YOUR MP4 FILES HERE)"
echo "  - ./output/data/output/       (Results - git-ignored)"
echo "  - ./output/data/processed/"
echo "  - ./output/data/error/"
echo "  - ./output/tmp/"

# Step 2: Copy test videos (optional, comment out if using your own videos)
echo ""
echo "[2/5] Setting up test scene (optional)..."
if [ -d "testdata/south_building_videos" ]; then
    mkdir -p ./output/data/input/my_scene
    cp testdata/south_building_videos/view*.mp4 ./output/data/input/my_scene/ 2>/dev/null || true
    echo "✓ South Building test videos copied to ./output/data/input/my_scene/"
    echo "   (Or copy your own MP4 files to ./output/data/input/<scene_name>/)"
else
    echo "! testdata/south_building_videos not found. Run scripts/e2e/01-download-testdata.sh first, or copy your MP4 files manually to:"
    echo "  ./output/data/input/<your_scene_name>/*.mp4"
fi

# Step 3: Build GPU image
echo ""
echo "[3/5] Building GPU Docker image..."
echo "   This takes ~10-15 minutes..."
docker build --target gpu -t 3dgs-processor:gpu-latest .
echo "✓ GPU image built successfully"

# Step 4: Prepare config
echo ""
echo "[4/5] Setting up configuration..."
if [ ! -f "container-test/config.1.yaml" ]; then
    cp config.example.yaml container-test/config.1.yaml
    echo "✓ Config file created at container-test/config.1.yaml"
else
    echo "✓ Config file already exists"
fi
echo "   (Edit container-test/config.1.yaml to adjust training parameters)"

# Step 5: Start container
echo ""
echo "[5/5] Starting GPU container..."
echo ""
docker compose --profile gpu up 3dgs-processor-gpu &
COMPOSE_PID=$!

echo ""
echo "=========================================="
echo "✓ GPU Container Started!"
echo "=========================================="
echo ""
echo "📂 Where to put your MP4 files:"
echo "   ./output/data/input/<scene_name>/*.mp4"
echo ""
echo "📊 Monitor progress:"
echo "   docker compose logs -f 3dgs-processor-gpu"
echo ""
echo "🏥 Check health status:"
echo "   curl http://localhost:8081/health"
echo ""
echo "📤 Output location (git-ignored):"
echo "   ./output/data/output/"
echo "   Expected files: my_scene.ply, my_scene.splat, manifest.json"
echo ""
echo "🛑 To stop the container:"
echo "   docker compose --profile gpu down 3dgs-processor-gpu"
echo ""
echo "🧹 To remove all output and restart:"
echo "   rm -rf ./output"
echo ""
echo "=========================================="
echo ""
echo "Container is running in background (PID: $COMPOSE_PID)"
echo "Press Ctrl+C to stop tailing logs and keep container running"
echo "Or wait for processing to complete..."
echo ""

# Tail logs (optional - remove this section if you don't want to see logs)
wait $COMPOSE_PID
 
