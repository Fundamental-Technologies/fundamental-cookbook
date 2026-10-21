#!/usr/bin/env bash
#
# Fundamental Platform - GCP prerequisite check
#
# Run this before you deploy. It is read-only: it creates nothing and changes
# nothing in your project. It uses the permissions of the account gcloud is
# signed in with. Checks your account is not allowed to make are marked SKIP,
# not FAIL, and listed at the end so you can verify them another way.
#
# Requires: bash, gcloud (signed in), python3, curl. Everything else is
# reported, not required.
#
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: preflight.sh [-p <project-id>] [-t <tfvars-file>]

Checks that your Google Cloud project is ready for the Fundamental Platform.
The script is read-only.

Options:
  -p <project-id>  Project you deploy into (default: project_id from the tfvars
                   file, else the current gcloud project)
  -t <file>        Your terraform/<name>.tfvars. Enables exact checks for
                   region, zones, machine types, quota, bundle, image, existing
                   network and customer exposure. Without it the template
                   defaults are checked.
  -h               Show this help

Example:
  ./preflight.sh -t terraform/my-deployment.tfvars
EOF
}

# ---------------------------------------------------------------- inputs
PROJECT_ID=""; TFVARS=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) PROJECT_ID="${2:-}"; shift 2 ;;
    -t) TFVARS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

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

# run_gc <gcloud args...> -> stdout in GC_OUT. Returns 0 ok, 2 permission denied, 1 other error.
PERM_REGEX='PERMISSION_DENIED|permission denied|does not have permission|does not have [a-z.]+ access|Permission .* denied|Required .* permission|caller does not have|\(403\)|HTTPError 403|status code 403|Forbidden|ACCESS_TOKEN_SCOPE_INSUFFICIENT'
GC_OUT=""; GC_ERR=""
run_gc() {
  local errf; errf=$(mktemp)
  if GC_OUT=$(gcloud "$@" 2>"$errf"); then rm -f "$errf"; return 0; fi
  GC_ERR=$(<"$errf"); rm -f "$errf"
  if printf '%s' "$GC_ERR" | grep -qiE "$PERM_REGEX"; then return 2; fi
  return 1
}
first_err_line() { printf '%s' "$GC_ERR" | grep -vE '^\s*$' | grep -viE '^(WARNING|ERROR):?\s*$' | head -1 | sed -E 's/^(ERROR|WARNING): ?//; s/^ *- //' | cut -c1-160; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- tfvars
# A small reader for the tfvars subset the template uses (strings, numbers,
# booleans, lists, objects, nested objects). Not a full HCL parser. Output is
# one "dotted.key=value" line per scalar; a list of scalars is space separated
# and also reports "key.#=<length>".
TFVARS_FLAT="$TMP/tfvars"
HAS_TFVARS=0
if [ -n "$TFVARS" ]; then
  if [ ! -f "$TFVARS" ]; then echo "tfvars file not found: $TFVARS"; exit 2; fi
  if ! command -v python3 >/dev/null 2>&1; then echo "python3 is needed to read $TFVARS."; exit 2; fi
  if ! python3 - "$TFVARS" >"$TFVARS_FLAT" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# Strip comments outside strings.
out, i, n, instr = [], 0, len(src), False
while i < n:
    c = src[i]
    if instr:
        out.append(c)
        if c == "\\" and i + 1 < n:
            out.append(src[i + 1]); i += 2; continue
        if c == '"':
            instr = False
        i += 1; continue
    if c == '"':
        instr = True; out.append(c); i += 1; continue
    if c == "#" or src.startswith("//", i):
        while i < n and src[i] != "\n": i += 1
        continue
    if src.startswith("/*", i):
        j = src.find("*/", i + 2); i = n if j < 0 else j + 2; continue
    out.append(c); i += 1
s = "".join(out)
tok = re.compile(r'(?P<ws>\s+)|(?P<str>"(?:[^"\\]|\\.)*")|(?P<num>-?\d+(?:\.\d+)?)|(?P<id>[A-Za-z_][A-Za-z0-9_-]*)|(?P<p>[=\[\]{},:])')
tokens, pos = [], 0
for m in tok.finditer(s):
    if m.start() != pos:
        sys.exit("cannot read tfvars near: " + s[pos:pos + 40].strip())
    pos = m.end()
    if m.lastgroup != "ws":
        tokens.append((m.lastgroup, m.group()))
if pos != len(s):
    sys.exit("cannot read tfvars near: " + s[pos:pos + 40].strip())
i = 0
def peek():
    return tokens[i] if i < len(tokens) else (None, None)
def take():
    global i
    if i >= len(tokens): sys.exit("cannot read tfvars: unexpected end of file")
    t = tokens[i]; i += 1; return t
def key_of(t):
    return t[1][1:-1] if t[0] == "str" else t[1]
def value():
    k, v = take()
    if k == "str": return v[1:-1].replace('\\"', '"')
    if k in ("num", "id"): return v
    if v == "[":
        items = []
        while peek()[1] != "]":
            items.append(value())
            if peek()[1] == ",": take()
        take(); return items
    if v == "{":
        obj = {}
        while peek()[1] != "}":
            key = key_of(take())
            if peek()[1] in ("=", ":"): take()
            obj[key] = value()
            if peek()[1] == ",": take()
        take(); return obj
    sys.exit("cannot read tfvars: unexpected " + v)
top = {}
while i < len(tokens):
    key = key_of(take())
    if peek()[1] != "=": sys.exit("cannot read tfvars: expected = after " + key)
    take()
    top[key] = value()
def emit(prefix, v):
    if isinstance(v, dict):
        for k, x in v.items(): emit(prefix + "." + k if prefix else k, x)
    elif isinstance(v, list):
        print(prefix + ".#=" + str(len(v)))
        if all(not isinstance(x, (dict, list)) for x in v):
            print(prefix + "=" + " ".join(str(x) for x in v))
        else:
            for idx, x in enumerate(v): emit(prefix + "." + str(idx), x)
    else:
        print(prefix + "=" + str(v))
emit("", top)
PYEOF
  then
    echo "Cannot read $TFVARS. $(tail -1 "$TFVARS_FLAT" 2>/dev/null)"; exit 2
  fi
  HAS_TFVARS=1
fi
# tv <dotted key> <default> -> value from the tfvars file, or the default when unset or null
tv() {
  local v=""
  [ "$HAS_TFVARS" = 1 ] && v=$(awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$TFVARS_FLAT")
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$2"; else printf '%s' "$v"; fi
}
# tv_set <dotted key> -> 0 when the key is present and not null
tv_set() { [ "$HAS_TFVARS" = 1 ] && grep -qE "^$(printf '%s' "$1" | sed 's/[.[\*^$]/\\&/g')=" "$TFVARS_FLAT" && [ "$(tv "$1" "")" != "" ]; }

# Template defaults (terraform/variables.tf). Only the ones the checks need.
[ -n "$PROJECT_ID" ] || PROJECT_ID=$(tv project_id "")
REGION=$(tv region us-west1)
ZONES=$(tv zones "")
[ -n "$ZONES" ] || ZONES="${REGION}-a ${REGION}-b"
DEPLOYMENT_NAME=$(tv deployment_name fundamental)
BUNDLE_VERSION=$(tv bundle_version "")
HARDENED_IMAGE=$(tv hardened_image "")
PRODUCER_BUCKET=$(tv producer_release_bucket_name fun-marketplace-us)
TF_MIN_VERSION="1.9.0"   # terraform/versions.tf required_version
EXPOSURE=$(tv customer_exposure_enabled false)
EDGE_CERT=$(tv edge_certificate_id "")
GPU_REGION=$(tv modelgpu.region "$REGION")

echo "Fundamental Platform - GCP prerequisite check (read-only)"
if [ "$HAS_TFVARS" = 1 ]; then
  echo "tfvars: $TFVARS"
else
  echo "No tfvars file given. Template defaults are used for region, zones, machine types and quota. Pass -t terraform/<name>.tfvars for exact checks."
fi

# ---------------------------------------------------------------- 1. gcloud and sign-in
section "gcloud and sign-in"
if ! command -v gcloud >/dev/null 2>&1; then
  fail "gcloud is not installed." "Install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install"
  exit 1
fi
pass "$(gcloud version 2>/dev/null | head -1) is installed."
ACCOUNT=$(gcloud config get-value account 2>/dev/null)
if [ -z "$ACCOUNT" ] || ! run_gc auth print-access-token; then
  fail "You are not signed in to gcloud." "Run: gcloud auth login"
  exit 1
fi
pass "Signed in as $ACCOUNT."
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  [ -n "$PROJECT_ID" ] || { fail "No project known." "Pass -p <project-id>, or run: gcloud config set project <project-id>"; echo; exit 1; }
fi
CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ -n "$CONFIG_PROJECT" ] && [ "$CONFIG_PROJECT" != "$PROJECT_ID" ]; then
  warn "gcloud's current project is $CONFIG_PROJECT, but this check runs against $PROJECT_ID." "The deploy script uses gcloud's current project. Before you deploy: gcloud config set project $PROJECT_ID"
fi
TV_PROJECT=$(tv project_id "")
if [ -n "$TV_PROJECT" ] && [ "$TV_PROJECT" != "$PROJECT_ID" ]; then
  warn "project_id in the tfvars file is $TV_PROJECT, not $PROJECT_ID." "Check -p and project_id."
fi
gc() { run_gc "$@" --project="$PROJECT_ID"; }

# ---------------------------------------------------------------- 2. Project
section "Project $PROJECT_ID"
PROJECT_NUMBER=""
if run_gc projects describe "$PROJECT_ID" --format='value(projectNumber,lifecycleState)'; then
  PROJECT_NUMBER=$(printf '%s' "$GC_OUT" | cut -f1); P_STATE=$(printf '%s' "$GC_OUT" | cut -f2)
  if [ "$P_STATE" = "ACTIVE" ]; then
    pass "Project exists and is active (number $PROJECT_NUMBER)."
    info "Share the project number $PROJECT_NUMBER and the region with Fundamental for onboarding."
  else
    fail "Project is in state $P_STATE." "The project must be ACTIVE."
  fi
else
  case $? in
    2) skip "Project $PROJECT_ID exists and is active" "resourcemanager.projects.get on the project (roles/viewer)" ;;
    *) fail "Project $PROJECT_ID was not found." "Check the project id: gcloud projects list" ;;
  esac
