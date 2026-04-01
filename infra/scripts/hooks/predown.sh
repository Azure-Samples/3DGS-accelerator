#!/usr/bin/env bash
# predown.sh — azd predown hook
#
# Blocks 'azd down' when the environment is configured to reuse existing
# Azure resources. This prevents accidental deletion of shared infrastructure.
#
# Override with: azd env set FORCE_DELETE true
set -euo pipefail

# Read all env values once — azd env get-value prints errors to stdout for
# missing keys, so we parse the full key=value dump instead.
_env_values=$(azd env get-values 2>/dev/null || true)
_get() { echo "$_env_values" | grep "^$1=" | cut -d= -f2- | tr -d '"' || true; }

EXISTING_RG=$(_get EXISTING_RESOURCE_GROUP)
EXISTING_ACR=$(_get EXISTING_ACR_NAME)
EXISTING_STORAGE=$(_get EXISTING_STORAGE_ACCOUNT_NAME)
EXISTING_ENV=$(_get EXISTING_CONTAINER_APPS_ENV_NAME)
EXISTING_LAW=$(_get EXISTING_LOG_ANALYTICS_NAME)

HAS_EXISTING=false
EXISTING_LIST=""

if [[ -n "$EXISTING_RG" ]]; then
  HAS_EXISTING=true
  EXISTING_LIST+="   • Resource Group:             $EXISTING_RG\n"
fi
if [[ -n "$EXISTING_ACR" ]]; then
  HAS_EXISTING=true
  EXISTING_LIST+="   • Container Registry:         $EXISTING_ACR\n"
fi
if [[ -n "$EXISTING_STORAGE" ]]; then
  HAS_EXISTING=true
  EXISTING_LIST+="   • Storage Account:            $EXISTING_STORAGE\n"
fi
if [[ -n "$EXISTING_ENV" ]]; then
  HAS_EXISTING=true
  EXISTING_LIST+="   • Container Apps Environment: $EXISTING_ENV\n"
fi
if [[ -n "$EXISTING_LAW" ]]; then
  HAS_EXISTING=true
  EXISTING_LIST+="   • Log Analytics Workspace:    $EXISTING_LAW\n"
fi

if [[ "$HAS_EXISTING" != "true" ]]; then
  echo "No existing resources configured — proceeding with azd down."
  exit 0
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ⚠️  EXISTING RESOURCES DETECTED                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "This environment references pre-existing Azure resources:"
echo ""
echo -e "$EXISTING_LIST"
echo ""
echo "Running 'azd down' would delete the resource group and ALL"
echo "resources inside it, including those listed above."
echo ""

FORCE_DELETE=$(_get FORCE_DELETE)

if [[ "$FORCE_DELETE" == "true" ]]; then
  echo "⚡ FORCE_DELETE=true is set. Proceeding with deletion..."
  echo ""
  echo "To undo this override:  azd env set FORCE_DELETE false"
  exit 0
fi

echo "To proceed anyway, explicitly opt in:"
echo ""
echo "  azd env set FORCE_DELETE true"
echo "  azd down"
echo ""
echo "To remove the existing resource configuration:"
echo ""
echo "  ./scripts/configure-existing-resources.sh --reset"
echo ""
echo "Aborting to protect existing resources."
exit 1
