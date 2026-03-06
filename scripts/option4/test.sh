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

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"

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
# Summary
# ============================================================
echo "=== Test complete ==="
echo ""
echo "If Test 2 shows ACCEPTED, the PSC connection is established."
echo "If Test 3 shows 10.0.0.50, DNS is correctly resolving to the PSC endpoint."
echo "If Test 4 returns 'OK', the full path (VM -> PSC -> ILB -> Cloud Run) works."
