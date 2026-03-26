#!/usr/bin/env bash
# preprovision.sh — azd preprovision hook
# 1. Captures the deployer's principal ID for RBAC assignments
# 2. Runs RBAC preflight check (non-blocking)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ── Capture deployer identity for Bicep RBAC assignments ─────────────────────
echo "🔑 Detecting deployer identity..."
DEPLOYER_PRINCIPAL_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")

if [[ -n "$DEPLOYER_PRINCIPAL_ID" ]]; then
  echo "   Principal ID: $DEPLOYER_PRINCIPAL_ID"
  azd env set DEPLOYER_PRINCIPAL_ID "$DEPLOYER_PRINCIPAL_ID"
else
  echo "   ⚠️  Could not detect signed-in user. Deployer RBAC will be skipped."
  azd env set DEPLOYER_PRINCIPAL_ID ""
fi

echo ""

# ── RBAC preflight check ─────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════╗"
echo "║  RBAC Preflight Check                        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

if "$ROOT_DIR/infra/scripts/verify-rbac.sh"; then
  echo ""
  echo "Proceeding with provisioning..."
else
  echo ""
  echo "────────────────────────────────────────────────"
  echo "RBAC roles are not yet assigned. This is expected"
  echo "on first run. After 'azd provision' completes, ask a"
  echo "privileged user to run:"
  echo ""
  echo "  ./infra/scripts/assign-rbac.sh"
  echo ""
  echo "Continuing with provisioning..."
  echo "────────────────────────────────────────────────"
fi
