#!/usr/bin/env bash
# cleanup-rbac.sh — Remove RBAC role assignments from the Managed Identity
# Run this as a privileged user before 'azd down' or for cleanup.
#
# Usage:
#   ./infra/scripts/cleanup-rbac.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load azd environment values
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

: "${MANAGED_IDENTITY_PRINCIPAL_ID:?ERROR: MANAGED_IDENTITY_PRINCIPAL_ID is not set.}"
: "${AZURE_CONTAINER_REGISTRY_ID:?ERROR: AZURE_CONTAINER_REGISTRY_ID is not set.}"
: "${AZURE_STORAGE_ACCOUNT_ID:?ERROR: AZURE_STORAGE_ACCOUNT_ID is not set.}"

ACR_PULL_ROLE="7f951dda-4ed3-4680-a7ca-43fe172d538d"
STORAGE_BLOB_CONTRIBUTOR_ROLE="ba92f5b4-2d11-453d-a403-e96b0029c9fe"

echo "🧹 Removing RBAC role assignments for Managed Identity..."
echo "   Principal ID: $MANAGED_IDENTITY_PRINCIPAL_ID"
echo ""

echo "  → Removing AcrPull on Container Registry..."
az role assignment delete \
  --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
  --role "$ACR_PULL_ROLE" \
  --scope "$AZURE_CONTAINER_REGISTRY_ID" \
  --yes \
  --output none 2>/dev/null || echo "    (not found or already removed)"

echo "  → Removing Storage Blob Data Contributor on Storage Account..."
az role assignment delete \
  --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
  --role "$STORAGE_BLOB_CONTRIBUTOR_ROLE" \
  --scope "$AZURE_STORAGE_ACCOUNT_ID" \
  --yes \
  --output none 2>/dev/null || echo "    (not found or already removed)"

echo ""
echo "✅ RBAC role assignments removed."
