#!/usr/bin/env bash
#
# Fundamental Platform - Azure prerequisite check
#
# Run this before you deploy. It is read-only: it creates nothing and changes
# nothing in your subscription. It uses the permissions of the account you
# are signed in with. Checks your account is not allowed to make are marked
# SKIP, not FAIL, and listed at the end so you can verify them another way.
#
# Requires: bash, Azure CLI (signed in). jq is needed only with -p.
#
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: preflight.sh -g <resource-group> [options]

Checks that your Azure subscription is ready for the Fundamental Platform.
The script is read-only.

Options:
  -g <name>        Resource group you deploy into (required)
  -n <name>        Deployment name prefix (default: fundamental, or deploymentName in params.json)
  -l <region>      Azure region (default: the region of the resource group)
  -s <id>          Subscription ID (default: the current Azure CLI subscription)
  -p <file>        Your params.json. Enables exact checks for quota, zones, Entra group,
                   identities and TLS certificate. Needs jq.
  --deploy-app-id <client-id>
                   Client ID of the deployment app registration, if it is not
                   named <deployment-name>-deploy-app
  -h               Show this help

Example:
  ./preflight.sh -g rg-fundamental -p params.json
EOF
}

# ---------------------------------------------------------------- inputs
RG="" ; DEPLOYMENT_NAME="" ; LOCATION="" ; SUBSCRIPTION_ID="" ; PARAMS="" ; DEPLOY_APP_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    -g) RG="${2:-}"; shift 2 ;;
    -n) DEPLOYMENT_NAME="${2:-}"; shift 2 ;;
    -l) LOCATION="${2:-}"; shift 2 ;;
    -s) SUBSCRIPTION_ID="${2:-}"; shift 2 ;;
    -p) PARAMS="${2:-}"; shift 2 ;;
    --deploy-app-id) DEPLOY_APP_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done
[ -n "$RG" ] || { usage; exit 2; }

# ---------------------------------------------------------------- output
if [ -t 1 ]; then
  C_PASS=$'\033[32m'; C_FAIL=$'\033[31m'; C_WARN=$'\033[33m'; C_SKIP=$'\033[36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_PASS=""; C_FAIL=""; C_WARN=""; C_SKIP=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi
N_PASS=0; N_FAIL=0; N_WARN=0; N_SKIP=0
SKIPPED=""

section() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }
pass()  { N_PASS=$((N_PASS+1)); printf '  %s[PASS]%s %s\n' "$C_PASS" "$C_OFF" "$1"; }
fail()  { N_FAIL=$((N_FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$1"; [ -n "${2:-}" ] && printf '         %s%s%s\n' "$C_DIM" "$2" "$C_OFF"; }
warn()  { N_WARN=$((N_WARN+1)); printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$1"; [ -n "${2:-}" ] && printf '         %s%s%s\n' "$C_DIM" "$2" "$C_OFF"; }
info()  { printf '  %s[INFO]%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
# skip "<what was not checked>" "<permission your account needs>"
skip()  { N_SKIP=$((N_SKIP+1)); printf '  %s[SKIP]%s %s\n' "$C_SKIP" "$C_OFF" "$1"; printf '         %sNot checked: your account lacks permission. Needs: %s%s\n' "$C_DIM" "$2" "$C_OFF"; SKIPPED="${SKIPPED}  - $1 (needs: $2)"$'\n'; }

# run_az <az args...>  -> stdout in AZ_OUT. Returns 0 ok, 2 permission denied, 1 other error.
PERM_REGEX='AuthorizationFailed|LinkedAuthorizationFailed|Authorization_RequestDenied|Insufficient privileges|Forbidden|does not have authorization|\(403\)|status code 403'
AZ_OUT=""; AZ_ERR=""
run_az() {
  local errf; errf=$(mktemp)
  if AZ_OUT=$(az "$@" 2>"$errf"); then rm -f "$errf"; return 0; fi
  AZ_ERR=$(<"$errf"); rm -f "$errf"
  if printf '%s' "$AZ_ERR" | grep -qiE "$PERM_REGEX"; then return 2; fi
  return 1
}
first_err_line() { printf '%s' "$AZ_ERR" | grep -vE '^\s*$' | grep -viE '^(WARNING|ERROR):?\s*$' | head -1 | sed -E 's/^(ERROR|WARNING): ?//' | cut -c1-160; }

# ---------------------------------------------------------------- params.json
HAS_PARAMS=0
if [ -n "$PARAMS" ]; then
  if [ ! -f "$PARAMS" ]; then echo "params.json not found: $PARAMS"; exit 2; fi
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.parameters' "$PARAMS" >/dev/null 2>&1; then HAS_PARAMS=1; else echo "Cannot read $PARAMS: expected a 'parameters' object."; exit 2; fi
  fi
fi
# pval <name> <default>  -> scalar parameter value
pval() { local v=""; [ "$HAS_PARAMS" = 1 ] && v=$(jq -r --arg k "$1" '.parameters[$k].value | if . == null then empty else . end' "$PARAMS"); printf '%s' "${v:-$2}"; }
# parr <name> <default>  -> array parameter, space separated
parr() {
  if [ "$HAS_PARAMS" = 1 ] && jq -e --arg k "$1" '.parameters[$k].value' "$PARAMS" >/dev/null 2>&1; then
    jq -r --arg k "$1" '.parameters[$k].value | join(" ")' "$PARAMS"
  else
    printf '%s' "$2"
  fi
}

[ -n "$DEPLOYMENT_NAME" ] || DEPLOYMENT_NAME=$(pval deploymentName fundamental)
MI_NAME="$DEPLOYMENT_NAME-fun-mi-01"
SKR_APP_NAME="$DEPLOYMENT_NAME-skr-app"
DEPLOY_APP_NAME="$DEPLOYMENT_NAME-deploy-app"

echo "Fundamental Platform - Azure prerequisite check (read-only)"
echo "Resource group: $RG   Deployment name: $DEPLOYMENT_NAME"
if [ -n "$PARAMS" ] && [ "$HAS_PARAMS" = 0 ]; then
  echo "jq is not installed, so $PARAMS is ignored. Template defaults are used for quota and zone checks."
elif [ "$HAS_PARAMS" = 0 ]; then
  echo "No params.json given. Template defaults are used for quota and zone checks. Pass -p params.json for exact checks."
fi

# ---------------------------------------------------------------- 1. Azure CLI and sign-in
section "Azure CLI and sign-in"
if ! command -v az >/dev/null 2>&1; then
  fail "Azure CLI is not installed." "Install it: https://learn.microsoft.com/cli/azure/install-azure-cli"
  exit 1
fi
pass "Azure CLI $(az version --query '"azure-cli"' -o tsv 2>/dev/null) is installed."

if ! run_az account show -o none; then
  fail "You are not signed in to Azure." "Run: az login"
  exit 1
fi
if [ -n "$SUBSCRIPTION_ID" ]; then
  if ! run_az account show -s "$SUBSCRIPTION_ID" -o none; then
    fail "Subscription $SUBSCRIPTION_ID is not visible to your account." "Run: az login, then check the ID."
    exit 1
  fi
else
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)
fi
SUB_STATE=$(az account show -s "$SUBSCRIPTION_ID" --query state -o tsv)
SUB_NAME=$(az account show -s "$SUBSCRIPTION_ID" --query name -o tsv)
TENANT_ID=$(az account show -s "$SUBSCRIPTION_ID" --query tenantId -o tsv)
USER_NAME=$(az account show -s "$SUBSCRIPTION_ID" --query user.name -o tsv)
USER_TYPE=$(az account show -s "$SUBSCRIPTION_ID" --query user.type -o tsv)
az_sub() { run_az "$@" --subscription "$SUBSCRIPTION_ID"; }

pass "Signed in as $USER_NAME."
if [ "$SUB_STATE" = "Enabled" ]; then
  pass "Subscription '$SUB_NAME' ($SUBSCRIPTION_ID) is enabled."
else
  fail "Subscription '$SUB_NAME' is in state $SUB_STATE." "The subscription must be Enabled."
fi

# ---------------------------------------------------------------- 2. Resource group and region
section "Resource group and region"
RG_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RG"
RG_LOCATION=""
if az_sub group show -n "$RG" --query location -o tsv; then
  RG_LOCATION="$AZ_OUT"
  pass "Resource group '$RG' exists (region: $RG_LOCATION)."
else
  case $? in
    2) skip "Resource group '$RG' exists" "Reader on the resource group" ;;
    *) fail "Resource group '$RG' was not found." "Create it (Step 1A): az group create -n $RG -l <region>" ;;
  esac
fi
if [ -z "$LOCATION" ]; then
  LOCATION="$RG_LOCATION"
  [ -n "$LOCATION" ] || { fail "No region known. Pass -l <region>."; echo; exit 1; }
fi
if [ -n "$RG_LOCATION" ] && [ "$RG_LOCATION" != "$LOCATION" ]; then
  warn "Resource group is in $RG_LOCATION but you deploy to $LOCATION." "Fundamental replicates the machine image to the region you shared in Step 1D. Make sure it is $LOCATION."
fi
REGION_ZONES=""; REGION_ZONES_KNOWN=0
if run_az account list-locations --query "[?name=='$LOCATION'] | length(@)" -o tsv && [ "$AZ_OUT" = "1" ]; then
  pass "Region '$LOCATION' is valid for this subscription."
  if run_az account list-locations --query "[?name=='$LOCATION'].availabilityZoneMappings[].logicalZone" -o tsv; then
    REGION_ZONES_KNOWN=1; REGION_ZONES=$(printf '%s' "$AZ_OUT" | tr '\n' ' ' | sed 's/ *$//')
    if [ -n "$REGION_ZONES" ]; then
      info "Region '$LOCATION' has availability zones: $REGION_ZONES."
    else
      info "Region '$LOCATION' has no availability zones. Every zone list must be [] (aksAvailabilityZones defaults to [\"1\",\"2\"])."
    fi
  fi
else
  fail "Region '$LOCATION' is not a valid region name." "Use the short name, for example eastus2. List: az account list-locations -o table"
fi

# Your own roles on the resource group. Informational: explains any SKIP below.
MY_OID=""
if [ "$USER_TYPE" = "user" ]; then
  run_az ad signed-in-user show --query id -o tsv && MY_OID="$AZ_OUT"
else
  run_az ad sp show --id "$USER_NAME" --query id -o tsv && MY_OID="$AZ_OUT"
fi
if [ -n "$MY_OID" ] && az_sub role assignment list --scope "$RG_ID" --include-inherited --query "[?principalId=='$MY_OID'].roleDefinitionName" -o tsv; then
  MY_ROLES=$(printf '%s' "$AZ_OUT" | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
  info "Your roles on the resource group: ${MY_ROLES:-none}."
fi

if printf '%s' "$DEPLOYMENT_NAME" | grep -qE '^[a-z][a-z0-9-]{1,11}$'; then
  pass "Deployment name '$DEPLOYMENT_NAME' has a valid format."
else
  fail "Deployment name '$DEPLOYMENT_NAME' is not valid." "Use 2 to 12 characters: lowercase letters, digits, hyphens. Start with a letter."
fi

# ---------------------------------------------------------------- 3. Subscription readiness
section "Subscription readiness"
PROVIDERS="Microsoft.Compute Microsoft.Network Microsoft.ContainerService Microsoft.ContainerRegistry Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Storage Microsoft.ContainerInstance"
UNREG=""; PROV_SKIP=0
for p in $PROVIDERS; do
  if az_sub provider show -n "$p" --query registrationState -o tsv; then
    [ "$AZ_OUT" = "Registered" ] || UNREG="$UNREG $p"
  else
    PROV_SKIP=1
  fi
done
if [ "$PROV_SKIP" = 1 ]; then
  skip "Resource providers are registered" "Reader on the subscription"
elif [ -z "$UNREG" ]; then
  pass "All required resource providers are registered."
else
  warn "Resource providers not registered:$UNREG." "Register each: az provider register -n <name>. Owner on the resource group alone cannot do this."
fi

if az_sub keyvault list-deleted --resource-type vault --query "[?starts_with(name, '$DEPLOYMENT_NAME')].name" -o tsv; then
  if [ -n "$AZ_OUT" ]; then
    KV_COUNT=$(printf '%s\n' "$AZ_OUT" | wc -l | tr -d ' '); KV_SHOWN=$(printf '%s\n' "$AZ_OUT" | head -3 | tr '\n' ' ')
    [ "$KV_COUNT" -gt 3 ] && KV_SHOWN="$KV_SHOWN... ($KV_COUNT in total)"
    warn "Soft-deleted Key Vault(s) start with '$DEPLOYMENT_NAME': $KV_SHOWN" "If one is the platform vault of an earlier deployment, its name is reserved for 90 days. Use another deployment name, or purge it if your policy allows."
  else
    pass "No soft-deleted Key Vault reserves the '$DEPLOYMENT_NAME' name."
  fi
else
  [ $? = 2 ] && skip "No soft-deleted Key Vault reserves the deployment name" "Microsoft.KeyVault/locations/deletedVaults/read on the subscription"
fi

# ---------------------------------------------------------------- 4. Identities (Step 1)
section "Identities from identity onboarding (Step 1)"
MI_PRINCIPAL_ID=""
P_MI_ID=$(pval skrMiResourceId "")
if [ -n "$P_MI_ID" ]; then
  # params.json names the identity: check that one.
  MI_NAME=$(printf '%s' "$P_MI_ID" | awk -F/ '{print $NF}'); MI_RG=$(printf '%s' "$P_MI_ID" | awk -F/ '{print $5}')
  if [ "$(printf '%s' "$MI_RG" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$RG" | tr '[:upper:]' '[:lower:]')" ]; then
    fail "skrMiResourceId points to resource group '$MI_RG', not '$RG'." "The managed identity must be in the resource group you deploy into (Step 1A)."
  fi
  if az_sub identity show -n "$MI_NAME" -g "$MI_RG" --query principalId -o tsv; then
    MI_PRINCIPAL_ID="$AZ_OUT"
    pass "Managed identity '$MI_NAME' (skrMiResourceId) exists."
  else
    case $? in
      2) skip "Managed identity '$MI_NAME' (skrMiResourceId) exists" "Reader on the resource group" ;;
      *) fail "Managed identity '$MI_NAME' was not found in '$MI_RG'." "Check skrMiResourceId, or create it (Step 1A): az identity create -n $MI_NAME -g $RG" ;;
    esac
  fi
elif az_sub identity show -n "$MI_NAME" -g "$RG" --query principalId -o tsv; then
  MI_PRINCIPAL_ID="$AZ_OUT"
  pass "Managed identity '$MI_NAME' exists in '$RG'."
else
  case $? in
    2) skip "Managed identity '$MI_NAME' exists in '$RG'" "Reader on the resource group" ;;
    *) fail "Managed identity '$MI_NAME' was not found in '$RG'." "Create it (Step 1A): az identity create -n $MI_NAME -g $RG. If you used another name, set skrMiResourceId in params.json." ;;
  esac
