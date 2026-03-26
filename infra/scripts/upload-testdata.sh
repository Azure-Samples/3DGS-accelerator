#!/usr/bin/env bash
# upload-testdata.sh — Upload South Building test videos to Azure Blob Storage
#
# Downloads the COLMAP South Building dataset (if needed) and uploads
# the test videos to the Azure Storage account's 'input' container.
#
# Usage:
#   ./infra/scripts/upload-testdata.sh                          # default prefix: south_building/
#   ./infra/scripts/upload-testdata.sh --prefix my_scene/       # custom prefix
#   ./infra/scripts/upload-testdata.sh --download-only          # just download, don't upload
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

BLOB_PREFIX="south_building/"
DOWNLOAD_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) BLOB_PREFIX="$2"; shift 2 ;;
    --download-only) DOWNLOAD_ONLY=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

VIDEO_DIR="$ROOT_DIR/testdata/south_building_videos"

# ── Step 1: Download test data if not present ────────────────────────────────
if [ ! -d "$VIDEO_DIR" ] || [ "$(find "$VIDEO_DIR" -name '*.mp4' 2>/dev/null | wc -l)" -lt 3 ]; then
  echo "📥 Test videos not found. Running download script..."
  echo ""
  "$ROOT_DIR/scripts/e2e/01-download-testdata.sh"
  echo ""
fi

# Verify videos exist
VIDEO_COUNT=$(find "$VIDEO_DIR" -name '*.mp4' 2>/dev/null | wc -l)
if [[ "$VIDEO_COUNT" -lt 1 ]]; then
  echo "❌ No test videos found in $VIDEO_DIR"
  echo "   Run: ./scripts/e2e/01-download-testdata.sh"
  exit 1
fi

echo "📁 Found $VIDEO_COUNT test video(s) in $VIDEO_DIR"

if [[ "$DOWNLOAD_ONLY" == "true" ]]; then
  echo "✅ Download complete (--download-only). Skipping upload."
  exit 0
fi

# ── Step 2: Load azd environment and upload to blob storage ──────────────────
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

: "${AZURE_STORAGE_ACCOUNT_NAME:?ERROR: AZURE_STORAGE_ACCOUNT_NAME is not set. Run 'azd provision' first.}"

CONTAINER_NAME="input"

echo ""
echo "📤 Uploading test videos to Azure Blob Storage..."
echo "   Storage Account: $AZURE_STORAGE_ACCOUNT_NAME"
echo "   Container:       $CONTAINER_NAME"
echo "   Blob Prefix:     $BLOB_PREFIX"
echo ""

for video in "$VIDEO_DIR"/*.mp4; do
  FILENAME=$(basename "$video")
  BLOB_NAME="${BLOB_PREFIX}${FILENAME}"
  SIZE=$(stat -c %s "$video" 2>/dev/null || stat -f %z "$video" 2>/dev/null || echo "?")
  SIZE_MB=$(( ${SIZE:-0} / 1048576 ))

  echo "  → Uploading $FILENAME (${SIZE_MB}MB) → $BLOB_NAME"
  az storage blob upload \
    --account-name "$AZURE_STORAGE_ACCOUNT_NAME" \
    --container-name "$CONTAINER_NAME" \
    --name "$BLOB_NAME" \
    --file "$video" \
    --overwrite true \
    --auth-mode login \
    --output none
done

echo ""
echo "✅ Test videos uploaded successfully."
echo ""
echo "   To run the job with this data:"
echo "   BATCH_INPUT_PREFIX=\"$BLOB_PREFIX\" ./infra/scripts/run-job.sh --logs"
