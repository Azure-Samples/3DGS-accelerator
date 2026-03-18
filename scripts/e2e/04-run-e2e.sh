#!/usr/bin/env bash
# 04-run-e2e.sh — Run the full E2E pipeline test (file mode + batch mode)
#
# This script runs TWO E2E tests:
#
# Part A — File (Watch) Mode:
#   1. Cleans up from any prior run (calls 03-cleanup.sh)
#   2. Starts the 3dgs-processor in background (watch mode)
#   3. Copies test videos into the input directory to trigger a job
#   4. Waits for output to appear in ./output/data/output/
#   5. Verifies the output (PLY, SPLAT, manifest files)
#   6. Shuts down the processor gracefully
#
# Part B — Batch Mode (Azurite):
#   1. Starts Azurite (Azure Storage emulator) in Docker
#   2. Creates blob containers, uploads test videos
#   3. Runs the processor in batch mode (single run → exit)
#   4. Verifies outputs in Azurite blob storage
#   5. Stops Azurite
#
# Environment:
#   Uses mock training backend (no GPU required).
#   Uses real COLMAP for reconstruction.
#   Uses real FFmpeg for frame extraction.
#
# Usage:
#   ./scripts/e2e/04-run-e2e.sh                      # run both modes
#   ./scripts/e2e/04-run-e2e.sh --timeout 600         # custom timeout
#   ./scripts/e2e/04-run-e2e.sh --mode file           # file mode only
#   ./scripts/e2e/04-run-e2e.sh --mode batch          # batch mode only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/../.."
BINARY="$PROJECT_ROOT/target/release/3dgs-processor"

# Parse arguments
TIMEOUT=900
RUN_FILE=true
RUN_BATCH=true
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --mode)
            case $2 in
                file|watch) RUN_FILE=true; RUN_BATCH=false ;;
                batch) RUN_FILE=false; RUN_BATCH=true ;;
                all|both) RUN_FILE=true; RUN_BATCH=true ;;
                *) echo "Unknown mode: $2 (use: file, batch, all)"; exit 1 ;;
            esac
            shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

echo "============================================"
echo "  04 — Run E2E Pipeline Test"
echo "============================================"
echo ""

# Check prerequisites
if [ ! -f "$BINARY" ]; then
    echo "❌ Binary not found at $BINARY"
    echo "   Run 02-build.sh first."
    exit 1
fi

if ! command -v ffmpeg &>/dev/null; then
    echo "❌ ffmpeg not found. Run 00-install-deps.sh first."
    exit 1
fi

if ! command -v colmap &>/dev/null; then
    echo "❌ colmap not found. Run 00-install-deps.sh first."
    exit 1
fi

# Determine test video source
VIDEO_SRC="$PROJECT_ROOT/testdata/south_building_videos"
if [ ! -d "$VIDEO_SRC" ] || [ "$(ls "$VIDEO_SRC"/*.mp4 2>/dev/null | wc -l)" -lt 2 ]; then
    echo "⚠️  South Building videos not found, falling back to sample_scene videos"
    VIDEO_SRC="$PROJECT_ROOT/testdata/sample_scene"
fi

