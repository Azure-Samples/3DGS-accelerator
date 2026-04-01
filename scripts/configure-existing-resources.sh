#!/usr/bin/env bash
# configure-existing-resources.sh
#
# Interactive script to configure an azd environment to reuse existing Azure
# resources (Resource Group, ACR, Storage Account, Container Apps Environment).
#
# Run after 'azd init' and before 'azd provision'. Can be rerun at any time.
#
# Usage:
#   ./scripts/configure-existing-resources.sh          # Interactive mode
#   ./scripts/configure-existing-resources.sh --reset   # Clear existing config
#   ./scripts/configure-existing-resources.sh --help    # Show help
set -euo pipefail

# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
Usage: ./scripts/configure-existing-resources.sh [OPTIONS]

Interactively select existing Azure resources to reuse with this deployment.
Selected resources are referenced via Bicep's `existing` keyword — they are
NOT managed by the deployment and will NOT be deleted by 'azd down'.

Options:
  --reset   Clear all existing resource configuration (create fresh resources)
  --help    Show this help message

Resources that can be reused:
  • Resource Group
  • Azure Container Registry (ACR)
  • Storage Account
  • Container Apps Environment
  • Log Analytics Workspace

Resources always managed by the deployment:
  • Managed Identity
  • Container Apps Job

Prerequisites:
  • Azure CLI (az) — logged in
  • Azure Developer CLI (azd) — environment initialized
EOF
  exit 0
fi

# ── Prerequisites ────────────────────────────────────────────────────────────
command -v az >/dev/null 2>&1 || { echo "❌ Azure CLI (az) is required. Install: https://aka.ms/install-az"; exit 1; }
command -v azd >/dev/null 2>&1 || { echo "❌ Azure Developer CLI (azd) is required. Install: https://aka.ms/install-azd"; exit 1; }

if ! az account show > /dev/null 2>&1; then
  echo "❌ Not logged in to Azure CLI. Run 'az login' first."
  exit 1
fi

if ! azd env get-values > /dev/null 2>&1; then
  echo "❌ No azd environment selected. Run 'azd init' first."
  exit 1
fi

# ── Reset Mode ───────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--reset" ]]; then
  echo "🔄 Clearing existing resource configuration..."
  azd env set EXISTING_RESOURCE_GROUP ""
  azd env set EXISTING_ACR_NAME ""
  azd env set EXISTING_STORAGE_ACCOUNT_NAME ""
  azd env set EXISTING_CONTAINER_APPS_ENV_NAME ""
  azd env set EXISTING_LOG_ANALYTICS_NAME ""
  azd env set FORCE_DELETE ""
  echo ""
  echo "✅ Configuration reset. All resources will be created fresh on next 'azd provision'."
  exit 0
fi

# ── Display Header ───────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Configure Existing Azure Resources for Reuse            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

SUB_NAME=$(az account show --query name -o tsv)
SUB_ID=$(az account show --query id -o tsv)
echo "📍 Subscription: $SUB_NAME ($SUB_ID)"
echo ""

