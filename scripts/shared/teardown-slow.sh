#!/usr/bin/env bash
#
# teardown-slow.sh — Delete Apigee X org and peering infrastructure
#
# Run option-specific teardown scripts FIRST, then this script,
# then teardown-base.sh.
#
# Usage:
#   ./scripts/shared/teardown-slow.sh
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

echo "=== Apigee X Teardown for project: ${PROJECT_ID} ==="
echo ""
echo "WARNING: This will permanently delete the Apigee organisation"
echo "and all associated resources. Run option teardown scripts first."
echo ""
read -r -p "Continue? (y/N) " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# ============================================================
# Step 1: Undeploy API proxy
# ============================================================
echo ""
echo "--- Step 1: Undeploy API proxy ---"
apigee_api DELETE \
  "organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/1/deployments" \
  >/dev/null
echo "Done."

# ============================================================
# Step 2: Delete API proxy
# ============================================================
echo ""
echo "--- Step 2: Delete API proxy ---"
apigee_api DELETE "organizations/${PROJECT_ID}/apis/${PROXY_NAME}" >/dev/null
echo "Done."

# ============================================================
# Step 3: Detach environment from group
# ============================================================
echo ""
echo "--- Step 3: Detach environment from group ---"
TOKEN="$(gcloud auth print-access-token)"
ATTACHMENTS_JSON="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/envgroups/${APIGEE_ENV_GROUP}/attachments" 2>/dev/null || echo '{}')"

ATTACHMENT_NAME="$(echo "${ATTACHMENTS_JSON}" | python3 -c "
import sys,json
data = json.load(sys.stdin)
for a in data.get('environmentGroupAttachments', []):
    if a.get('environment') == '${APIGEE_ENV}':
        print(a['name'])
        break
" 2>/dev/null || true)"

if [[ -n "${ATTACHMENT_NAME}" ]]; then
  apigee_api DELETE "${ATTACHMENT_NAME}" >/dev/null
fi
echo "Done."

# ============================================================
# Step 4: Delete environment group
# ============================================================
echo ""
echo "--- Step 4: Delete environment group ---"
apigee_api DELETE "organizations/${PROJECT_ID}/envgroups/${APIGEE_ENV_GROUP}" >/dev/null
echo "Done."

# ============================================================
# Step 5: Detach environment from instance
# ============================================================
echo ""
echo "--- Step 5: Detach environment from instance ---"
TOKEN="$(gcloud auth print-access-token)"
INST_ATTACHMENTS_JSON="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}/attachments" 2>/dev/null || echo '{}')"

INST_ATTACHMENT_NAME="$(echo "${INST_ATTACHMENTS_JSON}" | python3 -c "
import sys,json
data = json.load(sys.stdin)
for a in data.get('attachments', []):
    if a.get('environment') == '${APIGEE_ENV}':
        print(a['name'])
        break
" 2>/dev/null || true)"

if [[ -n "${INST_ATTACHMENT_NAME}" ]]; then
  echo "Detaching environment from instance (may take a few minutes)..."
  apigee_api DELETE "${INST_ATTACHMENT_NAME}" >/dev/null

  TIMEOUT=300
  INTERVAL=15
  ELAPSED=0
  while (( ELAPSED < TIMEOUT )); do
    TOKEN="$(gcloud auth print-access-token)"
    CHECK="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}/attachments" 2>/dev/null || echo '{}')"
    if ! echo "${CHECK}" | grep -q "\"${APIGEE_ENV}\""; then
      break
    fi
    sleep "${INTERVAL}"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
fi
echo "Done."

# ============================================================
# Step 6: Delete environment
# ============================================================
echo ""
echo "--- Step 6: Delete environment ---"
apigee_api DELETE "organizations/${PROJECT_ID}/environments/${APIGEE_ENV}" >/dev/null
echo "Done."

# ============================================================
# Step 7: Delete Apigee instance
# ============================================================
echo ""
echo "--- Step 7: Delete Apigee instance ---"
echo "Deleting instance '${INSTANCE_NAME}' (this may take 20-30 minutes)..."
apigee_api DELETE "organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" >/dev/null

TIMEOUT=2400
INTERVAL=30
ELAPSED=0
while (( ELAPSED < TIMEOUT )); do
  TOKEN="$(gcloud auth print-access-token)"
  INST_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}")"
  if [[ "${INST_HTTP}" == "404" ]]; then
    break
  fi
  echo "  Instance still deleting (${ELAPSED}s elapsed)..."
  sleep "${INTERVAL}"
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo "Done."

# ============================================================
# Step 8: Delete Apigee organisation
# ============================================================
echo ""
echo "--- Step 8: Delete Apigee organisation ---"
echo "Deleting org '${PROJECT_ID}' with minimum retention..."
TOKEN="$(gcloud auth print-access-token)"
curl -s -X DELETE \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}?retention=MINIMUM" \
  >/dev/null 2>&1 || true
echo "Done. (Soft-deleted; permanent deletion in ~24 hours. Billing stops at soft-delete.)"

# ============================================================
# Step 9: Remove VPC peering
# ============================================================
echo ""
echo "--- Step 9: Remove VPC peering ---"
PEERING_NAME="$(gcloud compute networks peerings list \
  --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
  --format='value(name)' --filter='network~servicenetworking' 2>/dev/null || true)"

if [[ -n "${PEERING_NAME}" ]]; then
  gcloud services vpc-peerings delete \
    --service=servicenetworking.googleapis.com \
    --network="${APIGEE_NETWORK}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || true
fi
echo "Done."

# ============================================================
# Step 10: Release peering IP ranges
# ============================================================
echo ""
echo "--- Step 10: Release peering IP ranges ---"
gcloud compute addresses delete "${APIGEE_PEERING_RANGE_NAME}" \
  --global \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null || true
gcloud compute addresses delete "${APIGEE_INSTANCE_RANGE_NAME}" \
  --global \
  --project="${PROJECT_ID}" \
  --quiet 2>/dev/null || true
echo "Done."

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Apigee teardown complete ==="
echo ""
echo "The Apigee org has been soft-deleted (billing stops now)."
echo "Permanent deletion occurs in ~24 hours."
echo ""
echo "Next: run ./scripts/shared/teardown-base.sh to remove"
echo "VPC, VM, Cloud Run, etc."
