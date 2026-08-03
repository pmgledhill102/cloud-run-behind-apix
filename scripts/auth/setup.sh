#!/usr/bin/env bash
#
# auth/setup.sh — Auth PoC: JWT enforcement layers (~4-5 min first run)
#
# Builds the recommended baseline from docs/auth/jwt-enforcement-design.md §9
# with BOTH in-service enforcement variants deployed side by side as peers:
#   - Mock in-house IdP keypair (local) + cr-idp-mock serving the JWKS
#     (= the §7.4 "internal JWKS mirror" posture)
#   - cr-auth-echo: IAM-closed Cloud Run service with in-process JWT
#     middleware (library variant) and a Cloud Run CUSTOM audience
#   - cr-auth-echo-envoy: same app behind an Envoy jwt_authn ingress
#     container (sidecar variant, app middleware off via JWT_MODE=off),
#     same IAM posture and custom audience
#   - Apigee: 'auth-verify' shared flow (VerifyJWT vs the mock JWKS) attached
#     via the env-level PreProxy FLOW HOOK, and proxies 'cr-auth-jwt'
#     (/auth-echo) + 'cr-auth-jwt-envoy' (/auth-echo-envoy) whose targets
#     mint a Google ID token into X-Serverless-Authorization, leaving the
#     client JWT in Authorization
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
echo "Variants:        library middleware (/auth-echo) + Envoy sidecar (/auth-echo-envoy)"
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
    # regional-user-owned-bucket: keep the logs bucket in-project — the
    # Google-managed one is outside the VPC-SC perimeter (see setup-base.sh).
    gcloud builds submit \
      --region="${BUILD_REGION}" \
      --gcs-source-staging-dir="gs://${CLOUDBUILD_BUCKET}/source" \
      --default-buckets-behavior=regional-user-owned-bucket \
      --tag "${img}" \
      "${src}" \
      --project="${PROJECT_ID}"
    echo "Image pushed to ${img}"
  fi
}
# auth-echo serves both variants: APP_PORT/JWT_MODE select library vs
# sidecar behaviour at deploy time — one build, two deploy configs.
build_image "auth-echo" "${AUTH_ECHO_IMAGE_URL}" "${SCRIPT_DIR}/container"
build_image "idp-mock" "${IDP_MOCK_IMAGE_URL}" "${SCRIPT_DIR}/idp-mock"
build_image "auth-envoy" "${ENVOY_IMAGE_URL}" "${SCRIPT_DIR}/envoy"

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
# Step 4: Deploy cr-auth-echo (library variant: in-process middleware)
# ============================================================
echo ""
echo "--- Step 4: Deploy ${AUTH_ECHO_SERVICE} (library variant) ---"
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
# Step 5: Deploy cr-auth-echo-envoy (sidecar variant: Envoy jwt_authn)
# ============================================================
echo ""
echo "--- Step 5: Deploy ${AUTH_ECHO_ENVOY_SERVICE} (sidecar variant) ---"
# gcloud run deploy is create-or-update: always run it so topology/sizing
# changes in this script propagate as a new revision on re-run (a
# skip-if-exists here would silently ignore config drift).
#
# Envoy is the ingress container (--port); the app sits on ENVOY_APP_PORT
# (Cloud Run injects PORT only into the ingress container).
#
# PARALLEL topology: no --depends-on, so both containers start at T0 and
# the sidecar's startup cost is max(app, envoy) rather than app + envoy —
# an earlier sequential (--depends-on) run measured Envoy as a flat
# +0.65s AFTER the app was ready. Readiness is still gated on both:
# Envoy's startup probe traverses the proxy to the app via the JWT-exempt
# /healthz route, so the instance only accepts traffic once the full path
# works. APP_START_DELAY (optional env, seconds) makes the app emulate a
# heavy framework for cold-start experiments.
# Envoy is sized down (ENVOY_CPU/ENVOY_MEMORY, default 0.25 vCPU/128Mi):
# per-container defaults are 1 vCPU/512Mi, which silently DOUBLES the
# instance footprint vs the single-container library variant. Envoy with
# one static cluster + jwt_authn idles at a few tens of MB.
# Same IAM posture as the library variant: closed + custom audience.
gcloud run deploy "${AUTH_ECHO_ENVOY_SERVICE}" \
  --region="${REGION}" \
  --ingress=internal \
  --max-instances=5 \
  --min-instances=0 \
  --cpu-throttling \
  --no-allow-unauthenticated \
  --add-custom-audiences="${GOOGLE_CUSTOM_AUDIENCE}" \
  --project="${PROJECT_ID}" \
  --quiet \
  --container=envoy \
  --image="${ENVOY_IMAGE_URL}" \
  --port=8080 \
  --cpu="${ENVOY_CPU:-0.25}" \
  --memory="${ENVOY_MEMORY:-128Mi}" \
  --set-env-vars="^@^JWT_ISSUER=${JWT_ISSUER}@JWT_AUDIENCE=${JWT_AUDIENCE}@JWKS_JSON=${JWKS_JSON}@APP_PORT=${ENVOY_APP_PORT}" \
  --startup-probe=httpGet.path=/healthz,httpGet.port=8080,periodSeconds=1,failureThreshold=60 \
  --container=app \
  --image="${AUTH_ECHO_IMAGE_URL}" \
  --set-env-vars="^@^APP_PORT=${ENVOY_APP_PORT}@JWT_MODE=off@EXPECTED_ISS=${JWT_ISSUER}@EXPECTED_AUD=${JWT_AUDIENCE}@JWKS_JSON=${JWKS_JSON}@APP_START_DELAY=${APP_START_DELAY:-0}"