fi

# Platform access app registration (skr-app) and its federated credential
SKR_APP_ID=$(pval skrAppClientId "")
if [ -z "$SKR_APP_ID" ]; then
  if run_az ad app list --display-name "$SKR_APP_NAME" --query "[0].appId" -o tsv; then SKR_APP_ID="$AZ_OUT"; else [ $? = 2 ] && SKR_APP_ID="__skip__"; fi
fi
if [ "$SKR_APP_ID" = "__skip__" ]; then
  skip "App registration '$SKR_APP_NAME' exists" "permission to read app registrations in Microsoft Entra"
elif [ -z "$SKR_APP_ID" ]; then
  fail "App registration '$SKR_APP_NAME' was not found." "Create it (Step 1B), or set skrAppClientId in params.json if you used another name."
else
  if run_az ad app show --id "$SKR_APP_ID" --query signInAudience -o tsv; then
    [ "$AZ_OUT" = "AzureADMultipleOrgs" ] && pass "Platform access app ($SKR_APP_ID) exists and is multi-tenant." \
      || fail "Platform access app ($SKR_APP_ID) is not multi-tenant (signInAudience: $AZ_OUT)." "It must be AzureADMultipleOrgs (Step 1B)."
    if [ -n "$MI_PRINCIPAL_ID" ]; then
      if run_az ad app federated-credential list --id "$SKR_APP_ID" --query "[?subject=='$MI_PRINCIPAL_ID'] | length(@)" -o tsv; then
        [ "$AZ_OUT" != "0" ] && pass "Federated credential binds the app to managed identity '$MI_NAME'." \
          || fail "No federated credential on the platform access app has subject $MI_PRINCIPAL_ID." "Add it (Step 1B)."
      else
        [ $? = 2 ] && skip "Federated credential binds the app to the managed identity" "permission to read app registrations in Microsoft Entra"
      fi
    fi
  else
    case $? in
      2) skip "Platform access app ($SKR_APP_ID) exists" "permission to read app registrations in Microsoft Entra" ;;
      *) fail "Platform access app with client ID $SKR_APP_ID was not found." "Check skrAppClientId, or create the app (Step 1B)." ;;
    esac
  fi
