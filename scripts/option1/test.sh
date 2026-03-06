#!/usr/bin/env bash
#
# test.sh — Verify VPN + ILB connectivity to Cloud Run
#
# Test 1: BGP routes — verify 10.100.0.0/24 learned by router-apigee
# Test 2: VPN tunnel status — all tunnels ESTABLISHED
# Test 3: DNS resolution — api.internal.example.com resolves to 10.100.0.10
# Test 4: HTTP connectivity — curl through VPN to ILB to Cloud Run
# Test 5: Verbose connection details
#
# Prerequisites: setup-infra.sh, setup-vpn.sh, and setup-ilb.sh completed.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"

echo "=== Testing VPN + ILB Connectivity ==="
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
# Test 1: BGP routes
# ============================================================
echo "=========================================="
echo "  Test 1: BGP Routes"
echo "=========================================="
echo ""
echo "Verifying 10.100.0.0/24 is learned by router-apigee via BGP..."
echo ""

echo "--- Learned routes on router-apigee ---"
gcloud compute routers get-status "router-apigee" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="table(result.bestRoutes[].destRange, result.bestRoutes[].nextHopIp)" 2>/dev/null || echo "FAILED"

echo ""

# ============================================================
# Test 2: VPN tunnel status
# ============================================================
echo "=========================================="
echo "  Test 2: VPN Tunnel Status"
echo "=========================================="
echo ""

for tunnel in vpn-tunnel-apigee-if0 vpn-tunnel-apigee-if1; do
  status=$(gcloud compute vpn-tunnels describe "${tunnel}" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format='value(status)' 2>/dev/null || echo 'UNKNOWN')
  echo "  ${tunnel}: ${status}"
done

echo ""

# ============================================================
# Test 3: DNS resolution from VM
# ============================================================
echo "=========================================="
echo "  Test 3: DNS Resolution"
echo "=========================================="
echo ""
echo "Verifying api.internal.example.com resolves to 10.100.0.10..."
echo ""

echo "--- getent hosts api.internal.example.com ---"
ssh_cmd "getent hosts api.internal.example.com" || echo "  FAILED"

echo ""
echo "--- dig +short api.internal.example.com ---"
ssh_cmd "dig +short api.internal.example.com" || echo "  FAILED (dig not available — VM startup script may still be running)"

echo ""

# ============================================================
# Test 4: HTTP connectivity through VPN to ILB to Cloud Run
# ============================================================
echo "=========================================="
echo "  Test 4: HTTP Connectivity via VPN + ILB"
echo "=========================================="
echo ""
echo "VM → VPN tunnel → ILB (10.100.0.10:443) → Serverless NEG → Cloud Run"
echo ""

echo "--- curl -sk https://api.internal.example.com/ ---"
ssh_cmd "curl -sk --max-time 15 https://api.internal.example.com/" || echo "  FAILED: curl https://api.internal.example.com/"

echo ""

# ============================================================
# Test 5: Verbose curl showing connection details
# ============================================================
echo "=========================================="
echo "  Test 5: Connection Details"
echo "=========================================="
echo ""
echo "Confirming connection routes through ILB IP..."
echo ""

echo "--- curl -skv (connection details) ---"
ssh_cmd "curl -skv --max-time 15 https://api.internal.example.com/ 2>&1 | grep -E '(Trying|Connected|< HTTP)'" || echo "  FAILED"

echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Test complete ==="
echo ""
echo "If Test 1 shows 10.100.0.0/24, BGP routes are propagating correctly."
echo "If Test 2 shows ESTABLISHED, VPN tunnels are healthy."
echo "If Test 3 shows 10.100.0.10, DNS is correctly configured."
echo "If Test 4 returns 'OK', the full path (VM → VPN → ILB → Cloud Run) works."
