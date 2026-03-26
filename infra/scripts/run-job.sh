#!/usr/bin/env bash
# run-job.sh — Submit (start) a Container Apps Job execution
#
# Usage:
#   ./infra/scripts/run-job.sh              # start and return immediately
#   ./infra/scripts/run-job.sh --wait       # start and wait for completion
#   ./infra/scripts/run-job.sh --logs       # start, wait, then show logs
#
# Environment overrides:
#   BATCH_INPUT_PREFIX=south_building/    # override the blob prefix for the job
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WAIT=false
SHOW_LOGS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait) WAIT=true; shift ;;
    --logs) WAIT=true; SHOW_LOGS=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Load azd environment values
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

: "${JOB_NAME:?ERROR: JOB_NAME is not set. Run 'azd provision' first.}"
: "${AZURE_RESOURCE_GROUP:?ERROR: AZURE_RESOURCE_GROUP is not set.}"

BATCH_PREFIX="${BATCH_INPUT_PREFIX:-south_building/}"

echo "🚀 Starting job execution..."
echo "   Job:            $JOB_NAME"
echo "   Resource Group: $AZURE_RESOURCE_GROUP"
echo "   Batch Prefix:   $BATCH_PREFIX"
echo ""

# Update the job's BATCH_INPUT_PREFIX env var before starting
az containerapp job update \
  --name "$JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --set-env-vars "BATCH_INPUT_PREFIX=${BATCH_PREFIX}" \
  --output none 2>/dev/null

# Start the job
EXECUTION=$(az containerapp job start \
  --name "$JOB_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --query "name" \
  --output tsv 2>/dev/null)

if [[ -z "$EXECUTION" ]]; then
  echo "❌ Failed to start job execution."
  exit 1
fi

echo "✅ Job execution started: $EXECUTION"

if [[ "$WAIT" == "true" ]]; then
  echo ""
  echo "⏳ Waiting for execution to complete..."

  while true; do
    STATUS=$(az containerapp job execution show \
      --name "$JOB_NAME" \
      --resource-group "$AZURE_RESOURCE_GROUP" \
      --job-execution-name "$EXECUTION" \
      --query "properties.status" \
      --output tsv 2>/dev/null || echo "Unknown")

    case "$STATUS" in
      Succeeded)
        echo "✅ Job execution completed successfully."
        break
        ;;
      Failed)
        echo "❌ Job execution failed."
        SHOW_LOGS=true
        break
        ;;
      Running|Processing)
        echo "   Status: $STATUS (checking again in 30s...)"
        sleep 30
        ;;
      *)
        echo "   Status: $STATUS (checking again in 15s...)"
        sleep 15
        ;;
    esac
  done

  if [[ "$SHOW_LOGS" == "true" ]]; then
    echo ""
    echo "📋 Fetching execution logs..."
    # Retry log retrieval (logs can lag behind completion)
    for attempt in 1 2 3; do
      LOGS=$(az containerapp job logs show \
        --name "$JOB_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --execution "$EXECUTION" \
        --container "main" \
        --follow false \
        2>/dev/null || echo "")

      if [[ -n "$LOGS" ]]; then
        echo "$LOGS"
        break
      fi

      if [[ $attempt -lt 3 ]]; then
        echo "   (Logs not yet available — retrying in 15s...)"
        sleep 15
      else
        echo "   (Logs not available yet. Retrieve manually:)"
        echo "   az containerapp job logs show --name $JOB_NAME --resource-group $AZURE_RESOURCE_GROUP --execution $EXECUTION --container main"
      fi
    done
  fi
fi