echo "📹 Test video source: $VIDEO_SRC"
ls -lh "$VIDEO_SRC"/*.mp4 2>/dev/null
echo ""

# Common environment variables for both modes
export BACKEND="mock"
export FORCE_CPU_BACKEND="1"
export COLMAP_USE_CPU="1"           # Force COLMAP to CPU-only (no GPU/OpenGL needed)
export RECONSTRUCTION_BACKEND="colmap"
export FRAME_RATE="2"
export MIN_VIDEO_FRAMES="5"
export MIN_VIDEO_DURATION="0.5"
export COLMAP_MATCHER="sequential"
export COLMAP_MAX_NUM_FEATURES="2048"
export MIN_RECONSTRUCTION_POINTS="100"
export LOG_LEVEL="info"
export MAX_RETRIES="1"

# Track overall result
FILE_RESULT="skipped"
BATCH_RESULT="skipped"

###############################################################################
# PART A: FILE (WATCH) MODE
###############################################################################
if [ "$RUN_FILE" = true ]; then

echo "╔═══════════════════════════════════════════╗"
echo "║  Part A: File (Watch) Mode E2E Test       ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

# Step 1: Clean up
echo "━━━ Step A1: Cleaning up ━━━"
"$SCRIPT_DIR/03-cleanup.sh"
rm -rf /tmp/3dgs-work

DATA_ROOT="$PROJECT_ROOT/output/data"
INPUT_DIR="$DATA_ROOT/input"
OUTPUT_DIR="$DATA_ROOT/output"
PROCESSED_DIR="$DATA_ROOT/processed"
ERROR_DIR="$DATA_ROOT/error"

# Step 2: Start the processor in watch mode
echo "━━━ Step A2: Starting 3dgs-processor (watch mode) ━━━"
echo ""

export INPUT_PATH="$INPUT_DIR"
export OUTPUT_PATH="$OUTPUT_DIR"
export PROCESSED_PATH="$PROCESSED_DIR"
export ERROR_PATH="$ERROR_DIR"
export TEMP_PATH="/tmp/3dgs-work"
export UPLOAD_STABILITY_TIMEOUT_SECS="5"
export POLL_INTERVAL_SECS="2"

# Ensure NOT in batch mode
unset RUN_MODE 2>/dev/null || true
unset AZURE_STORAGE_ACCOUNT 2>/dev/null || true
unset AZURE_STORAGE_ENDPOINT 2>/dev/null || true
unset AZURE_STORAGE_SAS_TOKEN 2>/dev/null || true
unset BATCH_INPUT_PREFIX 2>/dev/null || true

echo "📋 Environment:"
echo "  INPUT_PATH=$INPUT_PATH"
echo "  OUTPUT_PATH=$OUTPUT_PATH"
echo "  PROCESSED_PATH=$PROCESSED_PATH"
echo "  ERROR_PATH=$ERROR_PATH"
echo "  BACKEND=$BACKEND"
echo "  RECONSTRUCTION_BACKEND=$RECONSTRUCTION_BACKEND"
echo "  FRAME_RATE=$FRAME_RATE"
echo "  UPLOAD_STABILITY_TIMEOUT_SECS=$UPLOAD_STABILITY_TIMEOUT_SECS"
echo "  POLL_INTERVAL_SECS=$POLL_INTERVAL_SECS"
echo ""

# Start processor in background, log to file
LOG_FILE="$PROJECT_ROOT/output/e2e-processor.log"
echo "🚀 Starting processor (log: $LOG_FILE)..."
"$BINARY" > "$LOG_FILE" 2>&1 &
PROCESSOR_PID=$!

echo "  PID: $PROCESSOR_PID"

# Give it a moment to start
sleep 3

# Check it's still running
if ! kill -0 "$PROCESSOR_PID" 2>/dev/null; then
    echo "❌ Processor exited immediately. Last 30 lines of log:"
    tail -30 "$LOG_FILE"
    exit 1
fi

echo "  ✅ Processor is running"
echo ""

# Cleanup function to kill processor on exit
file_mode_cleanup() {
    if [ -n "${PROCESSOR_PID:-}" ] && kill -0 "$PROCESSOR_PID" 2>/dev/null; then
        echo "  Sending SIGTERM to PID $PROCESSOR_PID..."
        kill "$PROCESSOR_PID" 2>/dev/null || true
        for i in $(seq 1 10); do
            if ! kill -0 "$PROCESSOR_PID" 2>/dev/null; then
                echo "  ✅ Processor shut down gracefully"
                return
            fi
            sleep 1
        done
        echo "  ⚠️  Force-killing processor..."
        kill -9 "$PROCESSOR_PID" 2>/dev/null || true
    fi
}

# Step 3: Trigger a job by copying videos
echo "━━━ Step A3: Triggering job ━━━"
SCENE_DIR="$INPUT_DIR/my_scene"
mkdir -p "$SCENE_DIR"

echo "📁 Copying test videos to $SCENE_DIR..."
cp "$VIDEO_SRC"/view*.mp4 "$SCENE_DIR/"
echo "  ✅ Copied $(ls "$SCENE_DIR"/*.mp4 | wc -l) video files"
echo ""

# Step 4: Wait for output
echo "━━━ Step A4: Waiting for output (timeout: ${TIMEOUT}s) ━━━"
echo ""

ELAPSED=0
POLL=5
SUCCESS=false

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    # Check if processor crashed
    if ! kill -0 "$PROCESSOR_PID" 2>/dev/null; then
        echo ""
        echo "❌ Processor exited unexpectedly!"
        echo ""
        echo "📋 Last 50 lines of log:"
        tail -50 "$LOG_FILE"
        exit 1
    fi
    
    # Check for output files
    OUTPUT_FILES=$(find "$OUTPUT_DIR" -type f \( -name '*.ply' -o -name '*.splat' -o -name 'manifest.json' \) 2>/dev/null | wc -l)
    
    # Check if job moved to processed (success) or error (failure)
    PROCESSED_COUNT=$(find "$PROCESSED_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    ERROR_COUNT=$(find "$ERROR_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    
    if [ "$OUTPUT_FILES" -gt 0 ] && [ "$PROCESSED_COUNT" -gt 0 ]; then
        echo ""
        echo "🎉 Output detected!"
        SUCCESS=true
        break
    fi
    
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo ""
        echo "❌ Job moved to error directory!"
        echo ""
        echo "📋 Error directory contents:"
        find "$ERROR_DIR" -type f | head -20
        echo ""
        echo "📋 Last 80 lines of log:"
        tail -80 "$LOG_FILE"
        exit 1
    fi
    
    # Print status every 15 seconds
    if [ $((ELAPSED % 15)) -eq 0 ]; then
        STAGE=$(grep -oP 'Step \d+: \K[^"]*' "$LOG_FILE" 2>/dev/null | tail -1 || echo "starting...")
        echo "  ⏳ ${ELAPSED}s elapsed — stage: ${STAGE:-waiting...}"
    fi
    
    sleep "$POLL"
    ELAPSED=$((ELAPSED + POLL))
done

if [ "$SUCCESS" = false ]; then
    echo ""
    echo "❌ Timeout after ${TIMEOUT}s — no output produced"
    echo ""
    echo "📋 Last 80 lines of log:"
    tail -80 "$LOG_FILE"
    exit 1
fi

# Step 5: Verify output
echo ""
echo "━━━ Step A5: Verifying output ━━━"
echo ""

echo "📁 Output directory contents:"
find "$OUTPUT_DIR" -type f -exec ls -lh {} \;
echo ""

echo "📁 Processed directory:"
find "$PROCESSED_DIR" -maxdepth 2 -type d
echo ""

# Check for expected files
PLY_COUNT=$(find "$OUTPUT_DIR" -name '*.ply' | wc -l)
SPLAT_COUNT=$(find "$OUTPUT_DIR" -name '*.splat' | wc -l)
MANIFEST_COUNT=$(find "$OUTPUT_DIR" -name 'manifest.json' | wc -l)

PASS=true
echo "📊 Output verification:"

if [ "$PLY_COUNT" -gt 0 ]; then
    PLY_FILE=$(find "$OUTPUT_DIR" -name '*.ply' | head -1)
    PLY_SIZE=$(du -h "$PLY_FILE" | cut -f1)
    echo "  ✅ PLY file(s):      $PLY_COUNT ($PLY_SIZE)"
else
    echo "  ❌ PLY file(s):      MISSING"
    PASS=false
fi

if [ "$SPLAT_COUNT" -gt 0 ]; then
    SPLAT_FILE=$(find "$OUTPUT_DIR" -name '*.splat' | head -1)
    SPLAT_SIZE=$(du -h "$SPLAT_FILE" | cut -f1)
    echo "  ✅ SPLAT file(s):    $SPLAT_COUNT ($SPLAT_SIZE)"
else
    echo "  ❌ SPLAT file(s):    MISSING"
    PASS=false
fi

if [ "$MANIFEST_COUNT" -gt 0 ]; then
    echo "  ✅ manifest.json:    present"
else
    echo "  ❌ manifest.json:    MISSING"
    PASS=false
fi

# Shut down processor
echo ""
echo "━━━ Shutting down file-mode processor ━━━"
file_mode_cleanup
PROCESSOR_PID=""

if [ "$PASS" = true ]; then
    echo ""
    echo "🎉 Part A (File Mode): PASSED"
    FILE_RESULT="passed"
else
    echo ""
    echo "❌ Part A (File Mode): FAILED"
    FILE_RESULT="failed"
fi
echo ""

fi  # end RUN_FILE

###############################################################################
# PART B: BATCH MODE (AZURITE)
###############################################################################
if [ "$RUN_BATCH" = true ]; then

echo "╔═══════════════════════════════════════════╗"
echo "║  Part B: Batch Mode E2E Test (Azurite)    ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

# Check Docker
if ! command -v docker &>/dev/null; then
    echo "❌ Docker not found. Batch mode E2E requires Docker for Azurite."
    BATCH_RESULT="failed"
else

# Set up Python venv for azure-storage-blob
VENV_DIR="$PROJECT_ROOT/output/.e2e-venv"
if [ ! -d "$VENV_DIR" ]; then
    echo "📦 Creating Python venv for Azurite helper..."
    python3 -m venv "$VENV_DIR"
fi
# Activate venv and install dependency if needed
source "$VENV_DIR/bin/activate"
if ! python3 -c "import azure.storage.blob" 2>/dev/null; then
    echo "📦 Installing azure-storage-blob in venv..."
    pip install --quiet azure-storage-blob 2>&1
fi

AZURITE_CONTAINER="azurite-e2e-$(date +%s)"
AZURITE_PORT=10000
BATCH_LOG="$PROJECT_ROOT/output/e2e-batch.log"
BATCH_PREFIX="my_scene/"

# Step B1: Start Azurite
echo "━━━ Step B1: Starting Azurite ━━━"

# Stop any existing Azurite on this port
docker ps -q --filter "publish=${AZURITE_PORT}" | xargs -r docker stop 2>/dev/null || true
sleep 1

docker run -d --rm --name "$AZURITE_CONTAINER" \
    -p "${AZURITE_PORT}:10000" \
    mcr.microsoft.com/azure-storage/azurite \
    azurite-blob --blobHost 0.0.0.0 --blobPort 10000 --skipApiVersionCheck

# Wait for Azurite to be ready
echo "  Waiting for Azurite to start..."
for i in $(seq 1 15); do
    if curl -s "http://127.0.0.1:${AZURITE_PORT}/" >/dev/null 2>&1; then
        echo "  ✅ Azurite is running (container: $AZURITE_CONTAINER)"
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "  ❌ Azurite failed to start"
        docker logs "$AZURITE_CONTAINER" 2>&1 | tail -10
        docker stop "$AZURITE_CONTAINER" 2>/dev/null || true
        BATCH_RESULT="failed"
        # Jump to results
        RUN_BATCH=false
    fi
    sleep 1
done

# Cleanup function for Azurite
batch_cleanup() {
    if docker ps -q --filter "name=$AZURITE_CONTAINER" 2>/dev/null | grep -q .; then
        echo "  Stopping Azurite container..."
        docker stop "$AZURITE_CONTAINER" 2>/dev/null || true
        echo "  ✅ Azurite stopped"
    fi
}

if [ "$RUN_BATCH" = true ]; then

# Step B2: Setup blob storage (create containers, upload videos)
echo ""
echo "━━━ Step B2: Setting up Azurite blob storage ━━━"
echo ""

python3 "$SCRIPT_DIR/azurite_helper.py" setup "$VIDEO_SRC" "$BATCH_PREFIX"
echo ""

# Generate SAS token
SAS_TOKEN=$(python3 "$SCRIPT_DIR/azurite_helper.py" sas)
echo "  ✅ SAS token generated"
echo ""

# Step B3: Run batch mode processor
echo "━━━ Step B3: Running processor in batch mode ━━━"
echo ""

# Clean temp dirs
rm -rf /tmp/3dgs-work

echo "📋 Batch Environment:"
echo "  RUN_MODE=batch"
echo "  AZURE_STORAGE_ACCOUNT=devstoreaccount1"
echo "  AZURE_STORAGE_ENDPOINT=http://127.0.0.1:${AZURITE_PORT}/devstoreaccount1"
echo "  BATCH_INPUT_PREFIX=$BATCH_PREFIX"
echo "  BACKEND=$BACKEND"
echo ""

echo "🚀 Starting processor in batch mode (log: $BATCH_LOG)..."

BATCH_EXIT=0
RUN_MODE=batch \
  AZURE_STORAGE_ACCOUNT=devstoreaccount1 \
  AZURE_STORAGE_ENDPOINT="http://127.0.0.1:${AZURITE_PORT}/devstoreaccount1" \
  AZURE_STORAGE_SAS_TOKEN="$SAS_TOKEN" \
  BATCH_INPUT_PREFIX="$BATCH_PREFIX" \
  TEMP_PATH="/tmp/3dgs-work" \
  "$BINARY" > "$BATCH_LOG" 2>&1 || BATCH_EXIT=$?

if [ "$BATCH_EXIT" -eq 0 ]; then
    echo "  ✅ Processor exited with code 0 (success)"
else
    echo "  ❌ Processor exited with code $BATCH_EXIT (failure)"
    echo ""
    echo "📋 Last 50 lines of batch log:"
    tail -50 "$BATCH_LOG"
fi
echo ""

# Step B4: Verify outputs in Azurite
echo "━━━ Step B4: Verifying batch outputs in Azurite ━━━"
echo ""

echo "📊 Blob storage verification:"
VERIFY_EXIT=0
python3 "$SCRIPT_DIR/azurite_helper.py" verify "my_scene/" || VERIFY_EXIT=$?

# Step B5: Cleanup Azurite
echo ""
echo "━━━ Step B5: Stopping Azurite ━━━"
batch_cleanup

if [ "$BATCH_EXIT" -eq 0 ] && [ "$VERIFY_EXIT" -eq 0 ]; then
    echo ""
    echo "🎉 Part B (Batch Mode): PASSED"
    BATCH_RESULT="passed"
else
    echo ""
    echo "❌ Part B (Batch Mode): FAILED"
    BATCH_RESULT="failed"
fi
echo ""

fi  # end RUN_BATCH inner check
fi  # end docker check

# Deactivate venv if it was activated
deactivate 2>/dev/null || true

fi  # end RUN_BATCH

###############################################################################
# FINAL RESULTS
###############################################################################
echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║            E2E Test Results               ║"
echo "╠═══════════════════════════════════════════╣"
printf "║  File (Watch) Mode: %-21s ║\n" "$FILE_RESULT"
printf "║  Batch Mode:        %-21s ║\n" "$BATCH_RESULT"
echo "╚═══════════════════════════════════════════╝"
echo ""

if [ "$FILE_RESULT" = "failed" ] || [ "$BATCH_RESULT" = "failed" ]; then
    echo "❌ E2E TEST FAILED"
    exit 1
fi

echo "🎉 ALL E2E TESTS PASSED!"
exit 0