echo "Service '${AUTH_ECHO_ENVOY_SERVICE}' deployed."
AUTH_ECHO_ENVOY_URL="$(gcloud run services describe "${AUTH_ECHO_ENVOY_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
echo "Service URL: ${AUTH_ECHO_ENVOY_URL}"

# ============================================================
# Step 6: Apigee — shared flow + flow hook + proxies (skip if absent)
# ============================================================
echo ""
echo "--- Step 6: Apigee shared flow, flow hook, proxies ---"
TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

# Create-or-skip an auth proxy with combined-header target auth (design doc
# §2): HeaderName sends the minted Google ID token in
# X-Serverless-Authorization so the client JWT survives untouched in
# Authorization. Audience is the Cloud Run CUSTOM audience — one fixed
# string, no per-service URL plumbing. Both variants get an identical
# proxy shape; only name/path/target differ.
# Usage: deploy_auth_proxy <name> <base-path> <target-url> <description>
deploy_auth_proxy() {
  local name="$1" base_path="$2" target_url="$3" description="$4"

  local deployed_rev
  deployed_rev="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0]['revision'] if d else '')" 2>/dev/null || true)"

  if [[ -n "${deployed_rev}" ]]; then
    local current_target
    current_target="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${name}/revisions/${deployed_rev}?format=bundle" \
      -o "/tmp/auth-proxy-check-${name}.zip" 2>/dev/null && \
      unzip -p "/tmp/auth-proxy-check-${name}.zip" apiproxy/targets/default.xml 2>/dev/null || true)"
    rm -f "/tmp/auth-proxy-check-${name}.zip"
    if echo "${current_target}" | grep -q "${target_url}" && \
       echo "${current_target}" | grep -q "<Audience>${GOOGLE_CUSTOM_AUDIENCE}</Audience>"; then
      echo "Proxy '${name}' already deployed with correct target, skipping."
      return 0
    fi
  fi

  echo "Creating proxy '${name}' (BasePath ${base_path})..."
  local bundle_dir
  bundle_dir="$(mktemp -d)"
  mkdir -p "${bundle_dir}/apiproxy/proxies" "${bundle_dir}/apiproxy/targets"

  cat > "${bundle_dir}/apiproxy/proxies/default.xml" << XMLEOF
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
    <BasePath>${base_path}</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

  cat > "${bundle_dir}/apiproxy/targets/default.xml" << XMLEOF
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
    <URL>${target_url}</URL>
    <Authentication>
      <HeaderName>X-Serverless-Authorization</HeaderName>
      <GoogleIDToken>
        <Audience>${GOOGLE_CUSTOM_AUDIENCE}</Audience>
      </GoogleIDToken>
    </Authentication>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

  cat > "${bundle_dir}/apiproxy/${name}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${name}">
  <Description>${description}</Description>
  <BasePaths>${base_path}</BasePaths>