fi
if run_gc billing projects describe "$PROJECT_ID" --format='value(billingEnabled)'; then
  case "$GC_OUT" in
    True|true) pass "Billing is enabled." ;;
    *) fail "Billing is not enabled on the project." "Link a billing account: Console > Billing, or: gcloud billing projects link $PROJECT_ID --billing-account <id>" ;;
  esac
else
  case $? in
    2) skip "Billing is enabled on the project" "billing.resourceAssociations.list (roles/billing.user or roles/viewer)" ;;
    *) warn "Could not read the billing state." "$(first_err_line)" ;;
  esac
fi

# ---------------------------------------------------------------- 3. APIs
section "Required APIs"
# Derived from the resource types in the Terraform module. The deployment
# itself enables container, dns and parametermanager; the rest must be on.
APIS_REQUIRED="compute.googleapis.com cloudkms.googleapis.com secretmanager.googleapis.com artifactregistry.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com storage.googleapis.com logging.googleapis.com monitoring.googleapis.com serviceusage.googleapis.com"
APIS_SELF_ENABLED="container.googleapis.com dns.googleapis.com parametermanager.googleapis.com"
if [ "$EXPOSURE" = "true" ] && [ -n "$EDGE_CERT" ]; then APIS_REQUIRED="$APIS_REQUIRED certificatemanager.googleapis.com"; fi
if gc services list --enabled --format='value(config.name)'; then
  printf '%s\n' "$GC_OUT" > "$TMP/apis"
  MISSING=""
  for a in $APIS_REQUIRED; do grep -qx "$a" "$TMP/apis" || MISSING="$MISSING $a"; done
  if [ -z "$MISSING" ]; then
    pass "All required APIs are enabled."
  else
    fail "APIs not enabled:$MISSING" "Enable them: gcloud services enable$MISSING --project $PROJECT_ID"
  fi
  LATER=""
  for a in $APIS_SELF_ENABLED; do grep -qx "$a" "$TMP/apis" || LATER="$LATER $a"; done
  if [ -z "$LATER" ]; then
    pass "APIs the deployment enables itself are already on (container, dns, parametermanager)."
  else
    warn "Not enabled yet, the deployment enables them on the first run:$LATER" "That needs serviceusage.services.enable. To enable them now: gcloud services enable$LATER --project $PROJECT_ID"
  fi
else
  case $? in
    2) skip "Required APIs are enabled" "serviceusage.services.list on the project (roles/viewer)" ;;
    *) warn "Could not list enabled APIs." "$(first_err_line)" ;;
  esac
fi

