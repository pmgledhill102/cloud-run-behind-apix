#!/usr/bin/env bash
#
# test.sh — Verify PSC endpoint connectivity to 20 Cloud Run services
#
# Test 1: DNS resolution — *.run.app resolves to the PSC endpoint IP for each service
# Test 2: HTTP connectivity — curl each Cloud Run service through the PSC endpoint
# Test 3: Summary table — pass/fail for each service
#
# Prerequisites: setup-infra.sh and setup-psc.sh completed.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
PSC_IP="10.100.0.1"
SERVICE_COUNT=20

echo "=== Testing PSC Connectivity (${SERVICE_COUNT} services) ==="
echo "Project: ${PROJECT_ID}"
echo "Expected PSC IP: ${PSC_IP}"
echo ""

# Helper — run a command on vm-test via IAP SSH (filters NumPy warning, keeps real errors)
ssh_cmd() {
  gcloud compute ssh "vm-test" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --project="${PROJECT_ID}" \
    --command="$1" 2> >(grep -v 'NumPy' >&2)
}

# Collect service URLs
echo "Collecting Cloud Run service URLs..."
declare -A SERVICE_URLS
for i in $(seq -w 1 ${SERVICE_COUNT}); do
  svc="cr-svc-${i}"
  url=$(gcloud run services describe "${svc}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)
  SERVICE_URLS["${svc}"]="${url}"
done
echo "Found ${#SERVICE_URLS[@]} services."
echo ""

# ============================================================
# Test 1: DNS Resolution
# ============================================================
echo "=========================================="
echo "  Test 1: DNS Resolution (${SERVICE_COUNT} services)"
echo "=========================================="
echo ""
echo "Verifying *.run.app resolves to ${PSC_IP} (PSC endpoint) for each service..."
echo ""

declare -A DNS_RESULTS
for svc in $(printf '%s\n' "${!SERVICE_URLS[@]}" | sort); do
  url="${SERVICE_URLS[$svc]}"
  if [[ -z "${url}" ]]; then
    echo "  ${svc}: URL not found — SKIPPED"
    DNS_RESULTS["${svc}"]="FAILED"
    continue
  fi
  host="${url#https://}"
  result=$(ssh_cmd "getent hosts ${host} | awk '{print \$1}'" 2>/dev/null || echo "FAILED")
  DNS_RESULTS["${svc}"]="${result}"
  echo "  ${svc}: ${host} → ${result}"
done

echo ""

# ============================================================
# Test 2: HTTP Connectivity
# ============================================================
echo "=========================================="
echo "  Test 2: HTTP Connectivity (${SERVICE_COUNT} services)"
echo "=========================================="
echo ""
echo "VM → PSC endpoint (${PSC_IP}) → Google backbone → Cloud Run"
echo ""

declare -A HTTP_RESULTS
for svc in $(printf '%s\n' "${!SERVICE_URLS[@]}" | sort); do
  url="${SERVICE_URLS[$svc]}"
  if [[ -z "${url}" ]]; then
    echo "  ${svc}: URL not found — SKIPPED"
    HTTP_RESULTS["${svc}"]="FAILED"
    continue
  fi
  response=$(ssh_cmd "curl -s --max-time 10 ${url}/" 2>/dev/null || echo "FAILED")
  k_service=$(echo "${response}" | grep "^Service:" | awk '{print $2}')
  HTTP_RESULTS["${svc}"]="${k_service:-FAILED}"
  echo "  ${svc}: K_SERVICE=${k_service:-FAILED}"
done

echo ""

# ============================================================
# Test 3: Summary
# ============================================================
echo "=========================================="
echo "  Test 3: Summary"
echo "=========================================="
echo ""
printf "  %-15s %-12s %-12s\n" "SERVICE" "DNS" "HTTP"
printf "  %-15s %-12s %-12s\n" "-------" "---" "----"

PASS_COUNT=0
FAIL_COUNT=0
for svc in $(printf '%s\n' "${!SERVICE_URLS[@]}" | sort); do
  dns_result="${DNS_RESULTS[$svc]}"
  http_result="${HTTP_RESULTS[$svc]}"

  if [[ "${dns_result}" == "${PSC_IP}" ]]; then
    dns_status="PASS"
  else
    dns_status="FAIL"
  fi

  if [[ "${http_result}" == "${svc}" ]]; then
    http_status="PASS"
  else
    http_status="FAIL"
  fi

  if [[ "${dns_status}" == "PASS" && "${http_status}" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi

  printf "  %-15s %-12s %-12s\n" "${svc}" "${dns_status}" "${http_status}"
done

echo ""
echo "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed out of ${SERVICE_COUNT} services"
echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Test complete ==="
echo ""
echo "If DNS shows PASS for all services, the single wildcard *.run.app → ${PSC_IP} covers all ${SERVICE_COUNT} services."
echo "If HTTP shows PASS for all services, the full path (VM → PSC → Cloud Run) works for every service."
echo ""
echo "Key finding: Zero additional networking infrastructure needed beyond single-service Option C."
