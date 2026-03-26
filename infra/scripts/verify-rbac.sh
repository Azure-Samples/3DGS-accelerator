#!/usr/bin/env bash
# verify-rbac.sh — Preflight check: verify RBAC role assignments exist
#
# Usage:
#   ./infra/scripts/verify-rbac.sh
#
# Exit codes:
#   0 — All required RBAC roles are assigned
#   1 — One or more RBAC roles are missing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load azd environment values
load_azd_env() {
  if command -v azd &>/dev/null; then
    eval "$(azd env get-values 2>/dev/null)" || true
  fi
}

load_azd_env

# Check if required variables are set (soft fail for preflight)
if [[ -z "${MANAGED_IDENTITY_PRINCIPAL_ID:-}" ]]; then
  echo "⚠️  MANAGED_IDENTITY_PRINCIPAL_ID is not set. Run 'azd provision' first."
  echo "   Skipping RBAC verification (infrastructure not yet provisioned)."
  exit 0
fi

: "${AZURE_CONTAINER_REGISTRY_ID:?ERROR: AZURE_CONTAINER_REGISTRY_ID is not set.}"
: "${AZURE_STORAGE_ACCOUNT_ID:?ERROR: AZURE_STORAGE_ACCOUNT_ID is not set.}"

ACR_PULL_ROLE="7f951dda-4ed3-4680-a7ca-43fe172d538d"
STORAGE_BLOB_CONTRIBUTOR_ROLE="ba92f5b4-2d11-453d-a403-e96b0029c9fe"

MISSING=0

echo "🔍 Verifying RBAC role assignments for Managed Identity..."
echo "   Principal ID: $MANAGED_IDENTITY_PRINCIPAL_ID"
echo ""

# Check AcrPull
ACR_RESULT=$(az role assignment list \
  --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
  --role "$ACR_PULL_ROLE" \
  --scope "$AZURE_CONTAINER_REGISTRY_ID" \
  --query "length(@)" \
  --output tsv 2>/dev/null || echo "0")

if [[ "$ACR_RESULT" -gt 0 ]]; then
  echo "  ✅ AcrPull on Container Registry"
else
  echo "  ❌ AcrPull on Container Registry — MISSING"
  MISSING=$((MISSING + 1))
fi

# Check Storage Blob Data Contributor
STORAGE_RESULT=$(az role assignment list \
  --assignee "$MANAGED_IDENTITY_PRINCIPAL_ID" \
  --role "$STORAGE_BLOB_CONTRIBUTOR_ROLE" \
  --scope "$AZURE_STORAGE_ACCOUNT_ID" \
  --query "length(@)" \
  --output tsv 2>/dev/null || echo "0")

if [[ "$STORAGE_RESULT" -gt 0 ]]; then
  echo "  ✅ Storage Blob Data Contributor on Storage Account"
else
  echo "  ❌ Storage Blob Data Contributor on Storage Account — MISSING"
  MISSING=$((MISSING + 1))
fi

echo ""

if [[ "$MISSING" -gt 0 ]]; then
  echo "⚠️  $MISSING RBAC role assignment(s) missing."
  echo "   Run './infra/scripts/assign-rbac.sh' as a privileged user to fix."
  exit 1
else
  echo "✅ All RBAC role assignments are in place."
  exit 0
fi