# ---------------------------------------------------------------- 4. Your permissions
section "Your permissions on $PROJECT_ID"
MEMBER="user:$ACCOUNT"
case "$ACCOUNT" in *.gserviceaccount.com) MEMBER="serviceAccount:$ACCOUNT" ;; esac
if gc projects get-iam-policy "$PROJECT_ID" --format=json; then
  MY_ROLES=$(printf '%s' "$GC_OUT" | python3 -c '
import json, sys
m = sys.argv[1]
print(", ".join(sorted(b["role"] for b in json.load(sys.stdin).get("bindings", []) if m in b.get("members", []))))' "$MEMBER")
  info "Roles granted to $MEMBER directly: ${MY_ROLES:-none}. Roles through groups or folders are not listed here."
  if printf '%s' "$MY_ROLES" | grep -qE 'roles/owner'; then
    pass "You hold roles/owner on the project."
  fi
else
  [ $? = 2 ] && skip "Your roles on the project" "resourcemanager.projects.getIamPolicy (roles/viewer)"
fi
# One permission per resource family the module creates, checked the way IAM
# evaluates them for your account (groups and inherited roles included).
PERMS="compute.networks.create compute.subnetworks.create compute.firewalls.create compute.instanceTemplates.create compute.instanceGroupManagers.create compute.addresses.create compute.forwardingRules.create compute.regionBackendServices.create compute.healthChecks.create compute.projects.setCommonInstanceMetadata compute.serviceAttachments.create container.clusters.create container.clusters.get cloudkms.keyRings.create cloudkms.cryptoKeys.create cloudkms.cryptoKeys.setIamPolicy secretmanager.secrets.create secretmanager.secrets.setIamPolicy parametermanager.parameters.create artifactregistry.repositories.create artifactregistry.repositories.uploadArtifacts dns.managedZones.create dns.changes.create iam.serviceAccounts.create iam.serviceAccounts.setIamPolicy resourcemanager.projects.setIamPolicy resourcemanager.projects.get storage.buckets.create serviceusage.services.enable"
if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  PERM_JSON=$(printf '%s' "$PERMS" | python3 -c 'import json,sys; print(json.dumps({"permissions": sys.stdin.read().split()}))')
  RESP=$(curl -sS -X POST -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" -H 'Content-Type: application/json' \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" -d "$PERM_JSON" 2>/dev/null)
  MISSING=$(printf '%s' "$RESP" | python3 -c '
import json, sys
want = sys.argv[1].split()
try:
    d = json.load(sys.stdin)
except Exception:
    print("__err__"); sys.exit()
if "error" in d:
    print("__err__ " + str(d["error"].get("message", ""))[:160]); sys.exit()
got = set(d.get("permissions", []))
print(" ".join(p for p in want if p not in got))' "$PERMS")
  case "$MISSING" in
    "") pass "Your account holds every permission the deployment needs ($(printf '%s' "$PERMS" | wc -w | tr -d ' ') checked)." ;;
    __err__*) warn "Could not test your permissions." "${MISSING#__err__ }" ;;
    *) fail "Your account is missing permissions: $MISSING" "Ask a project owner for roles/owner on $PROJECT_ID, or a role that grants these permissions." ;;
  esac
else
  info "curl or python3 missing: your permissions were not tested one by one."
fi

# ---------------------------------------------------------------- 5. Local tools
section "Local tools"
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }
if command -v terraform >/dev/null 2>&1; then
  TF_VER=$(terraform version 2>/dev/null | head -1 | sed -E 's/^Terraform v//')
  if ver_ge "$TF_VER" "$TF_MIN_VERSION"; then
    pass "terraform $TF_VER is installed (needs >= $TF_MIN_VERSION)."
  else
    fail "terraform $TF_VER is too old." "The deployment needs Terraform >= $TF_MIN_VERSION: https://developer.hashicorp.com/terraform/install"
  fi
else
  fail "terraform is not installed." "Install Terraform >= $TF_MIN_VERSION: https://developer.hashicorp.com/terraform/install"
fi
tool() {
  local cmd="$1" hint="$2" v
  if command -v "$cmd" >/dev/null 2>&1; then
    v=$("$cmd" "${@:3}" 2>/dev/null | head -1 | cut -c1-60)
    pass "$cmd is installed${v:+ ($v)}."
  else
    fail "$cmd is not installed." "$hint"
  fi
}
tool helm    "Install Helm: https://helm.sh/docs/intro/install/" version --short
tool kubectl "Install kubectl: https://kubernetes.io/docs/tasks/tools/" version --client
tool crane   "Install crane: https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md" version
tool perl    "Install perl (ships with macOS and most Linux distributions)." -e 'print "$^V\n"'
tool python3 "Install Python 3: https://www.python.org/downloads/" --version
if gcloud components list --format='value(id,state.name)' 2>/dev/null | grep -qE '^gke-gcloud-auth-plugin\s+Installed'; then
  pass "gke-gcloud-auth-plugin is installed."
elif command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  pass "gke-gcloud-auth-plugin is installed."
else
  fail "gke-gcloud-auth-plugin is not installed." "kubectl needs it to reach the cluster: gcloud components install gke-gcloud-auth-plugin"
fi

# ---------------------------------------------------------------- 6. Onboarding with Fundamental
section "Onboarding with Fundamental"
if [ -n "$BUNDLE_VERSION" ]; then
  if ! printf '%s' "$BUNDLE_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "bundle_version '$BUNDLE_VERSION' is not a plain X.Y.Z." "Use the version Fundamental named for the release, for example 1.0.2."
  fi
  if gc storage ls "gs://$PRODUCER_BUCKET/bundles/$BUNDLE_VERSION/app-manifest.json"; then
    pass "Bundle $BUNDLE_VERSION is readable in gs://$PRODUCER_BUCKET."
  else
    case $? in
      2) fail "Bundle bucket gs://$PRODUCER_BUCKET is not readable by $ACCOUNT." "Fundamental grants read access to the principals of project number ${PROJECT_NUMBER:-<project number>} during onboarding. Confirm onboarding is complete and that you run as an account with a role in this project." ;;
      *) fail "Bundle $BUNDLE_VERSION was not found in gs://$PRODUCER_BUCKET/bundles/." "Check bundle_version against the release Fundamental named. $(first_err_line)" ;;
    esac
  fi
else
  if gc storage ls "gs://$PRODUCER_BUCKET/bundles/"; then
    pass "Bundle bucket gs://$PRODUCER_BUCKET is readable. Set bundle_version to check one release."
  else
    case $? in
      2) fail "Bundle bucket gs://$PRODUCER_BUCKET is not readable by $ACCOUNT." "Fundamental grants read access to the principals of project number ${PROJECT_NUMBER:-<project number>} during onboarding. Confirm onboarding is complete and that you run as an account with a role in this project." ;;
      *) warn "Could not list gs://$PRODUCER_BUCKET/bundles/." "$(first_err_line)" ;;
    esac
  fi