# ── Helper: prompt user to select from a list ────────────────────────────────
# Usage: select_resource "Label" item1 item2 ...
# Sets SELECTED to chosen item or "" if skipped.
select_resource() {
  local label="$1"
  shift
  local items=("$@")

  if [[ ${#items[@]} -eq 0 ]]; then
    echo "   No ${label}s found. A new one will be created."
    SELECTED=""
    return
  fi

  for i in "${!items[@]}"; do
    echo "   [$((i+1))] ${items[$i]}"
  done
  echo "   [0] Skip — create a new ${label}"
  echo ""
  read -rp "   Select ${label} [0]: " choice
  choice=${choice:-0}

  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#items[@]} ]]; then
    SELECTED="${items[$((choice-1))]}"
    echo "   → Selected: $SELECTED"
  else
    SELECTED=""
    echo "   → Will create a new ${label}."
  fi
}

# ── Step 1: Resource Group ───────────────────────────────────────────────────
echo "── Step 1: Resource Group ──────────────────────────────────"
echo ""
echo "   Querying resource groups..."

RG_ITEMS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && RG_ITEMS+=("$line")
done < <(az group list --query "[].name" -o tsv 2>/dev/null | sort)

select_resource "Resource Group" "${RG_ITEMS[@]}"
SELECTED_RG="$SELECTED"
echo ""

# ── Determine target RG for resource queries ─────────────────────────────────
if [[ -n "$SELECTED_RG" ]]; then
  TARGET_RG="$SELECTED_RG"
  echo "   Scanning resources in: $TARGET_RG"
  echo ""
else
  echo "   ℹ️  Without an existing Resource Group, resources cannot be scanned."
  echo "   All resources will be created fresh."
  SELECTED_ACR=""
  SELECTED_STORAGE=""
  SELECTED_ENV=""
  SELECTED_LAW=""

  # Jump to summary
  echo ""
  echo "── Summary ───────────────────────────────────────────────"
  echo ""
  echo "   Resource Group:             (new)"
  echo "   Container Registry:         (new)"
  echo "   Storage Account:            (new)"
  echo "   Container Apps Environment: (new)"
  echo "   Log Analytics Workspace:    (new)"
  echo "   Container Apps Job:         (always managed by deployment)"
  echo ""
  read -rp "   Apply this configuration? [Y/n]: " confirm
  confirm=${confirm:-Y}
  if [[ "${confirm,,}" != "y" ]]; then
    echo "   Cancelled."
    exit 0
  fi

  echo ""
  echo "🔧 Setting azd environment variables..."
  azd env set EXISTING_RESOURCE_GROUP ""
  azd env set EXISTING_ACR_NAME ""
  azd env set EXISTING_STORAGE_ACCOUNT_NAME ""
  azd env set EXISTING_CONTAINER_APPS_ENV_NAME ""
  azd env set EXISTING_LOG_ANALYTICS_NAME ""
  echo ""
  echo "✅ Configuration saved. Run 'azd provision' to deploy."
  exit 0
fi

# ── Step 2: Container Registry (ACR) ─────────────────────────────────────────
echo "── Step 2: Container Registry (ACR) ────────────────────────"
echo ""
echo "   Querying ACRs in $TARGET_RG..."

ACR_ITEMS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ACR_ITEMS+=("$line")
done < <(az acr list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null)

ACR_DISPLAY=()
for acr_name in "${ACR_ITEMS[@]}"; do
  sku=$(az acr show -n "$acr_name" -g "$TARGET_RG" --query "sku.name" -o tsv 2>/dev/null || echo "?")
  ACR_DISPLAY+=("$acr_name  (SKU: $sku)")
done

select_resource "Container Registry" "${ACR_DISPLAY[@]}"
if [[ -n "$SELECTED" ]]; then
  SELECTED_ACR=$(echo "$SELECTED" | awk '{print $1}')
else
  SELECTED_ACR=""
fi
echo ""

# ── Step 3: Storage Account ──────────────────────────────────────────────────
echo "── Step 3: Storage Account ─────────────────────────────────"
echo ""
echo "   Querying Storage Accounts in $TARGET_RG..."

STORAGE_ITEMS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && STORAGE_ITEMS+=("$line")
done < <(az storage account list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null)

STORAGE_DISPLAY=()
for sa_name in "${STORAGE_ITEMS[@]}"; do
  sku=$(az storage account show -n "$sa_name" -g "$TARGET_RG" --query "sku.name" -o tsv 2>/dev/null || echo "?")
  STORAGE_DISPLAY+=("$sa_name  (SKU: $sku)")
done

select_resource "Storage Account" "${STORAGE_DISPLAY[@]}"
if [[ -n "$SELECTED" ]]; then
  SELECTED_STORAGE=$(echo "$SELECTED" | awk '{print $1}')
else
  SELECTED_STORAGE=""
fi

# Check required blob containers if storage was selected
if [[ -n "$SELECTED_STORAGE" ]]; then
  echo ""
  echo "   Checking required blob containers..."
  MISSING_CONTAINERS=()
  for container in input output processed error; do
    exists=$(az storage container exists \
      --account-name "$SELECTED_STORAGE" \
      --name "$container" \
      --auth-mode login \
      --query exists -o tsv 2>/dev/null || echo "false")
    if [[ "$exists" == "true" ]]; then
      echo "     ✅ $container"
    else
      echo "     ⚠️  $container (missing)"
      MISSING_CONTAINERS+=("$container")
    fi
  done
  if [[ ${#MISSING_CONTAINERS[@]} -gt 0 ]]; then
    echo ""
    echo "   ⚠️  Missing containers must be created before running the processor."
    echo "   You can create them with:"
    for mc in "${MISSING_CONTAINERS[@]}"; do
      echo "     az storage container create --account-name $SELECTED_STORAGE --name $mc --auth-mode login"
    done
  fi
fi
echo ""

# ── Step 4: Container Apps Environment ────────────────────────────────────────
echo "── Step 4: Container Apps Environment ──────────────────────"
echo ""
echo "   Querying Container Apps Environments in $TARGET_RG..."

CAE_ITEMS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && CAE_ITEMS+=("$line")
done < <(az containerapp env list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null)

select_resource "Container Apps Environment" "${CAE_ITEMS[@]}"
SELECTED_ENV="$SELECTED"
echo ""

# ── Step 5: Log Analytics Workspace ───────────────────────────────────────────
echo "── Step 5: Log Analytics Workspace ─────────────────────────"
echo ""
echo "   Querying Log Analytics Workspaces in $TARGET_RG..."

LAW_ITEMS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && LAW_ITEMS+=("$line")
done < <(az monitor log-analytics workspace list -g "$TARGET_RG" --query "[].name" -o tsv 2>/dev/null)

select_resource "Log Analytics Workspace" "${LAW_ITEMS[@]}"
SELECTED_LAW="$SELECTED"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "── Summary ───────────────────────────────────────────────"
echo ""
[[ -n "$SELECTED_RG" ]] \
  && echo "   Resource Group:             $SELECTED_RG (existing)" \
  || echo "   Resource Group:             (new)"
[[ -n "$SELECTED_ACR" ]] \
  && echo "   Container Registry:         $SELECTED_ACR (existing)" \
  || echo "   Container Registry:         (new)"
[[ -n "$SELECTED_STORAGE" ]] \
  && echo "   Storage Account:            $SELECTED_STORAGE (existing)" \
  || echo "   Storage Account:            (new)"
[[ -n "$SELECTED_ENV" ]] \
  && echo "   Container Apps Environment: $SELECTED_ENV (existing)" \
  || echo "   Container Apps Environment: (new)"
[[ -n "$SELECTED_LAW" ]] \
  && echo "   Log Analytics Workspace:    $SELECTED_LAW (existing)" \
  || echo "   Log Analytics Workspace:    (new)"
echo "   Container Apps Job:         (always managed by deployment)"
echo ""

read -rp "   Apply this configuration? [Y/n]: " confirm
confirm=${confirm:-Y}

if [[ "${confirm,,}" != "y" ]]; then
  echo "   Cancelled."
  exit 0
fi

# ── Apply Configuration ──────────────────────────────────────────────────────
echo ""
echo "🔧 Setting azd environment variables..."

azd env set EXISTING_RESOURCE_GROUP "${SELECTED_RG}"
azd env set EXISTING_ACR_NAME "${SELECTED_ACR}"
azd env set EXISTING_STORAGE_ACCOUNT_NAME "${SELECTED_STORAGE}"
azd env set EXISTING_CONTAINER_APPS_ENV_NAME "${SELECTED_ENV}"
azd env set EXISTING_LOG_ANALYTICS_NAME "${SELECTED_LAW}"

# Set location from existing RG to ensure consistency
if [[ -n "$SELECTED_RG" ]]; then
  RG_LOCATION=$(az group show -n "$SELECTED_RG" --query location -o tsv 2>/dev/null || echo "")
  if [[ -n "$RG_LOCATION" ]]; then
    azd env set AZURE_LOCATION "$RG_LOCATION"
    echo "   📍 Location set to: $RG_LOCATION (from resource group)"
  fi
fi

echo ""
echo "✅ Configuration saved to azd environment."
echo ""
echo "Next steps:"
echo "  1. Run 'azd provision' to deploy infrastructure"
echo "  2. Existing resources will be referenced (not recreated)"
echo "  3. 'azd down' will be blocked to protect existing resources"
echo "     (override with: azd env set FORCE_DELETE true)"
echo ""
echo "To undo:  ./scripts/configure-existing-resources.sh --reset"