fi

# Deployment app registration and its Owner role
DEPLOY_SP_ID=""
if [ -z "$DEPLOY_APP_ID" ]; then
  if run_az ad app list --display-name "$DEPLOY_APP_NAME" --query "[0].appId" -o tsv; then DEPLOY_APP_ID="$AZ_OUT"; else [ $? = 2 ] && DEPLOY_APP_ID="__skip__"; fi
fi
if [ "$DEPLOY_APP_ID" = "__skip__" ]; then
  skip "Deployment app registration '$DEPLOY_APP_NAME' exists and is Owner on '$RG'" "permission to read app registrations in Microsoft Entra"
elif [ -z "$DEPLOY_APP_ID" ]; then
  fail "App registration '$DEPLOY_APP_NAME' was not found." "Create it (Step 1C). If you reuse an existing deployment identity, pass --deploy-app-id <its-client-id>."
else
  if run_az ad sp show --id "$DEPLOY_APP_ID" --query id -o tsv; then
    DEPLOY_SP_ID="$AZ_OUT"
    pass "Deployment app ($DEPLOY_APP_ID) has a service principal."
    if az_sub role assignment list --scope "$RG_ID" --include-inherited --query "[?principalId=='$DEPLOY_SP_ID' && roleDefinitionName=='Owner'] | length(@)" -o tsv; then
      [ "$AZ_OUT" != "0" ] && pass "Deployment app is Owner on '$RG'." \
        || fail "Deployment app is not Owner on '$RG'." "Grant it (Step 1C): az role assignment create --assignee-object-id $DEPLOY_SP_ID --assignee-principal-type ServicePrincipal --role Owner --scope $RG_ID"
    else
      [ $? = 2 ] && skip "Deployment app is Owner on '$RG'" "Microsoft.Authorization/roleAssignments/read on the resource group"
    fi
  else
    case $? in
      2) skip "Deployment app ($DEPLOY_APP_ID) has a service principal" "permission to read service principals in Microsoft Entra" ;;
      *) fail "No service principal for deployment app $DEPLOY_APP_ID." "Run: az ad sp create --id $DEPLOY_APP_ID" ;;
    esac
  fi