fi
if [ -n "$HARDENED_IMAGE" ]; then
  if gc compute images describe "$HARDENED_IMAGE" --format='value(name,status)'; then
    IMG_STATUS=$(printf '%s' "$GC_OUT" | cut -f2)
    [ "$IMG_STATUS" = "READY" ] && pass "Hardened image $HARDENED_IMAGE is readable and READY." \
      || warn "Hardened image $HARDENED_IMAGE is in state $IMG_STATUS." "Ask Fundamental which image to use."
  else
    case $? in
      2) fail "Hardened image $HARDENED_IMAGE is not readable." "Fundamental makes the image readable by your project during onboarding. Confirm onboarding is complete." ;;
      *) fail "Hardened image $HARDENED_IMAGE was not found." "Either the name is wrong, or Fundamental has not yet shared it with your project (onboarding). An image you cannot read also reports not found." ;;
    esac
  fi
else
  info "hardened_image not set: the image is not checked. Pass -t with hardened_image set."
fi
info "The attestation broker's PSC service attachment must also accept your project number. Only Fundamental can confirm that."

# ---------------------------------------------------------------- 7. Region and zones
section "Region and zones"
check_region() {
  local r="$1"
  if gc compute regions describe "$r" --format='value(status)'; then
    [ "$GC_OUT" = "UP" ] && pass "Region $r is valid." || warn "Region $r is in state $GC_OUT."
    return 0
  fi
  case $? in
    2) skip "Region $r is valid" "compute.regions.get (roles/compute.viewer)" ;;
    *) fail "Region '$r' is not a valid region." "Use the short name, for example us-east5. List: gcloud compute regions list" ;;
  esac
  return 1
}
# zones_in <region> -> space separated zone names, cached per region
zones_in() {
  local f="$TMP/zones.$1"
  if [ ! -f "$f" ]; then
    if gc compute zones list --filter="region:($1)" --format='value(name)'; then printf '%s' "$GC_OUT" | tr '\n' ' ' > "$f"; else echo "__err__" > "$f"; fi
  fi
  cat "$f"
}
check_zones() {
  local label="$1" region="$2" zones="$3" bad="" z all
  all=$(zones_in "$region")
  for z in $zones; do
    case "$z" in "$region"-*) ;; *) bad="$bad $z"; continue ;; esac
    [ "$all" = "__err__" ] && continue
    printf ' %s ' "$all" | grep -q " $z " || bad="$bad $z"
  done
  if [ -n "$bad" ]; then
    fail "$label: zone(s)$bad are not in region $region." "List the zones: gcloud compute zones list --filter='region:($region)'"
  else
    pass "$label: zones $zones are in $region."
  fi
}
check_region "$REGION" && check_zones "zones" "$REGION" "$ZONES"
if [ "$REGION" = "us-central1" ]; then
  info "Region is us-central1: the attestation endpoint shares the private subnet."
elif tv_set existing_network.network; then
  info "The attestation endpoint needs a subnet in us-central1: existing_network.attestation_psc_subnet (checked below)."
else
  info "The attestation endpoint needs a small subnet in us-central1; the deployment creates it (attestation_psc_subnet_cidr)."
fi
if [ "$GPU_REGION" != "$REGION" ]; then
  check_region "$GPU_REGION" && info "modelgpu.region is set: the GPU tier runs in $GPU_REGION."
  if ! tv_set modelgpu.zones; then
    fail "modelgpu.region is set but modelgpu.zones is not." "Set modelgpu.zones to zones of $GPU_REGION."
  fi
fi

# ---------------------------------------------------------------- 8. Compute capacity
section "Compute capacity"
# Tiers: "<label>|<machine type>|<count>|<region>|<zones>|<spot>"
TIERS=""
add_tier() { TIERS="${TIERS}$1|$2|$3|$4|$5|$6"$'\n'; }
# tier_val <tier> <key> <base prefix> <default>: tier_overrides.<tier>.<key>, else <base>.<key>, else default
tier_val() { tv "tier_overrides.$1.$2" "$(tv "$3.$2" "$4")"; }
CPU_LAYOUT=$(tv modelcpu_layout combined); GPU_LAYOUT=$(tv modelgpu_layout combined)
if [ "$GPU_LAYOUT" = "split" ] && [ "$CPU_LAYOUT" != "split" ]; then
  fail "modelgpu_layout = \"split\" requires modelcpu_layout = \"split\"." "Set both layouts to split, or the GPU layout to combined."
fi
if [ "$CPU_LAYOUT" = "split" ]; then
  for t in modelcpu-train modelcpu-predict; do
    add_tier "$t" "$(tier_val $t machine_type modelcpu n2-standard-32)" "$(tier_val $t target_size modelcpu 1)" "$REGION" "$(tier_val $t zones modelcpu "$ZONES")" "$(tier_val $t spot modelcpu false)"
  done
else
  add_tier "modelcpu" "$(tv modelcpu.machine_type n2-standard-32)" "$(tv modelcpu.target_size 1)" "$REGION" "$(tv modelcpu.zones "$ZONES")" "$(tv modelcpu.spot false)"
fi
if [ "$GPU_LAYOUT" = "split" ]; then
  for t in modelgpu-train modelgpu-predict; do
    add_tier "$t" "$(tier_val $t machine_type modelgpu a3-ultragpu-8g)" "$(tier_val $t target_size modelgpu 1)" "$GPU_REGION" "$(tier_val $t zones modelgpu "$(tv modelgpu.zones "$ZONES")")" "$(tier_val $t spot modelgpu false)"
  done
else
  add_tier "modelgpu" "$(tv modelgpu.machine_type a3-ultragpu-8g)" "$(tv modelgpu.target_size 1)" "$GPU_REGION" "$(tv modelgpu.zones "$ZONES")" "$(tv modelgpu.spot false)"
fi
TW_SIZE=$(tv temporal_worker.target_size 1)
if [ "$TW_SIZE" != "0" ]; then
  add_tier "temporal-worker" "$(tv temporal_worker.machine_type n2-highmem-32)" "$TW_SIZE" "$REGION" "$(tv temporal_worker.zones "$ZONES")" "$(tv temporal_worker.spot false)"
else
  info "temporal_worker.target_size = 0: the tier is disabled."
fi
GKE_TYPES=$(tv gke_node_machine_types n2-standard-16)
GKE_MIN=$(tv gke_min_node_count_per_zone 1)
GKE_MAX=$(tv gke_max_node_count_per_zone 64)
ZONE_COUNT=$(printf '%s\n' "$ZONES" | wc -w | tr -d ' ')
first=1
for mt in $GKE_TYPES; do
  if [ "$first" = 1 ]; then add_tier "GKE platform pool" "$mt" "$((GKE_MIN * ZONE_COUNT))" "$REGION" "$ZONES" "false"; first=0
  else add_tier "GKE platform pool (fallback)" "$mt" "0" "$REGION" "$ZONES" "false"; fi
