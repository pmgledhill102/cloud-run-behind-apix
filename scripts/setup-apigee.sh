#!/usr/bin/env bash
#
# setup-apigee.sh — Provision Apigee X (pay-as-you-go) with VPC Peering
#
# Creates:
#   1. Apigee VPC + peering subnet (for Apigee runtime)
#   2. Apigee X organisation (pay-as-you-go, VPC peering model)
#   3. Apigee runtime instance
#   4. Apigee environment + environment group
#   5. Simple pass-through API proxy
#
# This is the foundation that all option PoC scripts build on.
# Run this ONCE per project before running any option's setup scripts.
#
# Prerequisites:
#   - gcloud CLI authenticated with Owner or Apigee Admin on the project
#   - Billing account linked to the project
#   - Docker (for building the test container in option scripts)
#
# Usage:
#   PROJECT_ID=sb-paul-g-apigee ./setup-apigee.sh
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-apigee}"
REGION="europe-north2"
ANALYTICS_REGION="europe-west1"  # Apigee analytics not available in all regions
CONSUMER_DATA_REGION="europe-west1"  # Must be a specific region, not multi-region "eu"
APIGEE_NETWORK="apigee-vpc"
APIGEE_PEERING_RANGE_NAME="apigee-peering-range"
APIGEE_PEERING_CIDR="10.1.0.0/20"  # Org peering range (4096 IPs)
APIGEE_INSTANCE_RANGE_NAME="apigee-instance-range"
APIGEE_INSTANCE_CIDR="10.2.0.0/22"  # Instance range (/22 minimum for runtime)
APIGEE_ENV="test"
APIGEE_ENV_GROUP="test-group"
APIGEE_ENV_GROUP_HOSTNAME="api.internal.example.com"
APIGEE_API="https://eu-apigee.googleapis.com/v1"  # EU endpoint for data residency

echo "=== Apigee X Provisioning (VPC Peering, Pay-As-You-Go) ==="
echo "Project:          ${PROJECT_ID}"
echo "Region:           ${REGION}"
echo "Analytics region: ${ANALYTICS_REGION}"
echo "Network:          ${APIGEE_NETWORK}"
echo "Peering CIDR:     ${APIGEE_PEERING_CIDR}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Enable APIs
# ============================================================
echo "--- Step 1: Enable APIs ---"
gcloud services enable \
  apigee.googleapis.com \
  compute.googleapis.com \
  servicenetworking.googleapis.com \
  cloudkms.googleapis.com \
  dns.googleapis.com \
  run.googleapis.com \
  iap.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project="${PROJECT_ID}"
echo "APIs enabled."

# ============================================================
# Step 2: Create Apigee VPC (if not exists)
# ============================================================
echo ""
echo "--- Step 2: Create Apigee VPC ---"
if resource_exists gcloud compute networks describe "${APIGEE_NETWORK}" --project="${PROJECT_ID}"; then
  echo "VPC '${APIGEE_NETWORK}' already exists, skipping."
else
  gcloud compute networks create "${APIGEE_NETWORK}" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC '${APIGEE_NETWORK}' created."
fi

# ============================================================
# Step 3: Allocate IP ranges for Apigee peering
# ============================================================
echo ""
echo "--- Step 3: Allocate peering IP ranges ---"

# Range 1: org peering
if gcloud compute addresses describe "${APIGEE_PEERING_RANGE_NAME}" \
    --global --project="${PROJECT_ID}" &>/dev/null; then
  echo "Peering range '${APIGEE_PEERING_RANGE_NAME}' already exists, skipping."
else
  PREFIX_LENGTH="${APIGEE_PEERING_CIDR##*/}"
  RANGE_START="${APIGEE_PEERING_CIDR%%/*}"
  gcloud compute addresses create "${APIGEE_PEERING_RANGE_NAME}" \
    --global \
    --prefix-length="${PREFIX_LENGTH}" \
    --addresses="${RANGE_START}" \
    --description="Apigee X org peering range" \
    --network="${APIGEE_NETWORK}" \
    --purpose=VPC_PEERING \
    --project="${PROJECT_ID}"
  echo "Peering range '${APIGEE_PEERING_RANGE_NAME}' (${APIGEE_PEERING_CIDR}) allocated."
fi