fi

# ---------------------------------------------------------------- 5. Cluster admin group and domain
section "Cluster admin group and domain"
if [ "$HAS_PARAMS" = 1 ]; then
  ADMIN_GROUPS=$(parr aksAdminGroupObjectIds "")
  if [ -z "$ADMIN_GROUPS" ]; then
    fail "aksAdminGroupObjectIds in params.json is empty." "Set the object ID of the Entra group that gets Cluster Admin."
  fi
  for gid in $ADMIN_GROUPS; do
    if run_az ad group show --group "$gid" --query displayName -o tsv; then
      pass "Entra group '$AZ_OUT' ($gid) exists."
    else
      case $? in
        2) skip "Entra group $gid exists" "permission to read groups in Microsoft Entra" ;;
        *) fail "Entra group $gid was not found." "Check aksAdminGroupObjectIds. Find the ID: az ad group show -g <group-name> --query id -o tsv" ;;
      esac
    fi
  done
  USER_DOMAIN=$(pval userDomain "")
  if [ -z "$USER_DOMAIN" ]; then
    fail "userDomain in params.json is empty." "Set a DNS suffix you control, for example apps.example.com."
  elif printf '%s' "$USER_DOMAIN" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
    pass "userDomain '$USER_DOMAIN' has a valid format."
  else
    fail "userDomain '$USER_DOMAIN' is not valid." "Use lowercase, no scheme (https://), no wildcard (*), no trailing dot."
  fi
else
  info "Entra group and userDomain not checked. Pass -p params.json."
fi

# ---------------------------------------------------------------- 6. Compute capacity
section "Compute capacity in $LOCATION"
SURGE=$(pval enableSurgeUpgrade true)
EXTRA=1; [ "$SURGE" = "false" ] && EXTRA=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Tiers: "<label>|<size>|<instances>|<zones>|<zones parameter name>"
TIERS=""
add_tier() { TIERS="${TIERS}$1|$2|$3|$4|$5"$'\n'; }
if [ "$(pval modelCpuLayout combined)" = "split" ]; then
  add_tier "Model CPU train"   "$(pval modelCpuTrainVmSize Standard_D192s_v7)"   "$(( $(pval modelCpuTrainInstanceCount 1) + EXTRA ))"   "$(parr modelCpuZones "")" modelCpuZones
  add_tier "Model CPU predict" "$(pval modelCpuPredictVmSize Standard_D192s_v7)" "$(( $(pval modelCpuPredictInstanceCount 1) + EXTRA ))" "$(parr modelCpuZones "")" modelCpuZones
else
  add_tier "Model CPU" "$(pval modelCpuVmSize Standard_D192s_v7)" "$(( $(pval modelCpuInstanceCount 1) + EXTRA ))" "$(parr modelCpuZones "")" modelCpuZones
fi
if [ "$(pval modelGpuLayout combined)" = "split" ]; then
  add_tier "Model GPU train"   "$(pval modelGpuTrainVmSize Standard_ND96isr_H200_v5)"   "$(( $(pval modelGpuTrainInstanceCount 1) + EXTRA ))"   "$(parr modelGpuZones "")" modelGpuZones
  add_tier "Model GPU predict" "$(pval modelGpuPredictVmSize Standard_ND96isr_H200_v5)" "$(( $(pval modelGpuPredictInstanceCount 1) + EXTRA ))" "$(parr modelGpuZones "")" modelGpuZones