done
info "GKE pool starts at $GKE_MIN node(s) per zone and can grow to $GKE_MAX per zone. Quota below covers the start size."

# region_quota <region> -> file with "METRIC LIMIT USAGE" lines, cached
region_quota() {
  local f="$TMP/quota.$1"
  if [ ! -f "$f" ]; then
    if gc compute regions describe "$1" --format=json; then
      printf '%s' "$GC_OUT" | python3 -c '
import json, sys
for q in json.load(sys.stdin).get("quotas", []):
    print(q["metric"], int(q["limit"]) if q["limit"] < 1e15 else -1, int(q["usage"]))' > "$f"
    else
      echo "__perm__" > "$f"
    fi
  fi
  printf '%s' "$f"
}
# quota_row <region> <metric> -> "limit usage" or empty
quota_row() { awk -v m="$2" '$1==m{print $2, $3; exit}' "$(region_quota "$1")"; }
# gpu_metric <accelerator type> <spot> -> quota metric name
gpu_metric() {
  local m
  case "$1" in
    nvidia-h200-141gb) m="NVIDIA_H200_GPUS" ;;
    nvidia-rtx-pro-6000) m="NVIDIA_RTX_PRO_6000_GPUS" ;;
    nvidia-a100-80gb) m="NVIDIA_A100_80GB_GPUS" ;;
    nvidia-tesla-a100) m="NVIDIA_A100_GPUS" ;;
    nvidia-l4) m="NVIDIA_L4_GPUS" ;;
    nvidia-tesla-t4) m="NVIDIA_T4_GPUS" ;;
    nvidia-h100-80gb|nvidia-h100-mega-80gb) m="NVIDIA_H100_GPUS" ;;
    *) m="$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | sed 's/^NVIDIA_TESLA_/NVIDIA_/')_GPUS" ;;
  esac
  [ "$2" = "true" ] && m="PREEMPTIBLE_$m"
  printf '%s' "$m"
}
# TODO: GPU quota metric names for H200 (a3-ultragpu) and RTX PRO 6000 (g4)
# could not be verified with gcloud: neither appears in `compute regions
# describe` for the regions checked, even where the machine types are offered.
# The A100, L4 and T4 names above are verified. When no row matches, the
# script prints the GPU rows it found and reports WARN instead of PASS/FAIL.

printf '%s\n' "$TIERS" | awk -F'|' 'NF{print $2}' | sort -u > "$TMP/types"
CPU_NEEDS="$TMP/cpu-needs"; : > "$CPU_NEEDS"
GPU_NEEDS="$TMP/gpu-needs"; : > "$GPU_NEEDS"
while IFS='|' read -r label mtype count region zones spot; do
  [ -n "$label" ] || continue
  if printf '%s' "$mtype" | grep -qE '^g4-standard-(6|12|24)$'; then
    fail "$label: $mtype is a fractional vGPU slice." "The open NVIDIA driver in the hardened image refuses vGPU shapes. Use g4-standard-48 or larger (a whole GPU), or a3-ultragpu-8g."
    continue
  fi
  vcpu=""; accel=""; acount=0; missing=""; perm=0
  for z in $zones; do
    if gc compute machine-types describe "$mtype" --zone "$z" --format='value(guestCpus,accelerators[0].guestAcceleratorType,accelerators[0].guestAcceleratorCount)'; then
      vcpu=$(printf '%s' "$GC_OUT" | cut -f1); accel=$(printf '%s' "$GC_OUT" | cut -f2); acount=$(printf '%s' "$GC_OUT" | cut -f3)
    else
      case $? in 2) perm=1 ;; *) missing="$missing $z" ;; esac
    fi
  done
  if [ "$perm" = 1 ] && [ -z "$vcpu" ]; then
    skip "$label: $mtype is offered in $zones" "compute.machineTypes.get (roles/compute.viewer)"; continue
  fi
  if [ -n "$missing" ]; then
    fail "$label: $mtype is not offered in zone(s)$missing." "Pick zones that offer it: gcloud compute machine-types list --filter='name=$mtype AND zone:($region)'. GPU shapes are often offered in a few zones only."
    [ -z "$vcpu" ] && continue
  else
    pass "$label: $mtype x $count is offered in $zones."
  fi
  if [ "$count" -gt 0 ] 2>/dev/null; then
    family=$(printf '%s' "$mtype" | cut -d- -f1 | tr '[:lower:]' '[:upper:]')
    printf '%s %s %s %s\n' "$region" "$family" "$((vcpu * count))" "$spot" >> "$CPU_NEEDS"
    if [ -n "$accel" ]; then
      printf '%s %s %s %s %s\n' "$region" "$accel" "$((acount * count))" "$spot" "$label" >> "$GPU_NEEDS"
    fi
  fi
done <<<"$TIERS"

# vCPU quota: per family row when the region reports one, plus the regional total.
for region in $(awk '{print $1}' "$CPU_NEEDS" | sort -u); do
  if grep -q '__perm__' "$(region_quota "$region")"; then
    skip "vCPU and GPU quota in $region" "compute.regions.get (roles/compute.viewer)"; continue
  fi
  awk -v r="$region" '$1==r && $4=="false"{a[$2]+=$3; t+=$3} $1==r && $4=="true"{p+=$3} END{for(k in a) print k, a[k]; print "CPUS", t+0; print "PREEMPTIBLE_CPUS", p+0}' "$CPU_NEEDS" > "$TMP/needs.$region"
  while read -r family need; do
    [ "$need" -gt 0 ] || continue
    case "$family" in CPUS|PREEMPTIBLE_CPUS) metric="$family" ;; *) metric="${family}_CPUS" ;; esac
    read -r limit usage <<<"$(quota_row "$region" "$metric")"
    if [ -z "${limit:-}" ]; then
      [ "$metric" = "CPUS" ] || [ "$metric" = "PREEMPTIBLE_CPUS" ] && warn "No quota row $metric in $region." "Check the Console: IAM & Admin > Quotas, filter on Compute Engine API and $region."
      continue
    fi
    [ "$limit" -lt 0 ] && continue
    free=$((limit - usage))
    if [ "$free" -ge "$need" ]; then
      pass "Quota $metric in $region: need $need, $free free (limit $limit, used $usage)."
    else
      fail "Quota $metric in $region: need $need, only $free free (limit $limit, used $usage)." "Request an increase: Console > IAM & Admin > Quotas, filter on $metric and $region."
    fi
  done < "$TMP/needs.$region"
