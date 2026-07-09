#!/usr/bin/env bash
#
# option2b/test.sh — Verify VPC-SC perimeter enforcement on the PGA path
#
# Test 1: Perimeter status — resources + restricted services
# Test 2: POSITIVE — VM (inside perimeter) → restricted VIP → cr-hello: 200
# Test 3: NEGATIVE — VM → out-of-perimeter GCS bucket: VPC-SC 403
# Test 4: Apigee end-to-end through the perimeter (if provisioned)
#
# Test 3 is the proof: option2 alone routes via the restricted VIP but blocks
# nothing. With the perimeter enforced, a restricted service (storage) in a
# project OUTSIDE the perimeter must be denied from inside it.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

PERIMETER_NAME="apigee-poc-perimeter"
POLICY_TITLE="apigee-poc-policy"
# Any public bucket in a project outside the perimeter works here:
EXTERNAL_BUCKET="gcp-public-data-landsat"

echo "=== Testing VPC-SC Perimeter Enforcement ==="
echo "Project: ${PROJECT_ID}"
echo ""

# Get Cloud Run service URL
SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"

if [[ -z "${SERVICE_URL}" ]]; then
  echo "ERROR: Could not get Cloud Run service URL. Is setup-base.sh complete?"
  exit 1
fi
echo "Cloud Run URL: ${SERVICE_URL}"
echo ""

# ============================================================
# Test 1: Perimeter status
# ============================================================
echo "=========================================="
echo "  Test 1: Perimeter Status"
echo "=========================================="
echo ""

ORG_ID="$(gcloud projects get-ancestors "${PROJECT_ID}" \
  --format='csv[no-heading](id,type)' | awk -F, '$2=="organization"{print $1}')"
POLICY_ID="${ACCESS_POLICY_ID:-}"
if [[ -z "${POLICY_ID}" ]]; then
  POLICY_ID="$(gcloud access-context-manager policies list \
    --organization="${ORG_ID}" \
    --billing-project="${PROJECT_ID}" \
    --format='value(name)' \
    --filter="title=${POLICY_TITLE}" 2>/dev/null | head -1 || true)"
  POLICY_ID="${POLICY_ID##*/}"
fi

if [[ -z "${POLICY_ID}" ]]; then
  echo "ERROR: access policy '${POLICY_TITLE}' not found. Run option2b/setup.sh first."
  exit 1
fi

gcloud access-context-manager perimeters describe "${PERIMETER_NAME}" \
  --policy="${POLICY_ID}" \
  --billing-project="${PROJECT_ID}" \
  --format='yaml(status.resources,status.restrictedServices)' \
  || { echo "ERROR: perimeter '${PERIMETER_NAME}' not found."; exit 1; }
echo ""

# ============================================================
# Test 2: POSITIVE — inside-perimeter path still works
# ============================================================
echo "=========================================="
echo "  Test 2: POSITIVE — VM → cr-hello (inside perimeter)"
echo "=========================================="
echo ""
echo "VM (inside) → restricted VIP → Cloud Run (inside) — expect HTTP 200"
echo ""

echo "--- curl ${SERVICE_URL} (with ID token) ---"
ssh_curl_auth "${SERVICE_URL}" "-s --max-time 10 ${SERVICE_URL}/" || echo "  FAILED"
echo ""

# ============================================================
# Test 3: NEGATIVE — out-of-perimeter access is blocked
# ============================================================
echo "=========================================="
echo "  Test 3: NEGATIVE — VM → external bucket (outside perimeter)"
echo "=========================================="
echo ""
echo "VM (inside) → storage.googleapis.com → public bucket '${EXTERNAL_BUCKET}'"
echo "(project outside the perimeter) — expect VPC-SC 403"
echo ""

NEGATIVE_URL="https://storage.googleapis.com/storage/v1/b/${EXTERNAL_BUCKET}"
BLOCKED=false
for attempt in 1 2 3; do
  echo "--- attempt ${attempt}: curl ${NEGATIVE_URL} ---"
  RESPONSE="$(ssh_cmd "curl -s --max-time 15 -o /dev/null -w '%{http_code}' '${NEGATIVE_URL}' && echo '' && curl -s --max-time 15 '${NEGATIVE_URL}' | head -c 400" || true)"
  echo "${RESPONSE}"
  echo ""
  if echo "${RESPONSE}" | head -1 | grep -q "403"; then
    BLOCKED=true
    break
  fi
  if [[ "${attempt}" -lt 3 ]]; then
    echo "  Not blocked yet — perimeter may still be propagating. Retrying in 60s..."
    sleep 60
  fi
done

if [[ "${BLOCKED}" == "true" ]]; then
  echo "PASS: request blocked (403). VPC-SC perimeter is enforcing."
else
  echo "FAIL: request was NOT blocked."
  echo "  - Perimeter propagation can take up to ~30 minutes; re-run this test."
  echo "  - Check the perimeter restricts storage.googleapis.com (Test 1 output)."
fi
echo ""

# ============================================================
# Test 4: Apigee end-to-end through the perimeter (if provisioned)
# ============================================================
echo "=========================================="
echo "  Test 4: Apigee End-to-End (if provisioned)"
echo "=========================================="
echo ""

TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "Apigee not provisioned, skipping."
  echo ""
else
  INSTANCE_IP="$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"

  if [[ -z "${INSTANCE_IP}" ]]; then
    echo "Apigee instance not ACTIVE, skipping."
    echo ""
  else
    echo "VM → Apigee (${INSTANCE_IP}) → restricted VIP → Cloud Run"
    echo "(Apigee southbound is inside the perimeter via the VPC-SC-enabled peering)"
    echo ""

    echo "--- curl https://${INSTANCE_IP}/hello (via Apigee → PGA) ---"
    ssh_cmd "curl -sk --max-time 15 -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}/hello" || echo "  FAILED"
    echo ""
  fi
fi

# ============================================================
# Summary
# ============================================================
echo "=== Test complete ==="
echo ""
echo "Test 2 'OK'          → inside-perimeter path unaffected by enforcement"
echo "Test 3 403           → perimeter blocks cross-perimeter access (the proof)"
echo "Test 4 'OK'          → Apigee southbound admitted through the perimeter"
echo ""
echo "Together: same DNS + restricted VIP as option2, but now with real"
echo "VPC-SC enforcement — access is bounded by the perimeter, not just IAM."
