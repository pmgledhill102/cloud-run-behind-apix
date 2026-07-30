#!/usr/bin/env bash
#
# auth/teardown-envoy.sh — Reverse of setup-envoy.sh
#
# Deletes: Apigee proxy cr-auth-jwt-envoy, Cloud Run service
# cr-auth-echo-envoy, and the auth-envoy image. Leaves everything owned by
# auth/setup.sh (keypair, idp-mock, auth-echo, shared flow, flow hook) —
# run auth/teardown.sh for those.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-auth.sh"

echo "=== Teardown auth PoC sidecar variant — project: ${PROJECT_ID} ==="
echo ""

# ============================================================
# Step 1: Apigee proxy
# ============================================================
echo "--- Step 1: Remove Apigee proxy '${AUTH_ENVOY_PROXY_NAME}' ---"
PROXY_REV="$(apigee_api GET "organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_ENVOY_PROXY_NAME}/deployments" \
  | python3 -c "
import sys,json
try:
    d = json.load(sys.stdin).get('deployments', [])
    print(d[0].get('revision','') if d else '')
except Exception:
    print('')
" 2>/dev/null || true)"
if [[ -n "${PROXY_REV}" ]]; then
  apigee_api DELETE "organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_ENVOY_PROXY_NAME}/revisions/${PROXY_REV}/deployments"
  echo "Proxy undeployed (rev ${PROXY_REV})."
fi
apigee_api DELETE "organizations/${PROJECT_ID}/apis/${AUTH_ENVOY_PROXY_NAME}"
echo "Proxy deleted (or did not exist)."

# ============================================================
# Step 2: Cloud Run service
# ============================================================
echo ""
echo "--- Step 2: Delete ${AUTH_ECHO_ENVOY_SERVICE} ---"
if resource_exists gcloud run services describe "${AUTH_ECHO_ENVOY_SERVICE}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud run services delete "${AUTH_ECHO_ENVOY_SERVICE}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Service deleted."
else
  echo "Service does not exist, skipping."
fi

# ============================================================
# Step 3: Envoy image
# ============================================================
echo ""
echo "--- Step 3: Delete auth-envoy image ---"
if gcloud artifacts docker images describe "${ENVOY_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud artifacts docker images delete "${ENVOY_IMAGE_URL}" \
    --project="${PROJECT_ID}" --quiet --delete-tags
  echo "Image deleted."
else
  echo "Image does not exist, skipping."
fi

echo ""
echo "=== Sidecar variant teardown complete ==="