done
# GPU quota per accelerator type.
while read -r region accel need spot label; do
  [ -n "$region" ] || continue
  grep -q '__perm__' "$(region_quota "$region")" && continue
  metric=$(gpu_metric "$accel" "$spot")
  read -r limit usage <<<"$(quota_row "$region" "$metric")"
  if [ -z "${limit:-}" ]; then
    rows=$(awk -v k="$(printf '%s' "$accel" | sed -E 's/^nvidia-(tesla-)?//; s/-.*//' | tr '[:lower:]' '[:upper:]')" 'index($1, k) && $1 !~ /^COMMITTED_/ {printf "%s=%s/%s ", $1, $3, $2}' "$(region_quota "$region")")
    warn "$label: no quota row $metric found in $region for $accel. Verify the GPU quota yourself." "Console > IAM & Admin > Quotas, filter on Compute Engine API, $region and the GPU name. Need $need GPU(s). Rows found: ${rows:-none}"
    continue
  fi
  free=$((limit - usage))
  if [ "$free" -ge "$need" ]; then
    pass "$label: GPU quota $metric in $region: need $need, $free free (limit $limit, used $usage)."
  else
    fail "$label: GPU quota $metric in $region: need $need, only $free free (limit $limit, used $usage)." "Request an increase: Console > IAM & Admin > Quotas, filter on $metric and $region. a3-ultragpu-8g often also needs a reservation."
  fi
done < "$GPU_NEEDS"
info "Quota covers the start size of each tier. Add headroom for a tier you plan to scale."

# ---------------------------------------------------------------- 9. Terraform state
section "Terraform state"
STATE_BUCKET="$PROJECT_ID-tfstate-fun"; STATE_EXISTS=0
if gc storage buckets describe "gs://$STATE_BUCKET" --format='value(location)'; then
  STATE_EXISTS=1
  info "State bucket gs://$STATE_BUCKET exists (location $GC_OUT): an earlier deployment of this project. The deploy script continues from its state."
else
  case $? in
    2) skip "State bucket gs://$STATE_BUCKET" "storage.buckets.get (roles/storage.admin or roles/viewer)" ;;
    *) info "State bucket gs://$STATE_BUCKET does not exist yet: the deploy script creates it on the first run." ;;
  esac
fi

# ---------------------------------------------------------------- 10. Network
section "Network"
# parse_link <self-link> -> "project kind region name" (region is - for global)
parse_link() {
  printf '%s' "$1" | sed -E 's#^https://www.googleapis.com/compute/v1/##' | awk -F/ '
    $1=="projects" && $3=="global" && $4=="networks" {print $2, "network", "-", $5; exit}
    $1=="projects" && $3=="regions" && $5=="subnetworks" {print $2, "subnet", $4, $6; exit}'
}
# check_subnet <label> <self-link> <expected region> <want pga 0|1> [<range names>]
check_subnet() {
  local label="$1" link="$2" want_region="$3" want_pga="$4" ranges="${5:-}"
  read -r sp kind sr sname <<<"$(parse_link "$link")"
  if [ "$kind" != "subnet" ]; then
    fail "$label: '$link' is not a subnet self-link." "Expected: projects/<project>/regions/<region>/subnetworks/<name>"; return
  fi
  if [ -n "$want_region" ] && [ "$sr" != "$want_region" ]; then
    fail "$label: subnet $sname is in $sr, not $want_region." "Use a subnet in $want_region."
  fi
  if run_gc compute networks subnets describe "$sname" --region "$sr" --project "$sp" --format='value(network.basename(),privateIpGoogleAccess,secondaryIpRanges[].rangeName)'; then
    local net pga rng
    net=$(printf '%s' "$GC_OUT" | cut -f1); pga=$(printf '%s' "$GC_OUT" | cut -f2); rng=$(printf '%s' "$GC_OUT" | cut -f3)
    pass "$label: subnet $sname exists in $sr."
    if [ -n "$NET_NAME" ] && [ "$net" != "$NET_NAME" ]; then
      fail "$label: subnet $sname belongs to network $net, not $NET_NAME." "Every subnet in existing_network must be in existing_network.network."
    fi
    if [ "$want_pga" = 1 ]; then
      [ "$pga" = "True" ] && pass "$label: Private Google Access is on." \
        || fail "$label: Private Google Access is off on $sname." "Turn it on: gcloud compute networks subnets update $sname --region $sr --project $sp --enable-private-ip-google-access"
    fi
    local r
    for r in $ranges; do
      printf ';%s;' "$rng" | grep -q ";$r;" && pass "$label: secondary range '$r' is present." \
        || fail "$label: no secondary range named '$r' on $sname." "Add it: gcloud compute networks subnets update $sname --region $sr --project $sp --add-secondary-ranges $r=<cidr>"
    done
  else
    case $? in
      2) skip "$label: subnet $sname exists with Private Google Access and the secondary ranges" "compute.subnetworks.get on project $sp (roles/compute.viewer)" ;;
      *) fail "$label: subnet $sname was not found in $sr of project $sp." "$(first_err_line)" ;;
    esac
  fi
}
NET_NAME=""
if tv_set existing_network.network; then
  info "Deploying into an existing VPC (existing_network)."
  NET_LINK=$(tv existing_network.network "")
  read -r np kind _ NET_NAME <<<"$(parse_link "$NET_LINK")"
  if [ "$kind" != "network" ]; then
    fail "existing_network.network '$NET_LINK' is not a network self-link." "Expected: projects/<project>/global/networks/<name>"; NET_NAME=""
  elif run_gc compute networks describe "$NET_NAME" --project "$np" --format='value(name)'; then
    pass "Network $NET_NAME exists in project $np."
    if run_gc dns managed-zones list --project "$np" --filter="privateVisibilityConfig.networks.networkUrl~/networks/$NET_NAME\$ AND (dnsName=ftm-int.net. OR dnsName=gcp.fundamental.tech.)" --format='value(name)'; then
      if [ -z "$GC_OUT" ]; then
        pass "No private zone ftm-int.net or gcp.fundamental.tech is attached to $NET_NAME yet."
      elif [ "$STATE_EXISTS" = 1 ]; then
        warn "Private DNS zone(s) attached to $NET_NAME: $(printf '%s' "$GC_OUT" | tr '\n' ' ')" "They belong to this project's earlier deployment (state bucket exists). Fine for an upgrade; a second deployment in the same network is not supported."
      else
        fail "Private DNS zone(s) already attached to $NET_NAME: $(printf '%s' "$GC_OUT" | tr '\n' ' ')" "A network carries one deployment. Use another network."
      fi
    fi
  else
    case $? in
      2) skip "Network $NET_NAME exists" "compute.networks.get on project $np (roles/compute.viewer)" ;;
      *) fail "Network $NET_NAME was not found in project $np." "$(first_err_line)" ;;
    esac
  fi
  if tv_set existing_network.private_subnet; then
    check_subnet "private subnet" "$(tv existing_network.private_subnet "")" "$REGION" 1 "$(tv existing_network.pods_range_name pods) $(tv existing_network.services_range_name services)"
  else
    fail "existing_network.private_subnet is not set." "It carries the GKE nodes and the sealed CPU tiers."
  fi
  if [ "$GPU_REGION" != "$REGION" ]; then
    if tv_set existing_network.modelgpu_subnet; then
      check_subnet "modelgpu subnet" "$(tv existing_network.modelgpu_subnet "")" "$GPU_REGION" 1
    else
      fail "existing_network.modelgpu_subnet is required when modelgpu.region ($GPU_REGION) differs from region ($REGION)." "Set it to a subnet in $GPU_REGION, or remove modelgpu.region."
    fi
  elif tv_set existing_network.modelgpu_subnet; then
    check_subnet "modelgpu subnet" "$(tv existing_network.modelgpu_subnet "")" "$GPU_REGION" 1
  else
    info "The GPU tier shares the private subnet (modelgpu.region not set)."
  fi
  if [ "$REGION" != "us-central1" ]; then
    if tv_set existing_network.attestation_psc_subnet; then
      check_subnet "attestation PSC subnet" "$(tv existing_network.attestation_psc_subnet "")" "us-central1" 1
    else
      fail "existing_network.attestation_psc_subnet is required when region is not us-central1." "The attestation broker's service attachment is in us-central1; the consumer endpoint needs a subnet there. Set it to a small subnet of $NET_NAME in us-central1."
    fi
  fi
  for k in proxy_only_subnet psc_nat_subnet; do
    tv_set "existing_network.$k" && check_subnet "$k" "$(tv "existing_network.$k" "")" "$REGION" 0
  done
