#!/usr/bin/env bash
#
# test.sh — Verify PSC Service Attachment connectivity to Cloud Run
#
# Test 1: Service Attachment connected endpoints status
# Test 2: PSC endpoint connection status
# Test 3: DNS resolution from VM
# Test 4: HTTP connectivity through PSC
# Test 5: Verbose curl showing connection details
#
# Prerequisites: setup-infra.sh and setup-psc.sh completed.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-apigee}"

REGION="europe-north2"
ZONE="${REGION}-a"

# Apigee (optional — detected automatically)
APIGEE_API="${APIGEE_API:-https://eu-apigee.googleapis.com/v1}"
INSTANCE_NAME="instance-${REGION}"
ENDPOINT_ATTACHMENT_ID="ea-cr-hello"

echo "=== Testing PSC Service Attachment Connectivity ==="
echo "Project: ${PROJECT_ID}"
echo ""

# Helper — run a command on vm-test via IAP SSH (filters NumPy warning, keeps real errors)
ssh_cmd() {
  gcloud compute ssh "vm-test" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --project="${PROJECT_ID}" \
    --command="$1" 2> >(grep -v 'NumPy' >&2)
}

# ============================================================
# Test 1: Service Attachment connected endpoints status
# ============================================================
echo "=========================================="
echo "  Test 1: Service Attachment Status"
echo "=========================================="
echo ""
echo "Verifying Service Attachment has ACCEPTED connected endpoints..."
echo ""

echo "--- Connected endpoints ---"
gcloud compute service-attachments describe "sa-workloads" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="yaml(connectedEndpoints)" || echo "  FAILED"

echo ""

# ============================================================
# Test 2: PSC endpoint connection status
# ============================================================
echo "=========================================="
echo "  Test 2: PSC Endpoint Connection Status"
echo "=========================================="
echo ""
echo "Verifying PSC endpoint pscConnectionStatus = ACCEPTED..."
echo ""

PSC_STATUS="$(gcloud compute forwarding-rules describe "psc-endpoint-apigee" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="value(pscConnectionStatus)" 2>/dev/null || echo "UNKNOWN")"
echo "PSC connection status: ${PSC_STATUS}"

if [[ "${PSC_STATUS}" == "ACCEPTED" ]]; then
  echo "PASS: PSC endpoint is ACCEPTED."
else
  echo "FAIL: Expected ACCEPTED, got ${PSC_STATUS}."
fi

echo ""

# ============================================================
# Test 3: DNS resolution from VM
# ============================================================
echo "=========================================="
echo "  Test 3: DNS Resolution"
echo "=========================================="
echo ""
echo "Verifying api.internal.example.com resolves to 10.0.0.50 (PSC endpoint)..."
echo ""

echo "--- getent hosts api.internal.example.com ---"
ssh_cmd "getent hosts api.internal.example.com" || echo "  FAILED"

echo ""
echo "--- dig +short api.internal.example.com ---"
ssh_cmd "dig +short api.internal.example.com" || echo "  FAILED (dig not available — VM startup script may still be running)"

echo ""

# ============================================================
# Test 4: HTTP connectivity through PSC
# ============================================================
echo "=========================================="
echo "  Test 4: HTTP Connectivity via PSC"
echo "=========================================="
echo ""
echo "VM -> PSC endpoint (10.0.0.50) -> Service Attachment -> ILB -> Cloud Run"
echo ""

echo "--- curl https://api.internal.example.com/ ---"
ssh_cmd "curl -sk --max-time 10 https://api.internal.example.com/" || echo "  FAILED"

echo ""

# ============================================================
# Test 5: Verbose curl showing connection details
# ============================================================
echo "=========================================="
echo "  Test 5: Connection Details"
echo "=========================================="
echo ""
echo "Confirming curl connects to PSC endpoint IP..."
echo ""

echo "--- curl -v (connection details) ---"
ssh_cmd "curl -skv --max-time 10 https://api.internal.example.com/ 2>&1 | grep -E '(Trying|Connected|< HTTP)'" || echo "  FAILED"

echo ""

# ============================================================
# Test 6: End-to-end through Apigee (if provisioned)
# ============================================================
echo "=========================================="
echo "  Test 6: Apigee End-to-End (if provisioned)"
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

  EA_HOST="$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/endpointAttachments/${ENDPOINT_ATTACHMENT_ID}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"

  if [[ -z "${INSTANCE_IP}" ]]; then
    echo "Apigee instance not ACTIVE, skipping."
    echo ""
  elif [[ -z "${EA_HOST}" ]]; then
    echo "Endpoint attachment '${ENDPOINT_ATTACHMENT_ID}' not ready, skipping."
    echo "Run setup-psc.sh first to create the endpoint attachment."
    echo ""
  else
    echo "Apigee instance IP:         ${INSTANCE_IP}"
    echo "Endpoint attachment host:    ${EA_HOST}"
    echo ""
    echo "VM → Apigee (${INSTANCE_IP})"
    echo "  → Endpoint Attachment (${EA_HOST}) → Service Attachment"
    echo "  → ILB → Cloud Run"
    echo ""

    echo "--- curl https://${INSTANCE_IP}/hello (via Apigee → southbound PSC) ---"
    ssh_cmd "curl -sk --max-time 15 -H 'Host: api.internal.example.com' https://${INSTANCE_IP}/hello" || echo "  FAILED"

    echo ""

    echo "--- Connection details ---"
    ssh_cmd "curl -skv --max-time 15 -H 'Host: api.internal.example.com' https://${INSTANCE_IP}/hello 2>&1 | grep -E '(Trying|Connected|< HTTP)'" || echo "  FAILED"

    echo ""
  fi
fi

# ============================================================
# Summary
# ============================================================
echo "=== Test complete ==="
echo ""
echo "Direct PSC path (Tests 1-5):"
echo "  Test 2 ACCEPTED  → PSC connection established"
echo "  Test 3 10.0.0.50 → DNS resolving to PSC endpoint"
echo "  Test 4 'OK'      → VM → PSC → ILB → Cloud Run works"
echo ""
echo "Apigee path (Test 6, if provisioned):"
echo "  'OK' → VM → Apigee → Endpoint Attachment → Service Attachment → ILB → Cloud Run"
