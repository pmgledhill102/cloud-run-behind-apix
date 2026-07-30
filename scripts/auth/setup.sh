#!/usr/bin/env bash
#
# auth/setup.sh — Auth PoC: JWT enforcement layers (~3-4 min first run)
#
# Builds the recommended baseline from docs/auth/jwt-enforcement-design.md §9:
#   - Mock in-house IdP keypair (local) + cr-idp-mock serving the JWKS
#     (= the §7.4 "internal JWKS mirror" posture)
#   - cr-auth-echo: IAM-closed Cloud Run service with JWT middleware and a
#     Cloud Run CUSTOM audience for the Google ID token
#   - Apigee: 'auth-verify' shared flow (VerifyJWT vs the mock JWKS) attached
#     via the env-level PreProxy FLOW HOOK, and proxy 'cr-auth-jwt'
#     (/auth-echo) whose target mints a Google ID token into
#     X-Serverless-Authorization, leaving the client JWT in Authorization
#
# Prerequisites: shared/setup-base.sh + option2/setup.sh (PGA DNS).
#                shared/setup-slow.sh for the Apigee parts (skipped if absent).
#                option2b (VPC-SC perimeter) optional but recommended.
#
# NOTE: the flow hook attaches VerifyJWT to EVERY proxy in the env — the
# option2/3 hello tests will return 401 until auth/teardown.sh runs.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-auth.sh"

echo "=== Auth PoC setup — project: ${PROJECT_ID} ==="
echo "Client JWT:      iss=${JWT_ISSUER} aud=${JWT_AUDIENCE}"
echo "Google ID token: custom audience '${GOOGLE_CUSTOM_AUDIENCE}' via X-Serverless-Authorization"
echo ""

# ============================================================
# Step 1: Mock issuer keypair (stands in for the external IdP)
# ============================================================
echo "--- Step 1: Mock issuer keypair ---"
mkdir -p "${AUTH_STATE_DIR}"
if [[ -f "${AUTH_PRIVATE_KEY}" ]]; then
  echo "Keypair already exists at ${AUTH_PRIVATE_KEY}, skipping."
else
  openssl genrsa -out "${AUTH_PRIVATE_KEY}" 2048 2>/dev/null
  echo "Generated RSA-2048 keypair (kid=${JWT_KID})."
fi
JWKS_JSON="$(build_jwks_json)"
echo "JWKS built (public material only)."

# ============================================================
# Step 2: Build container images (Cloud Build, skip if present)
# ============================================================
echo ""
echo "--- Step 2: Build container images ---"
build_image() {
  local name="$1" img="$2" src="$3"
  if gcloud artifacts docker images describe "${img}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "Image '${img}' already exists, skipping build."
  else
    echo "Building ${name} via Cloud Build (region: ${BUILD_REGION})..."
    gcloud builds submit \
      --region="${BUILD_REGION}" \
      --gcs-source-staging-dir="gs://${CLOUDBUILD_BUCKET}/source" \
      --tag "${img}" \
      "${src}" \
      --project="${PROJECT_ID}"
    echo "Image pushed to ${img}"
  fi
}
build_image "auth-echo" "${AUTH_ECHO_IMAGE_URL}" "${SCRIPT_DIR}/container"
build_image "idp-mock" "${IDP_MOCK_IMAGE_URL}" "${SCRIPT_DIR}/idp-mock"

# ============================================================
# Step 3: Deploy cr-idp-mock (JWKS endpoint / internal mirror)
# ============================================================
echo ""
echo "--- Step 3: Deploy ${IDP_MOCK_SERVICE} ---"
if resource_exists gcloud run services describe "${IDP_MOCK_SERVICE}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Service '${IDP_MOCK_SERVICE}' already exists, skipping."
else
  # allow-unauthenticated: a JWKS is public material — the interesting posture
  # is ingress=internal (in-perimeter reachability only), mirroring §7.4.
  gcloud run deploy "${IDP_MOCK_SERVICE}" \
    --image="${IDP_MOCK_IMAGE_URL}" \
    --region="${REGION}" \
    --ingress=internal \
    --max-instances=2 \
    --min-instances=0 \
    --cpu-throttling \
    --allow-unauthenticated \
    --set-env-vars="^@^JWKS_JSON=${JWKS_JSON}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "Service '${IDP_MOCK_SERVICE}' deployed."
