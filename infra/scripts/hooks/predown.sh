#!/usr/bin/env bash
# predown.sh — azd predown hook
#
# Blocks 'azd down' when the environment is configured to reuse existing
# Azure resources. This prevents accidental deletion of shared infrastructure.
#
# Override with: azd env set FORCE_DELETE true
set -euo pipefail

EXISTING_RG=$(azd env get-value EXISTING_RESOURCE_GROUP 2>/dev/null || echo "")
EXISTING_ACR=$(azd env get-value EXISTING_ACR_NAME 2>/dev/null || echo "")
EXISTING_STORAGE=$(azd env get-value EXISTING_STORAGE_ACCOUNT_NAME 2>/dev/null || echo "")
EXISTING_ENV=$(azd env get-value EXISTING_CONTAINER_APPS_ENV_NAME 2>/dev/null || echo "")
EXISTING_LAW=$(azd env get-value EXISTING_LOG_ANALYTICS_NAME 2>/dev/null || echo "")

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

FORCE_DELETE=$(azd env get-value FORCE_DELETE 2>/dev/null || echo "")

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