# Range 2: instance range (separate to avoid exhaustion)
if gcloud compute addresses describe "${APIGEE_INSTANCE_RANGE_NAME}" \
    --global --project="${PROJECT_ID}" &>/dev/null; then
  echo "Instance range '${APIGEE_INSTANCE_RANGE_NAME}' already exists, skipping."
else
  INST_PREFIX="${APIGEE_INSTANCE_CIDR##*/}"
  INST_START="${APIGEE_INSTANCE_CIDR%%/*}"
  gcloud compute addresses create "${APIGEE_INSTANCE_RANGE_NAME}" \
    --global \
    --prefix-length="${INST_PREFIX}" \
    --addresses="${INST_START}" \
    --description="Apigee X instance IP range" \
    --network="${APIGEE_NETWORK}" \
    --purpose=VPC_PEERING \
    --project="${PROJECT_ID}"
  echo "Instance range '${APIGEE_INSTANCE_RANGE_NAME}' (${APIGEE_INSTANCE_CIDR}) allocated."
fi

# ============================================================
# Step 4: Create/update VPC peering to servicenetworking
# ============================================================
echo ""
echo "--- Step 4: VPC peering to Google Service Networking ---"

EXISTING_PEERING="$(gcloud compute networks peerings list \
  --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
  --format='value(name)' --filter='network~servicenetworking' 2>/dev/null || true)"

if [[ -n "${EXISTING_PEERING}" ]]; then
  echo "VPC peering already exists. Updating to include both ranges..."
  gcloud services vpc-peerings update \
    --service=servicenetworking.googleapis.com \
    --ranges="${APIGEE_PEERING_RANGE_NAME},${APIGEE_INSTANCE_RANGE_NAME}" \
    --network="${APIGEE_NETWORK}" \
    --project="${PROJECT_ID}"
  echo "Peering updated with both ranges."
else
  gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="${APIGEE_PEERING_RANGE_NAME},${APIGEE_INSTANCE_RANGE_NAME}" \
    --network="${APIGEE_NETWORK}" \
    --project="${PROJECT_ID}"
  echo "VPC peering to servicenetworking established with both ranges."
fi

# ============================================================
# Step 5: Provision Apigee organisation
# ============================================================
echo ""
echo "--- Step 5: Provision Apigee organisation ---"

# Note: gcloud alpha apigee organizations provision only supports eval/trial orgs.
# For pay-as-you-go (PAYG), we use the Apigee REST API directly.

TOKEN="$(gcloud auth print-access-token)"

# Check if org already exists
ORG_STATE="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

if [[ "${ORG_STATE}" == "200" ]]; then
  echo "Apigee org '${PROJECT_ID}' already exists, skipping."
else
  echo "Creating Apigee organisation..."
  echo "  Billing type:  PAYG (pay-as-you-go)"
  echo "  Runtime type:  CLOUD"
  echo "  Analytics:     ${ANALYTICS_REGION}"
  echo "  Network:       ${APIGEE_NETWORK}"
  echo ""

  # Create the org via REST API (supports billingType: PAYG)
  ORG_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${APIGEE_API}/organizations?parent=projects/${PROJECT_ID}" \
    -d "{
      \"displayName\": \"${PROJECT_ID}\",
      \"analyticsRegion\": \"${ANALYTICS_REGION}\",
      \"authorizedNetwork\": \"${APIGEE_NETWORK}\",
      \"runtimeType\": \"CLOUD\",
      \"billingType\": \"PAYG\",
      \"projectId\": \"${PROJECT_ID}\",
      \"apiConsumerDataLocation\": \"${CONSUMER_DATA_REGION}\"
    }")"

  # Check for errors in response
  if echo "${ORG_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR creating Apigee org:"
    echo "${ORG_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${ORG_RESPONSE}"
    exit 1
  fi

  # Extract operation name for polling
  OP_NAME="$(echo "${ORG_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)"
  echo "Organisation creation started."
  if [[ -n "${OP_NAME}" ]]; then
    echo "Operation: ${OP_NAME}"
  fi

  echo ""
  echo "Waiting for org to become ACTIVE..."
  echo "(This is the longest step — typically 30-50 minutes)"
  echo ""

  # Poll for org readiness
  TIMEOUT=3600  # 60 minutes max
  INTERVAL=30
  ELAPSED=0
  while true; do
    # Refresh token periodically (tokens expire after 60 min)
    if (( ELAPSED > 0 && ELAPSED % 1800 == 0 )); then
      TOKEN="$(gcloud auth print-access-token)"
    fi

    STATE="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','NOT_READY'))" 2>/dev/null || echo "NOT_READY")"

    if [[ "${STATE}" == "ACTIVE" ]]; then
      echo "Apigee org is ACTIVE."
      break
    fi
    if (( ELAPSED >= TIMEOUT )); then
      echo "ERROR: Timed out after ${TIMEOUT}s waiting for Apigee org to become ACTIVE."
      echo "Current state: ${STATE}"
      echo "Check: curl -H \"Authorization: Bearer \$(gcloud auth print-access-token)\" ${APIGEE_API}/organizations/${PROJECT_ID}"
      exit 1
    fi
    echo "  State: ${STATE} (${ELAPSED}s elapsed, checking every ${INTERVAL}s)..."
    sleep "${INTERVAL}"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
