#!/usr/bin/env bash
#
# auth/setup-envoy.sh — Sidecar variant of the auth PoC (§10 item 6, #39)
#
# Deploys cr-auth-echo-envoy: a multi-container Cloud Run service with an
# Envoy jwt_authn ingress container in front of the same echo app (its
# in-process middleware disabled via JWT_MODE=off — Envoy enforces instead),
# plus Apigee proxy 'cr-auth-jwt-envoy' (/auth-echo-envoy) with the same
# combined-header target auth as the library variant.
#
# Prerequisites: auth/setup.sh has run (keypair + idp-mock + Apigee bits).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-auth.sh"

echo "=== Auth PoC sidecar variant setup — project: ${PROJECT_ID} ==="
echo "Service: ${AUTH_ECHO_ENVOY_SERVICE} (Envoy jwt_authn ingress + app on :${ENVOY_APP_PORT})"
echo ""

if [[ ! -f "${AUTH_PRIVATE_KEY}" ]]; then
  echo "ERROR: no keypair at ${AUTH_PRIVATE_KEY} — run ./scripts/auth/setup.sh first."
  exit 1
fi
JWKS_JSON="$(build_jwks_json)"

# ============================================================
# Step 1: Build images
# ============================================================
echo "--- Step 1: Build images ---"
# auth-echo is rebuilt unconditionally: this variant needs the APP_PORT /
# JWT_MODE support added for it. Existing cr-auth-echo keeps running its
# deploy-time-pinned digest, so rebuilding :latest is safe.
echo "Rebuilding auth-echo (APP_PORT/JWT_MODE support)..."
# regional-user-owned-bucket: keep the logs bucket in-project — the
# Google-managed one is outside the VPC-SC perimeter (see setup-base.sh).
gcloud builds submit \
  --region="${BUILD_REGION}" \
  --gcs-source-staging-dir="gs://${CLOUDBUILD_BUCKET}/source" \
  --default-buckets-behavior=regional-user-owned-bucket \
  --tag "${AUTH_ECHO_IMAGE_URL}" \
  "${SCRIPT_DIR}/container" \
  --project="${PROJECT_ID}"

if gcloud artifacts docker images describe "${ENVOY_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${ENVOY_IMAGE_URL}' already exists, skipping build."
else
  echo "Building auth-envoy via Cloud Build..."
  gcloud builds submit \
    --region="${BUILD_REGION}" \
    --gcs-source-staging-dir="gs://${CLOUDBUILD_BUCKET}/source" \
    --default-buckets-behavior=regional-user-owned-bucket \
    --tag "${ENVOY_IMAGE_URL}" \
    "${SCRIPT_DIR}/envoy" \
    --project="${PROJECT_ID}"
fi

# ============================================================
# Step 2: Deploy the multi-container service
# ============================================================
echo ""
echo "--- Step 2: Deploy ${AUTH_ECHO_ENVOY_SERVICE} ---"
# gcloud run deploy is create-or-update: always run it so topology/sizing
# changes in this script propagate as a new revision on re-run (the earlier
# skip-if-exists silently ignored config drift).
if true; then
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
fi
AUTH_ECHO_ENVOY_URL="$(gcloud run services describe "${AUTH_ECHO_ENVOY_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
echo "Service URL: ${AUTH_ECHO_ENVOY_URL}"

# ============================================================
# Step 3: Apigee proxy /auth-echo-envoy (skip if no Apigee)
# ============================================================
echo ""
echo "--- Step 3: Apigee proxy '${AUTH_ENVOY_PROXY_NAME}' ---"
TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "Apigee not provisioned (HTTP ${APIGEE_HTTP}), skipping proxy."
else
  PROXY_DEPLOYED_REV="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_ENVOY_PROXY_NAME}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0]['revision'] if d else '')" 2>/dev/null || true)"

  NEEDS_PROXY=true
  if [[ -n "${PROXY_DEPLOYED_REV}" ]]; then
    CURRENT_TARGET="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${AUTH_ENVOY_PROXY_NAME}/revisions/${PROXY_DEPLOYED_REV}?format=bundle" \
      -o /tmp/auth-envoy-proxy-check.zip 2>/dev/null && \
      unzip -p /tmp/auth-envoy-proxy-check.zip apiproxy/targets/default.xml 2>/dev/null || true)"
    rm -f /tmp/auth-envoy-proxy-check.zip
    if echo "${CURRENT_TARGET}" | grep -q "${AUTH_ECHO_ENVOY_URL}"; then
      echo "Proxy '${AUTH_ENVOY_PROXY_NAME}' already deployed with correct target, skipping."
      NEEDS_PROXY=false
    fi
  fi

  if [[ "${NEEDS_PROXY}" == "true" ]]; then
    echo "Creating proxy '${AUTH_ENVOY_PROXY_NAME}' (BasePath /auth-echo-envoy)..."
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
    <BasePath>/auth-echo-envoy</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

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
    <URL>${AUTH_ECHO_ENVOY_URL}</URL>
    <Authentication>
      <HeaderName>X-Serverless-Authorization</HeaderName>
      <GoogleIDToken>
        <Audience>${GOOGLE_CUSTOM_AUDIENCE}</Audience>
      </GoogleIDToken>
    </Authentication>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

    cat > "${BUNDLE_DIR}/apiproxy/${AUTH_ENVOY_PROXY_NAME}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${AUTH_ENVOY_PROXY_NAME}">
  <Description>Auth PoC sidecar variant: Envoy jwt_authn ingress container target</Description>
  <BasePaths>/auth-echo-envoy</BasePaths>
</APIProxy>
XMLEOF

    BUNDLE_ZIP="$(mktemp).zip"
    (cd "${BUNDLE_DIR}" && zip -r "${BUNDLE_ZIP}" apiproxy/) >/dev/null

    IMPORT_RESPONSE="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${AUTH_ENVOY_PROXY_NAME}&action=import" \
      --data-binary "@${BUNDLE_ZIP}")"
    rm -rf "${BUNDLE_DIR}" "${BUNDLE_ZIP}"

    if echo "${IMPORT_RESPONSE}" | grep -q '"error"'; then
      echo "ERROR importing proxy:"
      echo "${IMPORT_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${IMPORT_RESPONSE}"
      exit 1
    fi
    NEW_REV="$(echo "${IMPORT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))")"
    echo "Imported proxy revision ${NEW_REV}."

    DEPLOY_RESPONSE="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_ENVOY_PROXY_NAME}/revisions/${NEW_REV}/deployments?override=true&serviceAccount=${SA_EMAIL}")"
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
echo "=== Sidecar variant setup complete ==="
echo ""
echo "  /auth-echo-envoy → Envoy jwt_authn (ingress container) → app (middleware OFF)"
echo "  /auth-echo       → app middleware (library variant), for comparison"
echo ""
echo "Run ./scripts/auth/test-envoy.sh to verify and compare."