fi
IDP_URL="$(gcloud run services describe "${IDP_MOCK_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
JWKS_URL="${IDP_URL}/.well-known/jwks.json"
echo "JWKS URL: ${JWKS_URL}"

# ============================================================
# Step 4: Deploy cr-auth-echo (IAM-closed, custom audience, middleware)
# ============================================================
echo ""
echo "--- Step 4: Deploy ${AUTH_ECHO_SERVICE} ---"
if resource_exists gcloud run services describe "${AUTH_ECHO_SERVICE}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Service '${AUTH_ECHO_SERVICE}' already exists, skipping."
else
  # JWKS_JSON is also passed as fallback: if the run→run fetch of JWKS_URL
  # fails (ingress=internal vs non-VPC egress — a finding in itself, logged
  # by the container), validation still works. Fail-closed if neither loads.
  gcloud run deploy "${AUTH_ECHO_SERVICE}" \
    --image="${AUTH_ECHO_IMAGE_URL}" \
    --region="${REGION}" \
    --ingress=internal \
    --max-instances=5 \
    --min-instances=0 \
    --cpu-throttling \
    --no-allow-unauthenticated \
    --add-custom-audiences="${GOOGLE_CUSTOM_AUDIENCE}" \
    --set-env-vars="^@^JWKS_URL=${JWKS_URL}@JWKS_JSON=${JWKS_JSON}@EXPECTED_ISS=${JWT_ISSUER}@EXPECTED_AUD=${JWT_AUDIENCE}" \
    --project="${PROJECT_ID}" \
    --quiet
  echo "Service '${AUTH_ECHO_SERVICE}' deployed."
fi
AUTH_ECHO_URL="$(gcloud run services describe "${AUTH_ECHO_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
echo "Service URL: ${AUTH_ECHO_URL}"

# ============================================================
# Step 5: Apigee — shared flow + flow hook + proxy (skip if absent)
# ============================================================
echo ""
echo "--- Step 5: Apigee shared flow, flow hook, proxy ---"
TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "Apigee not provisioned (HTTP ${APIGEE_HTTP}), skipping Apigee steps."
else
  # ---- 5a: shared flow with VerifyJWT ----
  SF_DEPLOYED="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/sharedflows/${AUTH_SHAREDFLOW}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0]['revision'] if d else '')" 2>/dev/null || true)"

  if [[ -n "${SF_DEPLOYED}" ]]; then
    echo "Shared flow '${AUTH_SHAREDFLOW}' already deployed (rev ${SF_DEPLOYED}), skipping."
  else
    echo "Creating shared flow '${AUTH_SHAREDFLOW}'..."
    SF_DIR="$(mktemp -d)"
    mkdir -p "${SF_DIR}/sharedflowbundle/sharedflows" "${SF_DIR}/sharedflowbundle/policies"

    cat > "${SF_DIR}/sharedflowbundle/${AUTH_SHAREDFLOW}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SharedFlowBundle name="${AUTH_SHAREDFLOW}">
  <Description>VerifyJWT vs mock IdP JWKS — attached via env flow hook</Description>
</SharedFlowBundle>
XMLEOF

    cat > "${SF_DIR}/sharedflowbundle/sharedflows/default.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<SharedFlow name="default">
  <Step>
    <Name>VJ-VerifyClientJWT</Name>
  </Step>
</SharedFlow>
XMLEOF

    # Source omitted → the policy reads the Bearer token from the
    # Authorization header (which stays untouched for the target — the
    # Google ID token rides X-Serverless-Authorization instead).
    # Algorithm pinned per design doc §8.4.
    cat > "${SF_DIR}/sharedflowbundle/policies/VJ-VerifyClientJWT.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<VerifyJWT async="false" continueOnError="false" enabled="true" name="VJ-VerifyClientJWT">
  <DisplayName>VJ-VerifyClientJWT</DisplayName>
  <Algorithm>RS256</Algorithm>
  <PublicKey>
    <JWKS uri="${JWKS_URL}"/>
  </PublicKey>
  <Issuer>${JWT_ISSUER}</Issuer>
  <Audience>${JWT_AUDIENCE}</Audience>
</VerifyJWT>
XMLEOF

    SF_ZIP="$(mktemp).zip"
    (cd "${SF_DIR}" && zip -r "${SF_ZIP}" sharedflowbundle/) >/dev/null

    SF_IMPORT="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/sharedflows?name=${AUTH_SHAREDFLOW}&action=import" \
      --data-binary "@${SF_ZIP}")"
    rm -rf "${SF_DIR}" "${SF_ZIP}"

    if echo "${SF_IMPORT}" | grep -q '"error"'; then
      echo "ERROR importing shared flow:"
      echo "${SF_IMPORT}" | python3 -m json.tool 2>/dev/null || echo "${SF_IMPORT}"
      exit 1
    fi
    SF_REV="$(echo "${SF_IMPORT}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))")"
    echo "Imported shared flow revision ${SF_REV}."

    SF_DEPLOY="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/sharedflows/${AUTH_SHAREDFLOW}/revisions/${SF_REV}/deployments?override=true")"
    if echo "${SF_DEPLOY}" | grep -q '"error"'; then
      echo "ERROR deploying shared flow:"
      echo "${SF_DEPLOY}" | python3 -m json.tool 2>/dev/null || echo "${SF_DEPLOY}"
      exit 1
    fi
    echo "Shared flow deployed to '${APIGEE_ENV}'."
  fi

  # ---- 5b: attach via env-level flow hook (fleet-wide, structurally unskippable) ----
  HOOK_CURRENT="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/flowhooks/${AUTH_FLOWHOOK}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sharedFlow',''))" 2>/dev/null || true)"
  if [[ "${HOOK_CURRENT}" == "${AUTH_SHAREDFLOW}" ]]; then
    echo "Flow hook '${AUTH_FLOWHOOK}' already attached to '${AUTH_SHAREDFLOW}', skipping."
  else
    HOOK_RESPONSE="$(curl -s -X PUT \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/flowhooks/${AUTH_FLOWHOOK}" \
      -d "{\"sharedFlow\": \"${AUTH_SHAREDFLOW}\"}")"
    if echo "${HOOK_RESPONSE}" | grep -q '"error"'; then
      echo "ERROR attaching flow hook:"
      echo "${HOOK_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${HOOK_RESPONSE}"
      exit 1
    fi
    echo "Flow hook '${AUTH_FLOWHOOK}' → '${AUTH_SHAREDFLOW}' attached (applies to ALL proxies in '${APIGEE_ENV}')."
  fi

  # ---- 5c: proxy cr-auth-jwt with combined-header target auth ----
  PROXY_DEPLOYED_REV="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_PROXY_NAME}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0]['revision'] if d else '')" 2>/dev/null || true)"

  NEEDS_PROXY=true
  if [[ -n "${PROXY_DEPLOYED_REV}" ]]; then
    CURRENT_TARGET="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${AUTH_PROXY_NAME}/revisions/${PROXY_DEPLOYED_REV}?format=bundle" \
      -o /tmp/auth-proxy-check.zip 2>/dev/null && \
      unzip -p /tmp/auth-proxy-check.zip apiproxy/targets/default.xml 2>/dev/null || true)"
    rm -f /tmp/auth-proxy-check.zip
    if echo "${CURRENT_TARGET}" | grep -q "${AUTH_ECHO_URL}" && \
       echo "${CURRENT_TARGET}" | grep -q "<Audience>${GOOGLE_CUSTOM_AUDIENCE}</Audience>"; then
      echo "Proxy '${AUTH_PROXY_NAME}' already deployed with correct target, skipping."
      NEEDS_PROXY=false
    fi
  fi

  if [[ "${NEEDS_PROXY}" == "true" ]]; then
    echo "Creating proxy '${AUTH_PROXY_NAME}' (BasePath /auth-echo)..."
    BUNDLE_DIR="$(mktemp -d)"
    mkdir -p "${BUNDLE_DIR}/apiproxy/proxies" "${BUNDLE_DIR}/apiproxy/targets"

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
    <BasePath>/auth-echo</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

    # The combined-header pattern (design doc §2): HeaderName sends the
    # minted Google ID token in X-Serverless-Authorization so the client
    # JWT survives untouched in Authorization. Audience is the Cloud Run
    # CUSTOM audience — one fixed string, no per-service URL plumbing.
    cat > "${BUNDLE_DIR}/apiproxy/targets/default.xml" << XMLEOF
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
    <URL>${AUTH_ECHO_URL}</URL>
    <Authentication>
      <HeaderName>X-Serverless-Authorization</HeaderName>
      <GoogleIDToken>
        <Audience>${GOOGLE_CUSTOM_AUDIENCE}</Audience>
      </GoogleIDToken>
    </Authentication>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

    cat > "${BUNDLE_DIR}/apiproxy/${AUTH_PROXY_NAME}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${AUTH_PROXY_NAME}">
  <Description>Auth PoC: client JWT passthrough + Google ID token via X-Serverless-Authorization</Description>
  <BasePaths>/auth-echo</BasePaths>