else
  add_tier "Model GPU" "$(pval modelGpuVmSize Standard_ND96isr_H200_v5)" "$(( $(pval modelGpuInstanceCount 1) + EXTRA ))" "$(parr modelGpuZones "")" modelGpuZones
fi
add_tier "Model orchestration" "$(pval modelOrchestrationVmSize Standard_E32s_v7)" "$(( $(pval modelOrchestrationInstanceCount 1) + EXTRA ))" "$(parr modelOrchestrationZones "")" modelOrchestrationZones
# The AKS pool starts at its minimum, so quota is checked for that, floored at 3 nodes.
AKS_NODES=$(pval aksUserNodeMin 3); [ "$AKS_NODES" -gt 3 ] 2>/dev/null || AKS_NODES=3
add_tier "AKS user node pool"  "$(pval aksUserNodeVmSize Standard_E16as_v7)" "$AKS_NODES" "$(parr aksAvailabilityZones "1 2")" aksAvailabilityZones
[ "$EXTRA" = 1 ] && info "Surge upgrades are on: each model tier needs quota for instance count + 1."

# One SKU lookup for every size. Lines: "name family vcpu offeredZones restrictedZones locationRestricted". "-" means empty.
SKU_FILE="$TMP/skus"
SIZE_LIST=$(printf '%s' "$TIERS" | cut -d'|' -f2 | sort -u | sed "s/.*/'&'/" | paste -sd, -)
info "Looking up sizes and quota in $LOCATION. This takes about a minute."
if az_sub vm list-skus -l "$LOCATION" --resource-type virtualMachines \
    --query "[?contains([$SIZE_LIST], name)].[name, family, capabilities[?name=='vCPUs'].value | [0], join(',', locationInfo[0].zones || \`[]\`) || '-', join(',', restrictions[?type=='Zone'].restrictionInfo.zones[] || \`[]\`) || '-', length(restrictions[?type=='Location'])]" -o tsv; then
  printf '%s\n' "$AZ_OUT" | tr '\t' ' ' > "$SKU_FILE"
else
  [ $? = 2 ] && echo "__perm__" > "$SKU_FILE" || echo "__err__" > "$SKU_FILE"
fi
# sku_info <size> -> "family vcpu offeredZones restrictedZones locationRestricted"
sku_info() {
  if grep -q '^__perm__' "$SKU_FILE"; then echo "__perm__"; return; fi
  if grep -q '^__err__' "$SKU_FILE"; then echo "__err__"; return; fi
  awk -v s="$1" '$1==s{print $2, $3, $4, $5, $6; exit}' "$SKU_FILE"
}
USAGE_FILE="$TMP/usage"
if ! az_sub vm list-usage -l "$LOCATION" --query "[].[name.value, currentValue, limit]" -o tsv; then
  [ $? = 2 ] && echo "__perm__" > "$USAGE_FILE" || echo "__err__" > "$USAGE_FILE"
else
  printf '%s\n' "$AZ_OUT" > "$USAGE_FILE"
fi

NEEDS=""   # "family vcpus" lines
TOTAL_NEED=0
while IFS='|' read -r label size count zones zparam; do
  [ -n "$label" ] || continue
  read -r family vcpu offered restricted locrestr <<<"$(sku_info "$size")"
  case "$family" in
    __perm__) skip "$label: size $size is offered in $LOCATION" "Microsoft.Compute/skus/read on the subscription"; continue ;;
    __err__)  warn "$label: could not look up size $size." "$(first_err_line)"; continue ;;
    "")       fail "$label: size $size is not offered in $LOCATION for this subscription." "Pick another size or region. List: az vm list-skus -l $LOCATION --size $size -o table"; continue ;;
  esac
  if [ "${locrestr:-0}" != "0" ]; then
    fail "$label: size $size is restricted for this subscription in $LOCATION." "Request access or pick another size: az vm list-skus -l $LOCATION --size $size -o table"; continue
  fi
  # The size is offered regionally, so count its quota even if the zone check fails below.
  zone_msg=""; zone_ok=1
  if [ -n "$zones" ]; then
    if [ "$REGION_ZONES_KNOWN" = 1 ] && [ -z "$REGION_ZONES" ]; then
      fail "$label: zone(s)$(printf ' %s' $zones) requested, but region $LOCATION has no availability zones." "Set $zparam to [] in params.json for regional placement."; zone_ok=0
    else
      missing=""
      for z in $zones; do
        printf ',%s,' "$offered" | grep -q ",$z," || missing="$missing $z"
        printf ',%s,' "$restricted" | grep -q ",$z," && missing="$missing $z"
      done
      if [ -n "$missing" ]; then
        [ "$offered" = "-" ] && offered="none"
        fail "$label: size $size is not offered in zone(s)$missing of $LOCATION." "Offered zones: $offered. Change $zparam, or set it to [] for regional placement."; zone_ok=0
      fi
    fi
    zone_msg=" in zone(s) $zones"
  fi
  [ "$zone_ok" = 1 ] && pass "$label: $size x $count is offered in $LOCATION$zone_msg."
  need=$(( count * vcpu ))
  NEEDS="${NEEDS}$family $need"$'\n'
  TOTAL_NEED=$(( TOTAL_NEED + need ))