</APIProxy>
XMLEOF

  local bundle_zip
  bundle_zip="$(mktemp).zip"
  (cd "${bundle_dir}" && zip -r "${bundle_zip}" apiproxy/) >/dev/null

  local import_response
  import_response="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${name}&action=import" \
    --data-binary "@${bundle_zip}")"
  rm -rf "${bundle_dir}" "${bundle_zip}"

  if echo "${import_response}" | grep -q '"error"'; then
    echo "ERROR importing proxy:"
    echo "${import_response}" | python3 -m json.tool 2>/dev/null || echo "${import_response}"
    exit 1
  fi
  local new_rev
  new_rev="$(echo "${import_response}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))")"
  echo "Imported proxy revision ${new_rev}."

  # GoogleIDToken target auth requires a deploy-time SA (mints tokens as it)
  local deploy_response
  deploy_response="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/${new_rev}/deployments?override=true&serviceAccount=${SA_EMAIL}")"
  if echo "${deploy_response}" | grep -q '"error"'; then
    echo "ERROR deploying proxy:"
    echo "${deploy_response}" | python3 -m json.tool 2>/dev/null || echo "${deploy_response}"
    exit 1
  fi
  echo "Proxy revision ${new_rev} deployed to '${APIGEE_ENV}' as ${SA_EMAIL}."
}

if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "Apigee not provisioned (HTTP ${APIGEE_HTTP}), skipping Apigee steps."
else
  # ---- 6a: shared flow with VerifyJWT ----
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

  # ---- 6b: attach via env-level flow hook (fleet-wide, structurally unskippable) ----
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

  # ---- 6c: one proxy per variant, identical combined-header target auth ----
  deploy_auth_proxy "${AUTH_PROXY_NAME}" "/auth-echo" "${AUTH_ECHO_URL}" \
    "Auth PoC library variant: client JWT passthrough + Google ID token via X-Serverless-Authorization"
  deploy_auth_proxy "${AUTH_ENVOY_PROXY_NAME}" "/auth-echo-envoy" "${AUTH_ECHO_ENVOY_URL}" \
    "Auth PoC sidecar variant: Envoy jwt_authn ingress container target"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Auth PoC setup complete ==="
echo ""
echo "Enforcement layers now live:"
echo "  1. Apigee flow hook → '${AUTH_SHAREDFLOW}' shared flow: VerifyJWT (sig/exp/iss/aud)"
echo "  2. Cloud Run IAM: both echo services closed, Google ID token w/ custom audience"
echo "  3. In-service enforcement, one path per variant:"
echo "     /auth-echo       → ${AUTH_ECHO_SERVICE}: in-process middleware (library)"
echo "     /auth-echo-envoy → ${AUTH_ECHO_ENVOY_SERVICE}: Envoy jwt_authn ingress container (middleware off)"
echo ""
echo "NOTE: the flow hook now applies VerifyJWT to ALL proxies in '${APIGEE_ENV}'"
echo "      (e.g. /hello now needs a JWT too). Run ./scripts/auth/teardown.sh to detach."
echo ""
echo "Run ./scripts/auth/test.sh to verify."