fi

# ============================================================
# Step 6: Create Apigee runtime instance
# ============================================================
echo ""
echo "--- Step 6: Create Apigee runtime instance ---"

TOKEN="$(gcloud auth print-access-token)"
INSTANCE_NAME="instance-${REGION}"

# Check if instance already exists (any state — CREATING or ACTIVE)
INSTANCE_JSON="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}")"
INSTANCE_EXISTS="$(echo "${INSTANCE_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if 'name' in d else 'no')" 2>/dev/null || echo "no")"
INSTANCE_STATE="$(echo "${INSTANCE_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','UNKNOWN'))" 2>/dev/null || echo "UNKNOWN")"

if [[ "${INSTANCE_EXISTS}" == "yes" && "${INSTANCE_STATE}" == "ACTIVE" ]]; then
  echo "Apigee instance '${INSTANCE_NAME}' already exists and is ACTIVE, skipping."
elif [[ "${INSTANCE_EXISTS}" == "yes" ]]; then
  echo "Apigee instance '${INSTANCE_NAME}' exists (state: ${INSTANCE_STATE}). Waiting..."
else
  echo "Creating Apigee instance '${INSTANCE_NAME}' in ${REGION}..."
  echo "(This may take 30-60 minutes)"

  INST_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/instances" \
    -d "{
      \"name\": \"${INSTANCE_NAME}\",
      \"location\": \"${REGION}\",
      \"ipRange\": \"${APIGEE_INSTANCE_CIDR}\"
    }")"

  if echo "${INST_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR creating Apigee instance:"
    echo "${INST_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${INST_RESPONSE}"
    exit 1
  fi

  echo "Instance creation started."
fi

# Wait for ACTIVE (unless already active)
if [[ "${INSTANCE_STATE}" != "ACTIVE" ]]; then
  echo "Waiting for instance to become ACTIVE..."
  TIMEOUT=3600  # 60 minutes max
  INTERVAL=30
  ELAPSED=0
  while true; do
    if (( ELAPSED > 0 && ELAPSED % 1800 == 0 )); then
      TOKEN="$(gcloud auth print-access-token)"
    fi

    INST_STATE="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state','CREATING'))" 2>/dev/null || echo "CREATING")"

    if [[ "${INST_STATE}" == "ACTIVE" ]]; then
      echo "Apigee instance is ACTIVE."
      break
    fi
    if (( ELAPSED >= TIMEOUT )); then
      echo "ERROR: Timed out after ${TIMEOUT}s waiting for instance."
      echo "Current state: ${INST_STATE}"
      exit 1
    fi
    echo "  State: ${INST_STATE} (${ELAPSED}s elapsed, checking every ${INTERVAL}s)..."
    sleep "${INTERVAL}"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
fi

# ============================================================
# Step 7: Create Apigee environment
# ============================================================
echo ""
echo "--- Step 7: Create Apigee environment ---"

TOKEN="$(gcloud auth print-access-token)"

ENV_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}")"

if [[ "${ENV_HTTP}" == "200" ]]; then
  echo "Environment '${APIGEE_ENV}' already exists, skipping."