done <<<"$TIERS"

if grep -q '__perm__' "$USAGE_FILE"; then
  skip "vCPU quota in $LOCATION covers the selected sizes" "Microsoft.Compute/locations/usages/read on the subscription"
elif grep -q '__err__' "$USAGE_FILE"; then
  warn "Could not read vCPU quota in $LOCATION." "$(first_err_line)"
else
  printf '%s' "$NEEDS" | awk 'NF{a[$1]+=$2} END{for(k in a) print k, a[k]}' > "$TMP/needs"
  while read -r family need; do
    read -r cur limit <<<"$(awk -v f="$family" '$1==f{print $2, $3}' "$USAGE_FILE")"
    if [ -z "${limit:-}" ]; then warn "Quota for family $family was not found in $LOCATION." "Check in the portal: Subscriptions -> Usage + quotas."; continue; fi
    free=$(( limit - cur ))
    if [ "$free" -ge "$need" ]; then
      pass "Quota $family: need $need vCPUs, $free free (limit $limit, used $cur)."
    else
      fail "Quota $family: need $need vCPUs, only $free free (limit $limit, used $cur)." "Request a quota increase: portal -> Subscriptions -> Usage + quotas."
    fi
  done < "$TMP/needs"
  read -r cur limit <<<"$(awk '$1=="cores"{print $2, $3}' "$USAGE_FILE")"
  if [ -n "${limit:-}" ]; then
    free=$(( limit - cur ))
    [ "$free" -ge "$TOTAL_NEED" ] && pass "Regional vCPU total: need $TOTAL_NEED, $free free (limit $limit, used $cur)." \
      || fail "Regional vCPU total: need $TOTAL_NEED, only $free free (limit $limit, used $cur)." "Request a quota increase for Total Regional vCPUs."
  fi
fi
info "The AKS system node pool is not included in the totals. Keep a small margin."

# ---------------------------------------------------------------- 7. TLS certificate (optional)
section "TLS certificate (optional)"
CERT_ID=$(pval userCertificateKeyVaultResourceId "")
if [ -z "$CERT_ID" ]; then
  info "No certificate set: the platform serves HTTP. Set userCertificateKeyVaultResourceId for HTTPS."
elif ! printf '%s' "$CERT_ID" | grep -qiE '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.KeyVault/vaults/[^/]+/certificates/[^/]+$'; then
  fail "userCertificateKeyVaultResourceId has the wrong format." "Expected: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>/certificates/<name>"