else
  VPC="$DEPLOYMENT_NAME-vpc"
  info "A new VPC $VPC is created with $(tv vpc_cidr 10.0.0.0/16): subnet $(tv private_subnet_1_cidr 10.0.0.0/22), pods $(tv gke_pods_cidr 10.0.128.0/17), services $(tv gke_services_cidr 10.0.16.0/20), GPU $(tv modelgpu_subnet_cidr 10.0.48.0/22), control plane $(tv gke_master_ipv4_cidr 172.16.0.0/28)."
  if gc compute networks describe "$VPC" --format='value(name)'; then
    if [ "$STATE_EXISTS" = 1 ]; then
      info "Network $VPC exists: this project's earlier deployment. The deploy script continues from its state."
    else
      warn "A network named $VPC already exists in $PROJECT_ID, but no state bucket does." "A project holds one deployment. If this is a leftover, remove it or use another project."
    fi
  else
    [ $? = 1 ] && pass "No network named $VPC exists yet."
  fi
fi
if printf '%s' "$DEPLOYMENT_NAME" | grep -qE '^[a-z]([a-z0-9-]*[a-z0-9])?$'; then
  pass "deployment_name '$DEPLOYMENT_NAME' has a valid format."
else
  fail "deployment_name '$DEPLOYMENT_NAME' is not valid." "Use lowercase letters, digits and hyphens, starting with a letter. It prefixes every resource name."
fi

# ---------------------------------------------------------------- 11. Customer exposure (optional)
section "Customer exposure (optional)"
if [ "$EXPOSURE" != "true" ]; then
  info "customer_exposure_enabled is off: the platform is reachable only inside the deployment VPC, on the ftm-int.net names."
else
  info "customer_exposure_enabled is on: the apps are published over Private Service Connect under your domain."
  if tv_set edge_proxy_only_subnet_cidr || tv_set existing_network.proxy_only_subnet; then pass "Proxy-only subnet is configured."
  else fail "edge_proxy_only_subnet_cidr is not set." "The edge load balancer needs a REGIONAL_MANAGED_PROXY subnet, for example 10.0.40.0/26, or existing_network.proxy_only_subnet."; fi
  if tv_set edge_psc_nat_subnet_cidr || tv_set existing_network.psc_nat_subnet; then pass "PSC NAT subnet is configured."
  else fail "edge_psc_nat_subnet_cidr is not set." "The PSC service attachment needs a PRIVATE_SERVICE_CONNECT subnet, for example 10.0.40.64/28, or existing_network.psc_nat_subnet."; fi
  CONSUMERS=$(tv allowed_consumer_projects "")
  if [ -z "$CONSUMERS" ]; then
    fail "allowed_consumer_projects is empty." "List the project id(s) that will create the PSC consumer endpoint."
  else
    for cp in $CONSUMERS; do
      if run_gc projects describe "$cp" --format='value(projectId)'; then pass "Consumer project $cp exists."
      else case $? in 2) skip "Consumer project $cp exists" "resourcemanager.projects.get on $cp" ;; *) fail "Consumer project $cp was not found." "Check allowed_consumer_projects." ;; esac; fi
    done
  fi
  N_APPS=$(tv 'exposed_apps.#' 0)
  if [ "$N_APPS" = "0" ]; then
    fail "exposed_apps is empty." "Copy the exposed_apps block from example.tfvars and set the hosts under your domain."
  else
    HOSTS=""
    i=0
    while [ "$i" -lt "$N_APPS" ]; do HOSTS="$HOSTS $(tv "exposed_apps.$i.host" "")"; i=$((i+1)); done
    pass "$N_APPS app(s) exposed:$HOSTS"
    for h in $HOSTS; do
      printf '%s' "$h" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || fail "Host '$h' is not a valid hostname." "Use lowercase, no scheme, no wildcard, no trailing dot."
    done
  fi
  if [ "$GKE_MIN" -lt 1 ] 2>/dev/null; then
    fail "gke_min_node_count_per_zone is $GKE_MIN." "With customer exposure the edge needs a node in every zone: keep it at least 1."
  fi
  if [ -z "$EDGE_CERT" ]; then
    info "edge_certificate_id not set: the edge serves plain HTTP. Set it for HTTPS."
  else
    CERT_LOC=$(printf '%s' "$EDGE_CERT" | sed -nE 's#.*/locations/([^/]+)/certificates/.*#\1#p')
    if [ -z "$CERT_LOC" ]; then
      fail "edge_certificate_id has the wrong format." "Expected: projects/<project>/locations/<region>/certificates/<name>"
    else
      [ "$CERT_LOC" = "$REGION" ] || fail "Certificate is in location $CERT_LOC, not $REGION." "A regional load balancer needs a certificate in its own region."
      if run_gc certificate-manager certificates describe "$EDGE_CERT" --format='value(sanDnsnames,managed.state,expireTime)'; then
        SANS=$(printf '%s' "$GC_OUT" | cut -f1); CSTATE=$(printf '%s' "$GC_OUT" | cut -f2); CEXP=$(printf '%s' "$GC_OUT" | cut -f3)
        pass "Certificate exists (${CSTATE:-self-managed}${CEXP:+, expires $CEXP})."
        if [ -n "${HOSTS:-}" ]; then
          miss=""
          for h in $HOSTS; do
            dom="${h#*.}"
            printf ';%s;' "$SANS" | grep -qE ";(\*\.$dom|$h);" || miss="$miss $h"
          done
          [ -z "$miss" ] && pass "Certificate covers every exposed host." \
            || fail "Certificate does not cover:$miss" "SANs on the certificate: ${SANS:-none}. It must list each host or a wildcard for its domain."
        fi
      else
        case $? in
          2) skip "Certificate $EDGE_CERT exists and covers the hosts" "certificatemanager.certs.get (roles/certificatemanager.viewer)" ;;
          *) fail "Certificate $EDGE_CERT was not found." "$(first_err_line)" ;;
        esac
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- 12. Organization policies
section "Organization policies"
# org_policy <constraint> -> JSON in GC_OUT, 0 ok, 2 perm, 1 other
org_policy() { gc resource-manager org-policies describe "constraints/$1" --effective --format=json; }
# policy_list <json> -> "ALLOW" | "DENY" | "allowed:<values>" | "denied:<values>" | "none"
policy_list() {
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin); lp = d.get("listPolicy")
if not lp: print("none"); sys.exit()
if lp.get("allValues") in ("ALLOW", "DENY"): print(lp["allValues"]); sys.exit()
if lp.get("allowedValues"): print("allowed:" + " ".join(lp["allowedValues"])); sys.exit()
if lp.get("deniedValues"): print("denied:" + " ".join(lp["deniedValues"])); sys.exit()
print("none")'
}
ORG_SKIP=0
# check_list_policy <constraint> <ok message> <mode> <pattern> <bad message> <hint>
#   mode "denies": FAIL when a denied value matches <pattern>
#   mode "needs":  FAIL when an allowed list exists and no value matches <pattern>
check_list_policy() {
  local c="$1" ok_msg="$2" mode="$3" pattern="$4" bad_msg="$5" hint="$6" v bad=0
  if org_policy "$c"; then
    v=$(policy_list "$GC_OUT")
    case "$v" in
      none|ALLOW) pass "$c: $ok_msg"; return ;;
      DENY) fail "$c denies all values." "$hint"; return ;;
      allowed:*) [ "$mode" = "needs" ] && ! printf '%s' "$v" | grep -qE "$pattern" && bad=1 ;;
      denied:*)  printf '%s' "$v" | grep -qE "$pattern" && bad=1 ;;
    esac
    if [ "$bad" = 1 ]; then fail "$c: $bad_msg ($v)." "$hint"; else warn "$c restricts values: $v." "$hint"; fi
  else
    case $? in 2) ORG_SKIP=1 ;; *) warn "Could not read $c." "$(first_err_line)" ;; esac
  fi
}
if org_policy compute.requireShieldedVm; then
  pass "compute.requireShieldedVm: every VM of the deployment is a Shielded VM, so this constraint is fine either way."
