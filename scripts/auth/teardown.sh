#!/usr/bin/env bash
#
# auth/teardown.sh — Remove all Auth PoC resources (reverse of setup.sh)
#
# Order matters: detach the flow hook FIRST — it re-opens /hello etc. for the
# other option tests — then undeploy/delete proxy + shared flow, then the
# Cloud Run services, images, and local key state.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-auth.sh"

echo "=== Auth PoC teardown — project: ${PROJECT_ID} ==="
echo ""

TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

if [[ "${APIGEE_HTTP}" == "200" ]]; then
  # ============================================================
  # Step 1: Detach flow hook (re-opens other proxies immediately)
  # ============================================================
  echo "--- Step 1: Detach flow hook '${AUTH_FLOWHOOK}' ---"
  apigee_api DELETE \
    "organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/flowhooks/${AUTH_FLOWHOOK}" \
    >/dev/null
  echo "Done."

  # ============================================================
  # Step 2: Undeploy + delete proxy
  # ============================================================
  echo ""
  echo "--- Step 2: Undeploy + delete proxy '${AUTH_PROXY_NAME}' ---"
  PROXY_REVS="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_PROXY_NAME}/deployments" \
    | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('deployments', []):
    print(d['revision'])" 2>/dev/null || true)"
  for REV in ${PROXY_REVS}; do
    apigee_api DELETE \
      "organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${AUTH_PROXY_NAME}/revisions/${REV}/deployments" \
      >/dev/null
    echo "Undeployed revision ${REV}."
  done
  apigee_api DELETE "organizations/${PROJECT_ID}/apis/${AUTH_PROXY_NAME}" >/dev/null
  echo "Done."

  # ============================================================
  # Step 3: Undeploy + delete shared flow
  # ============================================================
  echo ""
  echo "--- Step 3: Undeploy + delete shared flow '${AUTH_SHAREDFLOW}' ---"
  SF_REVS="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/sharedflows/${AUTH_SHAREDFLOW}/deployments" \
    | python3 -c "
import sys,json
for d in json.load(sys.stdin).get('deployments', []):
    print(d['revision'])" 2>/dev/null || true)"
  for REV in ${SF_REVS}; do
    apigee_api DELETE \
      "organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/sharedflows/${AUTH_SHAREDFLOW}/revisions/${REV}/deployments" \
      >/dev/null
    echo "Undeployed shared flow revision ${REV}."
  done
  apigee_api DELETE "organizations/${PROJECT_ID}/sharedflows/${AUTH_SHAREDFLOW}" >/dev/null
  echo "Done."
else
  echo "Apigee not provisioned (HTTP ${APIGEE_HTTP}), skipping Apigee teardown."
fi

# ============================================================
# Step 4: Delete Cloud Run services
# ============================================================
echo ""
echo "--- Step 4: Delete Cloud Run services ---"
for SVC in "${AUTH_ECHO_SERVICE}" "${IDP_MOCK_SERVICE}"; do
  if resource_exists gcloud run services describe "${SVC}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud run services delete "${SVC}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Service '${SVC}' deleted."
  else
    echo "Service '${SVC}' not found, skipping."
  fi
done

# ============================================================
# Step 5: Delete container images
# ============================================================
echo ""
echo "--- Step 5: Delete container images ---"
for IMG in "${AUTH_ECHO_IMAGE_URL}" "${IDP_MOCK_IMAGE_URL}"; do
  if gcloud artifacts docker images describe "${IMG}" --project="${PROJECT_ID}" &>/dev/null; then
    gcloud artifacts docker images delete "${IMG}" \
      --project="${PROJECT_ID}" --quiet --delete-tags
    echo "Image '${IMG}' deleted."
  else
    echo "Image '${IMG}' not found, skipping."
  fi
done

# ============================================================
# Step 6: Remove local key state
# ============================================================
echo ""
echo "--- Step 6: Remove local key state ---"
if [[ -d "${AUTH_STATE_DIR}" ]]; then
  rm -rf "${AUTH_STATE_DIR}"
  echo "Removed ${AUTH_STATE_DIR}."
else
  echo "No local state, skipping."
fi

echo ""
echo "=== Auth PoC teardown complete ==="
