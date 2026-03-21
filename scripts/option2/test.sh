#!/usr/bin/env bash
#
# option2/test.sh — Verify PGA connectivity to Cloud Run
#
# Test 1: DNS resolution — *.run.app resolves to restricted VIP (not public)
# Test 2: HTTP connectivity — curl Cloud Run service through PGA
# Test 3: Verify routing — curl -v showing connection to 199.36.153.x
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

echo "=== Testing PGA Connectivity ==="
echo "Project: ${PROJECT_ID}"
echo "Expected VIP range: 199.36.153.4-7"
echo ""

# Get Cloud Run service URL
SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"

if [[ -z "${SERVICE_URL}" ]]; then
  echo "ERROR: Could not get Cloud Run service URL. Is setup-base.sh complete?"
  exit 1
fi

SERVICE_HOST="${SERVICE_URL#https://}"
echo "Cloud Run URL: ${SERVICE_URL}"
echo "Cloud Run host: ${SERVICE_HOST}"
echo ""

# ============================================================
# Test 1: DNS resolution from VM
# ============================================================
echo "=========================================="
echo "  Test 1: DNS Resolution"
echo "=========================================="
echo ""
echo "Verifying *.run.app resolves to 199.36.153.x (restricted VIP)..."
echo ""

echo "--- getent hosts ${SERVICE_HOST} ---"
ssh_cmd "getent hosts ${SERVICE_HOST}" || echo "  FAILED"

echo ""
echo "--- dig +short ${SERVICE_HOST} ---"
ssh_cmd "dig +short ${SERVICE_HOST}" || echo "  FAILED (dig not available — VM startup script may still be running)"

echo ""

# ============================================================
# Test 2: HTTP connectivity through PGA
# ============================================================
echo "=========================================="
echo "  Test 2: HTTP Connectivity via PGA"
echo "=========================================="
echo ""
echo "VM → restricted VIP (199.36.153.x) → Google API frontend → Cloud Run"
echo ""

echo "--- curl ${SERVICE_URL} (with ID token) ---"
ssh_curl_auth "${SERVICE_URL}" "-s --max-time 10 ${SERVICE_URL}/" || echo "  FAILED: curl ${SERVICE_URL}"

echo ""

# ============================================================
# Test 3: Verify resolved IP matches restricted VIP
# ============================================================
echo "=========================================="
echo "  Test 3: Verify PGA routing"
echo "=========================================="
echo ""

echo "--- curl -v (connection details, with ID token) ---"
ssh_curl_auth "${SERVICE_URL}" "-sv --max-time 10 ${SERVICE_URL}/ 2>&1 | grep -E '(Trying|Connected|< HTTP)'" || echo "  FAILED"

echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Test complete ==="
echo ""
echo "If Test 1 shows 199.36.153.x, DNS is correctly routing through restricted VIP (PGA)."
echo "If Test 2 returns 'OK', the full path (VM → PGA → Cloud Run) works."
echo ""
echo "For comparison, public DNS resolves to a different IP:"
echo "  dig +short ${SERVICE_HOST} @8.8.8.8"
