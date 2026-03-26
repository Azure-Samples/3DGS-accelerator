#!/usr/bin/env bash
# postprovision.sh — azd postprovision hook
#
# Runs after infrastructure is provisioned:
# 1. Builds the GPU container image via ACR Tasks (no local Docker required)
# 2. Updates the Container Apps Job to use the freshly built image
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════╗"
echo "║  Post-Provision: ACR GPU Image Build         ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: Build image on ACR ───────────────────────────────────────────────
"$SCRIPT_DIR/acr-build.sh"

# ── Step 2: Update the Container Apps Job with the new image ─────────────────
JOB_IMAGE=$(azd env get-value JOB_IMAGE 2>/dev/null || echo "")
JOB_NAME=$(azd env get-value JOB_NAME 2>/dev/null || echo "")
RESOURCE_GROUP=$(azd env get-value AZURE_RESOURCE_GROUP 2>/dev/null || echo "")

if [[ -n "$JOB_IMAGE" && -n "$JOB_NAME" && -n "$RESOURCE_GROUP" ]]; then
  echo ""
  echo "🔄 Updating Container Apps Job with new image..."
  echo "   Job   : $JOB_NAME"
  echo "   Image : $JOB_IMAGE"
  az containerapp job update \
    --name "$JOB_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "$JOB_IMAGE" \
    --output none
  echo "✅ Job updated."
else
  echo ""
  echo "⚠️  Could not update job (missing JOB_NAME or AZURE_RESOURCE_GROUP)."
  echo "   Run './infra/scripts/deploy-job.sh' to apply the image to the job."
fi