else
  [ $? = 2 ] && ORG_SKIP=1
fi
check_list_policy compute.trustedImageProjects "images from any project are allowed." \
  needs 'fundamental-public' "projects/fundamental-public is not in the allowed image projects" \
  "The sealed tiers boot Fundamental's hardened image from projects/fundamental-public. Ask your org admin to allow it."
check_list_policy compute.disablePrivateServiceConnectCreationForConsumers "PSC consumer endpoints are allowed." \
  denies 'SERVICE_PRODUCERS' "endpoints to service producers are disabled" \
  "The deployment creates a PSC endpoint to Fundamental's attestation broker. Ask your org admin for an exception on this project."
check_list_policy compute.restrictPrivateServiceConnectProducer "connecting to any PSC producer is allowed." \
  needs 'fun-marketplace-prod' "Fundamental's project fun-marketplace-prod is not an allowed producer" \
  "The attestation endpoint connects to a service attachment in Fundamental's project fun-marketplace-prod. Ask your org admin to allow it."
if [ "$EXPOSURE" = "true" ]; then
  check_list_policy compute.restrictPrivateServiceConnectConsumer "any consumer may connect to your edge service attachment." \
    denies '.' "consumers are restricted" \
    "Your consumer project(s) must be allowed to connect to the edge service attachment."
fi
check_list_policy iam.allowedPolicyMemberDomains "principals from any domain may be granted roles." \
  denies '.' "no external principal may be granted a role" \
  "The deployment grants roles/compute.viewer to Fundamental's attestation broker service account (an external principal). Ask your org admin for an exception on this project, or ask Fundamental."
check_list_policy gcp.resourceLocations "resources may be created in any location." \
  denies 'in:(us|global)-locations|'"$REGION" "a location the deployment uses is denied" \
  "The deployment creates resources in $REGION, us-central1 (attestation endpoint), ${GPU_REGION} (GPU tier) and the multi-region $(tv storage_location US) (buckets, key ring). Make sure all are allowed."
check_list_policy gcp.restrictNonCmekServices "services without CMEK are allowed." \
  denies 'artifactregistry|secretmanager' "a service the deployment uses without CMEK is denied" \
  "Buckets, GKE secrets and disks use your own KMS keys; Artifact Registry and Secret Manager do not. Ask your org admin for an exception."
check_list_policy compute.vmExternalIpAccess "irrelevant here: the deployment creates no external IP addresses." \
  denies '^$' "" "The deployment creates no external IP addresses, so this constraint does not affect it."
[ "$ORG_SKIP" = 1 ] && skip "Organization policy constraints" "orgpolicy.policy.get on the project (roles/orgpolicy.policyViewer)"

# ---------------------------------------------------------------- 13. Not checked by this script
section "Confirm yourself"
info "Fundamental confirmed your project number${PROJECT_NUMBER:+ ($PROJECT_NUMBER)} and region: bundle bucket, hardened image and attestation broker access."
if ! tv_set existing_network.network; then
  info "The VPC ranges ($(tv vpc_cidr 10.0.0.0/16), control plane $(tv gke_master_ipv4_cidr 172.16.0.0/28)) do not overlap a network you will peer or connect from."
fi
[ "$EXPOSURE" = "true" ] && info "You own DNS for the exposed hosts and can create A records after the deployment."

# ---------------------------------------------------------------- Summary
section "Summary"
printf '  Passed: %d   Failed: %d   Warnings: %d   Not checked: %d\n' "$N_PASS" "$N_FAIL" "$N_WARN" "$N_SKIP"
if [ "$N_SKIP" -gt 0 ]; then
  echo
  echo "  Checks your account could not run. Ask a project owner to run this script,"
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