</APIProxy>
XMLEOF

    BUNDLE_ZIP="$(mktemp).zip"
    (cd "${BUNDLE_DIR}" && zip -r "${BUNDLE_ZIP}" apiproxy/) >/dev/null

    IMPORT_RESPONSE="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${AUTH_PROXY_NAME}&action=import" \
      --data-binary "@${BUNDLE_ZIP}")"
    rm -rf "${BUNDLE_DIR}" "${BUNDLE_ZIP}"

    if echo "${IMPORT_RESPONSE}" | grep -q '"error"'; then
      echo "ERROR importing proxy:"
      echo "${IMPORT_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${IMPORT_RESPONSE}"
      exit 1
    fi
    NEW_REV="$(echo "${IMPORT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))")"
    echo "Imported proxy revision ${NEW_REV}."

    # GoogleIDToken target auth requires a deploy-time SA (mints tokens as it)
    DEPLOY_RESPONSE="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_PROXY_NAME}/revisions/${NEW_REV}/deployments?override=true&serviceAccount=${SA_EMAIL}")"
    if echo "${DEPLOY_RESPONSE}" | grep -q '"error"'; then
      echo "ERROR deploying proxy:"
      echo "${DEPLOY_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${DEPLOY_RESPONSE}"
      exit 1
    fi
    echo "Proxy revision ${NEW_REV} deployed to '${APIGEE_ENV}' as ${SA_EMAIL}."
  fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Auth PoC setup complete ==="
echo ""
echo "Enforcement layers now live:"
echo "  1. Apigee flow hook → '${AUTH_SHAREDFLOW}' shared flow: VerifyJWT (sig/exp/iss/aud)"
echo "  2. Cloud Run IAM: ${AUTH_ECHO_SERVICE} closed, Google ID token w/ custom audience"
echo "  3. In-service middleware: revalidates the client JWT, echoes claims"
echo ""
echo "NOTE: the flow hook now applies VerifyJWT to ALL proxies in '${APIGEE_ENV}'"
echo "      (e.g. /hello now needs a JWT too). Run ./scripts/auth/teardown.sh to detach."
echo ""
echo "Run ./scripts/auth/test.sh to verify."
