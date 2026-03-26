#!/usr/bin/env bash
# deploy-job.sh — Build the container image on ACR and deploy to the Container Apps Job.
#
# This replaces 'azd deploy' for this project. It:
#   1. Builds the GPU Docker image via ACR Tasks (no local Docker required)
#   2. Deploys the image by updating the Container Apps Job
#
# Usage:
#   ./infra/scripts/deploy-job.sh            # build + deploy
#   ./infra/scripts/deploy-job.sh --skip-build   # deploy existing image (skip ACR build)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

SKIP_BUILD=false
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
  esac
done

cd "$ROOT_DIR"

# ── Step 1: Build image on ACR ───────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  "$SCRIPT_DIR/hooks/acr-build.sh"
else
  echo "⏭️  Skipping ACR build (--skip-build)"
fi

# ── Step 2: Update the Container Apps Job ────────────────────────────────────
JOB_IMAGE=$(azd env get-value JOB_IMAGE 2>/dev/null || echo "")
JOB_NAME=$(azd env get-value JOB_NAME 2>/dev/null || echo "")
RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")

if [[ -z "$JOB_IMAGE" ]]; then
  echo "❌ JOB_IMAGE not set. Run without --skip-build first."
  exit 1
fi

echo ""
echo "🚀 Deploying image to Container Apps Job..."
echo "   Job   : $JOB_NAME"
echo "   Image : $JOB_IMAGE"
echo ""

az containerapp job update \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "$JOB_IMAGE" \
  --output none

echo "✅ Deploy complete."
