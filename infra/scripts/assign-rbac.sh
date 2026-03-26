#!/usr/bin/env bash
# assign-rbac.sh — Assign RBAC roles to the Managed Identity
# Run this as a privileged user (Owner or User Access Administrator)
#
# Usage:
#   ./infra/scripts/assign-rbac.sh                    # reads from azd env
#   ./infra/scripts/assign-rbac.sh --use-bicep        # deploy via Bicep module
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Load azd environment values
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

# Validate required variables
: "${MANAGED_IDENTITY_PRINCIPAL_ID:?ERROR: MANAGED_IDENTITY_PRINCIPAL_ID is not set. Run 'azd provision' first.}"
: "${AZURE_CONTAINER_REGISTRY_NAME:?ERROR: AZURE_CONTAINER_REGISTRY_NAME is not set.}"
: "${AZURE_CONTAINER_REGISTRY_ID:?ERROR: AZURE_CONTAINER_REGISTRY_ID is not set.}"
: "${AZURE_STORAGE_ACCOUNT_NAME:?ERROR: AZURE_STORAGE_ACCOUNT_NAME is not set.}"
: "${AZURE_STORAGE_ACCOUNT_ID:?ERROR: AZURE_STORAGE_ACCOUNT_ID is not set.}"
: "${AZURE_RESOURCE_GROUP:?ERROR: AZURE_RESOURCE_GROUP is not set.}"

ACR_PULL_ROLE="7f951dda-4ed3-4680-a7ca-43fe172d538d"
STORAGE_BLOB_CONTRIBUTOR_ROLE="ba92f5b4-2d11-453d-a403-e96b0029c9fe"

if [[ "${1:-}" == "--use-bicep" ]]; then
  echo "🔧 Deploying RBAC assignments via Bicep..."
  az deployment group create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --template-file "$ROOT_DIR/infra/rbac/main.bicep" \
    --parameters \
      managedIdentityPrincipalId="$MANAGED_IDENTITY_PRINCIPAL_ID" \
      containerRegistryName="$AZURE_CONTAINER_REGISTRY_NAME" \
      storageAccountName="$AZURE_STORAGE_ACCOUNT_NAME" \
    --name "rbac-$(date +%Y%m%d%H%M%S)"
  echo "✅ RBAC assignments deployed via Bicep."
else
  echo "🔧 Assigning RBAC roles via Azure CLI..."

  echo "  → AcrPull on Container Registry: $AZURE_CONTAINER_REGISTRY_NAME"
  az role assignment create \
    --assignee-object-id "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$ACR_PULL_ROLE" \
    --scope "$AZURE_CONTAINER_REGISTRY_ID" \
    --output none 2>/dev/null || echo "    (already assigned or created)"

  echo "  → Storage Blob Data Contributor on Storage Account: $AZURE_STORAGE_ACCOUNT_NAME"
  az role assignment create \
    --assignee-object-id "$MANAGED_IDENTITY_PRINCIPAL_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "$STORAGE_BLOB_CONTRIBUTOR_ROLE" \
    --scope "$AZURE_STORAGE_ACCOUNT_ID" \
    --output none 2>/dev/null || echo "    (already assigned or created)"

  echo "✅ RBAC roles assigned successfully."
fi
