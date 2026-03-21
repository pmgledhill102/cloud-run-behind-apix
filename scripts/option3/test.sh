#!/usr/bin/env bash
#
# option3/test.sh — Verify PSC endpoint connectivity to Cloud Run
#
# For scaled variant:
#   SERVICE_COUNT=20 ./scripts/option3/test.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

SERVICE_COUNT="${SERVICE_COUNT:-1}"
PSC_IP="10.0.1.100"

echo "=== Testing PSC Connectivity ==="
echo "Project: ${PROJECT_ID}"
echo "Expected PSC IP: ${PSC_IP}"
echo "Service count: ${SERVICE_COUNT}"
echo ""

# --- Single-service mode (default) ---
if [[ "${SERVICE_COUNT}" -eq 1 ]]; then
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

  # Test 1: DNS
  echo "=========================================="
  echo "  Test 1: DNS Resolution"
  echo "=========================================="
  echo ""
  echo "--- getent hosts ${SERVICE_HOST} ---"
  ssh_cmd "getent hosts ${SERVICE_HOST}" || echo "  FAILED"
  echo ""
  echo "--- dig +short ${SERVICE_HOST} ---"
  ssh_cmd "dig +short ${SERVICE_HOST}" || echo "  FAILED"
  echo ""

  # Test 2: HTTP
  echo "=========================================="
  echo "  Test 2: HTTP Connectivity via PSC"
  echo "=========================================="
  echo ""
  echo "--- curl ${SERVICE_URL} (with ID token) ---"
  ssh_curl_auth "${SERVICE_URL}" "-s --max-time 10 ${SERVICE_URL}/" || echo "  FAILED"
  echo ""

  # Test 3: Routing
  echo "=========================================="
  echo "  Test 3: Verify PSC routing"
  echo "=========================================="
  echo ""
  echo "--- curl -v (connection details, with ID token) ---"
  ssh_curl_auth "${SERVICE_URL}" "-sv --max-time 10 ${SERVICE_URL}/ 2>&1 | grep -E '(Trying|Connected|< HTTP)'" || echo "  FAILED"
  echo ""

  echo "=== Test complete ==="
  echo ""
  echo "If Test 1 shows ${PSC_IP}, DNS is correctly routing through PSC."
  echo "If Test 2 returns 'OK', the full path (VM → PSC → Cloud Run) works."

# --- Scaled mode ---
else
  echo "Collecting Cloud Run service URLs..."
  declare -A SERVICE_URLS
  for i in $(seq -w 1 "${SERVICE_COUNT}"); do
    svc="cr-svc-${i}"
    url=$(gcloud run services describe "${svc}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)
    SERVICE_URLS["${svc}"]="${url}"
  done
  echo "Found ${#SERVICE_URLS[@]} services."
  echo ""

  # Test 1: DNS
  echo "=========================================="
  echo "  Test 1: DNS Resolution (${SERVICE_COUNT} services)"
  echo "=========================================="
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

  # Test 2: HTTP
  echo "=========================================="
  echo "  Test 2: HTTP Connectivity (${SERVICE_COUNT} services)"
  echo "=========================================="
  echo ""
  declare -A HTTP_RESULTS
  for svc in $(printf '%s\n' "${!SERVICE_URLS[@]}" | sort); do
    url="${SERVICE_URLS[$svc]}"
    if [[ -z "${url}" ]]; then
      HTTP_RESULTS["${svc}"]="FAILED"
      continue
    fi
    response=$(ssh_curl_auth "${url}" "-s --max-time 10 ${url}/" 2>/dev/null || echo "FAILED")
    k_service=$(echo "${response}" | grep "^Service:" | awk '{print $2}')
    HTTP_RESULTS["${svc}"]="${k_service:-FAILED}"
    echo "  ${svc}: K_SERVICE=${k_service:-FAILED}"
  done
  echo ""

  # Test 3: Summary
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
    dns_status="FAIL"
    http_status="FAIL"
    [[ "${dns_result}" == "${PSC_IP}" ]] && dns_status="PASS"
    [[ "${http_result}" == "${svc}" ]] && http_status="PASS"
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
  echo "=== Test complete ==="
  echo ""
  echo "Key finding: Zero additional networking infrastructure needed beyond single-service Option C."
fi