else
  ENV_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments" \
    -d "{
      \"name\": \"${APIGEE_ENV}\",
      \"displayName\": \"Test environment\",
      \"description\": \"PoC test environment\"
    }")"

  if echo "${ENV_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR creating environment:"
    echo "${ENV_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${ENV_RESPONSE}"
    exit 1
  fi

  # Wait for environment creation (usually quick, but LRO)
  echo "Waiting for environment creation..."
  sleep 10
  echo "Environment '${APIGEE_ENV}' created."
fi

# ============================================================
# Step 8: Attach environment to instance
# ============================================================
echo ""
echo "--- Step 8: Attach environment to instance ---"

ATTACHMENTS_JSON="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}/attachments")"

if echo "${ATTACHMENTS_JSON}" | grep -q "\"${APIGEE_ENV}\""; then
  echo "Environment '${APIGEE_ENV}' already attached to '${INSTANCE_NAME}', skipping."
else
  ATTACH_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}/attachments" \
    -d "{
      \"environment\": \"${APIGEE_ENV}\"
    }")"

  if echo "${ATTACH_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR attaching environment:"
    echo "${ATTACH_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${ATTACH_RESPONSE}"
    exit 1
  fi

  # Wait for attachment (can take a few minutes)
  echo "Waiting for environment attachment..."
  TIMEOUT=300
  INTERVAL=15
  ELAPSED=0
  while true; do
    CHECK="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}/attachments")"
    if echo "${CHECK}" | grep -q "\"${APIGEE_ENV}\""; then
      echo "Environment '${APIGEE_ENV}' attached to '${INSTANCE_NAME}'."
      break
    fi
    if (( ELAPSED >= TIMEOUT )); then
      echo "WARNING: Attachment may still be in progress. Check manually."
      break
    fi
    sleep "${INTERVAL}"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
fi

# ============================================================
# Step 9: Create environment group + attach environment
# ============================================================
echo ""
echo "--- Step 9: Create environment group ---"

TOKEN="$(gcloud auth print-access-token)"

ENVGROUP_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/envgroups/${APIGEE_ENV_GROUP}")"

if [[ "${ENVGROUP_HTTP}" == "200" ]]; then
  echo "Environment group '${APIGEE_ENV_GROUP}' already exists, skipping."
else
  ENVGROUP_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/envgroups" \
    -d "{
      \"name\": \"${APIGEE_ENV_GROUP}\",
      \"hostnames\": [\"${APIGEE_ENV_GROUP_HOSTNAME}\"]
    }")"

  if echo "${ENVGROUP_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR creating environment group:"
    echo "${ENVGROUP_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${ENVGROUP_RESPONSE}"
    exit 1
  fi

  echo "Waiting for environment group creation..."
  sleep 10
  echo "Environment group '${APIGEE_ENV_GROUP}' created with hostname '${APIGEE_ENV_GROUP_HOSTNAME}'."
fi

# Attach environment to group
ENVGROUP_ATTACHMENTS="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/envgroups/${APIGEE_ENV_GROUP}/attachments")"

if echo "${ENVGROUP_ATTACHMENTS}" | grep -q "\"${APIGEE_ENV}\""; then
  echo "Environment '${APIGEE_ENV}' already attached to group '${APIGEE_ENV_GROUP}', skipping."
else
  ENVGROUP_ATTACH_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/envgroups/${APIGEE_ENV_GROUP}/attachments" \
    -d "{
      \"environment\": \"${APIGEE_ENV}\"
    }")"

  if echo "${ENVGROUP_ATTACH_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR attaching environment to group:"
    echo "${ENVGROUP_ATTACH_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${ENVGROUP_ATTACH_RESPONSE}"
    exit 1
  fi

  echo "Waiting for environment group attachment..."
  sleep 10
  echo "Environment '${APIGEE_ENV}' attached to group '${APIGEE_ENV_GROUP}'."
fi

# ============================================================
# Step 10: Deploy pass-through API proxy
# ============================================================
echo ""
echo "--- Step 10: Deploy pass-through API proxy ---"

TOKEN="$(gcloud auth print-access-token)"
PROXY_NAME="cr-hello-passthrough"

# Check if proxy already exists
PROXY_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${PROXY_NAME}")"

if [[ "${PROXY_HTTP}" == "200" ]]; then
  echo "API proxy '${PROXY_NAME}' already exists, skipping creation."
