#!/usr/bin/env bash
#
# test.sh — Verify PSC endpoint connectivity to Cloud Run
#
# Test 1: DNS resolution — *.run.app resolves to the PSC endpoint IP (not public)
# Test 2: HTTP connectivity — curl Cloud Run service through the PSC endpoint
#
# Prerequisites: setup-infra.sh and setup-psc.sh completed.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
PSC_IP="10.100.0.1"

echo "=== Testing PSC Connectivity ==="
echo "Project: ${PROJECT_ID}"
echo "Expected PSC IP: ${PSC_IP}"
echo ""

# Get Cloud Run service URL
SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"

if [[ -z "${SERVICE_URL}" ]]; then
  echo "ERROR: Could not get Cloud Run service URL. Is setup-infra.sh complete?"
  exit 1
fi

# Extract hostname from URL (e.g., cr-hello-abc123-lz.a.run.app)
SERVICE_HOST="${SERVICE_URL#https://}"
echo "Cloud Run URL: ${SERVICE_URL}"
echo "Cloud Run host: ${SERVICE_HOST}"
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
# Test 1: DNS resolution from VM
# ============================================================
echo "=========================================="
echo "  Test 1: DNS Resolution"
echo "=========================================="
echo ""
echo "Verifying *.run.app resolves to ${PSC_IP} (PSC endpoint) instead of public IP..."
echo ""

echo "--- getent hosts ${SERVICE_HOST} ---"
ssh_cmd "getent hosts ${SERVICE_HOST}" || echo "  FAILED"

echo ""
echo "--- dig +short ${SERVICE_HOST} ---"
ssh_cmd "dig +short ${SERVICE_HOST}" || echo "  FAILED (dig not available — VM startup script may still be running)"

echo ""

# ============================================================
# Test 2: HTTP connectivity through PSC
# ============================================================
echo "=========================================="
echo "  Test 2: HTTP Connectivity via PSC"
echo "=========================================="
echo ""
echo "VM → PSC endpoint (${PSC_IP}) → Google backbone → Cloud Run"
echo ""

echo "--- curl ${SERVICE_URL} ---"
ssh_cmd "curl -s --max-time 10 ${SERVICE_URL}/" || echo "  FAILED: curl ${SERVICE_URL}"

echo ""

# ============================================================
# Test 3: Verify resolved IP matches PSC endpoint
# ============================================================
echo "=========================================="
echo "  Test 3: Verify PSC routing"
echo "=========================================="
echo ""
echo "Confirming curl resolves to PSC endpoint IP..."
echo ""

echo "--- curl -v (connection details) ---"
ssh_cmd "curl -sv --max-time 10 ${SERVICE_URL}/ 2>&1 | grep -E '(Trying|Connected|< HTTP)'" || echo "  FAILED"

echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Test complete ==="
echo ""
echo "If Test 1 shows ${PSC_IP}, DNS is correctly routing through PSC."
echo "If Test 2 returns 'OK', the full path (VM → PSC → Cloud Run) works."
echo ""
echo "For comparison, public DNS resolves to a different IP:"
echo "  dig +short ${SERVICE_HOST} @8.8.8.8"