else
  KV_SUB=$(printf '%s' "$CERT_ID" | cut -d/ -f3); KV_RG=$(printf '%s' "$CERT_ID" | cut -d/ -f5)
  KV_NAME=$(printf '%s' "$CERT_ID" | cut -d/ -f9); CERT_NAME=$(printf '%s' "$CERT_ID" | cut -d/ -f11)
  KV_ID="/subscriptions/$KV_SUB/resourceGroups/$KV_RG/providers/Microsoft.KeyVault/vaults/$KV_NAME"
  if run_az keyvault show --subscription "$KV_SUB" -g "$KV_RG" -n "$KV_NAME" --query "[properties.enableRbacAuthorization, properties.tenantId]" -o tsv; then
    KV_RBAC=$(printf '%s' "$AZ_OUT" | sed -n 1p); KV_TENANT=$(printf '%s' "$AZ_OUT" | sed -n 2p)
    pass "Key Vault '$KV_NAME' exists."
    [ "$KV_RBAC" = "true" ] && pass "Key Vault uses Azure RBAC permissions." \
      || fail "Key Vault '$KV_NAME' uses access policies, not Azure RBAC." "Switch the vault permission model to Azure role-based access control."
    [ "$KV_TENANT" = "$TENANT_ID" ] && pass "Key Vault is in the deployment tenant." \
      || fail "Key Vault is in tenant $KV_TENANT, not the deployment tenant $TENANT_ID." "The vault must be in the same tenant."
    if run_az keyvault certificate show --subscription "$KV_SUB" --vault-name "$KV_NAME" -n "$CERT_NAME" \
         --query "[policy.keyProperties.exportable, policy.x509CertificateProperties.subject, join(',', policy.x509CertificateProperties.subjectAlternativeNames.dnsNames || \`[]\`)]" -o tsv; then
      EXPORTABLE=$(printf '%s' "$AZ_OUT" | sed -n 1p); SUBJ=$(printf '%s' "$AZ_OUT" | sed -n 2p); SANS=$(printf '%s' "$AZ_OUT" | sed -n 3p)
      pass "Certificate '$CERT_NAME' exists."
      [ "$EXPORTABLE" = "true" ] && pass "Certificate private key is exportable." \
        || fail "Certificate private key is not exportable." "Import or renew the certificate with an exportable key (PKCS#8)."
      if [ -n "${USER_DOMAIN:-}" ]; then
        names=",$(printf '%s' "$SUBJ" | sed -E 's/.*CN=([^,]+).*/\1/'),$SANS,"
        if printf '%s' "$names" | grep -q ",\*\.$USER_DOMAIN,"; then
          pass "Certificate covers *.$USER_DOMAIN."
        else
          miss=""
          for h in fundamental-portal fundamental-api fundamental-auth fundamental-grafana; do printf '%s' "$names" | grep -q ",$h.$USER_DOMAIN," || miss="$miss $h.$USER_DOMAIN"; done
          [ -z "$miss" ] && pass "Certificate lists all four hostnames under $USER_DOMAIN." \
            || fail "Certificate does not cover:$miss." "It must cover *.$USER_DOMAIN or list all four hostnames."
        fi
      fi
    else
      case $? in
        2) skip "Certificate '$CERT_NAME' exists, is exportable and covers the domain" "Key Vault Certificates Officer (or Reader) on the vault, for your account" ;;
        *) fail "Certificate '$CERT_NAME' was not found in vault '$KV_NAME'." "$(first_err_line)" ;;
      esac
    fi
    if [ -n "$DEPLOY_SP_ID" ]; then
      if run_az role assignment list --subscription "$KV_SUB" --scope "$KV_ID" --include-inherited --query "[?principalId=='$DEPLOY_SP_ID' && roleDefinitionName=='Owner'] | length(@)" -o tsv; then
        [ "$AZ_OUT" != "0" ] && pass "Deployment app is Owner on the Key Vault." \
          || fail "Deployment app is not Owner on Key Vault '$KV_NAME'." "Grant it: az role assignment create --assignee-object-id $DEPLOY_SP_ID --assignee-principal-type ServicePrincipal --role Owner --scope $KV_ID"
      else
        [ $? = 2 ] && skip "Deployment app is Owner on the Key Vault" "Microsoft.Authorization/roleAssignments/read on the vault"
      fi
    fi
  else
    case $? in
      2) skip "Key Vault '$KV_NAME' exists, uses RBAC and holds the certificate" "Reader on the Key Vault" ;;
      *) fail "Key Vault '$KV_NAME' was not found in resource group '$KV_RG' of subscription $KV_SUB." "$(first_err_line)" ;;
    esac
  fi
fi

# ---------------------------------------------------------------- 8. Not checked by this script
section "Confirm yourself"
info "Fundamental confirmed your tenant ID, app IDs and region (Step 1D) and sent you computeImageId and the versions."
info "Address spaces 172.22.0.0/20 and 10.244.0.0/16 do not overlap a network you will peer or connect from."
info "You own DNS for userDomain and can create four A records after the deployment."

# ---------------------------------------------------------------- Summary
section "Summary"
printf '  Passed: %d   Failed: %d   Warnings: %d   Not checked: %d\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP"
if [ "$N_SKIP" -gt 0 ]; then
  echo
  echo "  Checks your account could not run. Ask an Owner of the resource group to run this script,"
  echo "  or verify these another way:"
  printf '%s' "$SKIPPED"
fi
echo
if [ "$N_FAIL" -gt 0 ]; then
  printf '  %sFix the FAIL items before you deploy.%s\n' "$C_FAIL" "$C_OFF"; exit 1
elif [ "$N_WARN" -gt 0 ] || [ "$N_SKIP" -gt 0 ]; then
  printf '  %sNo failures. Review the WARN and SKIP items, then deploy.%s\n' "$C_WARN" "$C_OFF"; exit 0
else
  printf '  %sAll checks passed. You can deploy.%s\n' "$C_PASS" "$C_OFF"; exit 0
fi