else
  echo "Creating API proxy bundle..."

  # Create temporary proxy bundle zip
  BUNDLE_DIR="$(mktemp -d)"
  mkdir -p "${BUNDLE_DIR}/apiproxy/proxies"
  mkdir -p "${BUNDLE_DIR}/apiproxy/targets"
  mkdir -p "${BUNDLE_DIR}/apiproxy/policies"

  # Proxy endpoint
  cat > "${BUNDLE_DIR}/apiproxy/proxies/default.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request/>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow">
    <Request/>
    <Response/>
  </PostFlow>
  <HTTPProxyConnection>
    <BasePath>/hello</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

  # Target endpoint — URL will be updated per-option
  cat > "${BUNDLE_DIR}/apiproxy/targets/default.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request/>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow">
    <Request/>
    <Response/>
  </PostFlow>
  <HTTPTargetConnection>
    <URL>https://TARGET_URL_PLACEHOLDER</URL>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

  # Proxy descriptor
  cat > "${BUNDLE_DIR}/apiproxy/${PROXY_NAME}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${PROXY_NAME}">
  <Description>Pass-through proxy to Cloud Run cr-hello service</Description>
  <BasePaths>/hello</BasePaths>
</APIProxy>
XMLEOF

  # Create the bundle zip
  BUNDLE_ZIP="$(mktemp).zip"
  (cd "${BUNDLE_DIR}" && zip -r "${BUNDLE_ZIP}" apiproxy/)

  # Import the proxy via REST API (gcloud has no 'apis create')
  IMPORT_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${PROXY_NAME}&action=import" \
    --data-binary "@${BUNDLE_ZIP}")"

  if echo "${IMPORT_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR importing API proxy:"
    echo "${IMPORT_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${IMPORT_RESPONSE}"
    rm -rf "${BUNDLE_DIR}" "${BUNDLE_ZIP}"
    exit 1
  fi

  rm -rf "${BUNDLE_DIR}" "${BUNDLE_ZIP}"
  echo "API proxy '${PROXY_NAME}' imported (revision 1)."
fi

# Deploy revision 1 if not already deployed
DEPLOY_CHECK="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/deployments")"

if echo "${DEPLOY_CHECK}" | grep -q "\"${PROXY_NAME}\""; then
  echo "Proxy '${PROXY_NAME}' already deployed to '${APIGEE_ENV}', skipping."
else
  DEPLOY_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/1/deployments?override=true")"

  if echo "${DEPLOY_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR deploying proxy:"
    echo "${DEPLOY_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${DEPLOY_RESPONSE}"
    exit 1
  fi

  echo "Proxy '${PROXY_NAME}' revision 1 deployed to '${APIGEE_ENV}'."
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================================"
echo "=== Apigee X Provisioning Complete ==="
echo "============================================================"
echo ""
echo "Organisation: ${PROJECT_ID}"
echo "Instance:     ${INSTANCE_NAME:-instance-${REGION}} (${REGION})"
echo "Environment:  ${APIGEE_ENV}"
echo "Env group:    ${APIGEE_ENV_GROUP} (${APIGEE_ENV_GROUP_HOSTNAME})"
echo "API proxy:    ${PROXY_NAME} → /hello"
echo ""
echo "VPC:          ${APIGEE_NETWORK}"
echo "Peering CIDR: ${APIGEE_PEERING_CIDR} (Apigee runtime IPs)"
echo ""

# Show the internal IP of the Apigee instance
TOKEN="$(gcloud auth print-access-token)"
INSTANCE_HOST="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('host','unknown'))" 2>/dev/null || echo 'unknown')"
echo "Instance internal IP: ${INSTANCE_HOST}"
echo ""
echo "The proxy has a placeholder target URL. Each option's setup"
echo "scripts will configure the correct Cloud Run target URL and"
echo "DNS/networking to reach it."
echo ""
echo "Billing: pay-as-you-go (\$0.50/hr). Run teardown-apigee.sh"
echo "when done to stop charges."
echo ""
echo "Next steps:"
echo "  1. cd scripts/option{1,2,3,4}/"
echo "  2. Run setup-iam.sh, setup-infra.sh, etc."
echo "  3. The option scripts will create subnets, DNS, PSC/VPN"
echo "     in the existing apigee-vpc."
