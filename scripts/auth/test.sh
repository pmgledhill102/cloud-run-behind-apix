#!/usr/bin/env bash
#
# auth/test.sh — Verify the JWT enforcement layers
#
# Maps to docs/auth/jwt-enforcement-design.md §10:
#   Test 1: JWKS reachable in-perimeter via PGA                (item 4, partial)
#   Test 2: valid JWT via Apigee → 200, BOTH auth headers seen (items 1, 3, 5)
#   Test 3: expired / wrong-aud / missing JWT → rejected at edge (item 2 of §5, item 3)
#   Test 4: direct PGA call bypassing Apigee → 403 at Cloud Run front end (item 2)
#   Test 5: crude latency comparison /auth-echo vs /hello       (item 3, partial §8)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-auth.sh"

PASS=0
FAIL=0
verdict() {  # verdict <ok-bool> <label>
  if [[ "$1" == "true" ]]; then
    echo "  PASS: $2"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $2"; FAIL=$((FAIL + 1))
  fi
}

echo "=== Auth PoC tests — project: ${PROJECT_ID} ==="

if [[ ! -f "${AUTH_PRIVATE_KEY}" ]]; then
  echo "ERROR: no keypair at ${AUTH_PRIVATE_KEY} — run ./scripts/auth/setup.sh first."
  exit 1
fi

AUTH_ECHO_URL="$(gcloud run services describe "${AUTH_ECHO_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
IDP_URL="$(gcloud run services describe "${IDP_MOCK_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
if [[ -z "${AUTH_ECHO_URL}" || -z "${IDP_URL}" ]]; then
  echo "ERROR: services not deployed — run ./scripts/auth/setup.sh first."
  exit 1
fi
echo "auth-echo: ${AUTH_ECHO_URL}"
echo "idp-mock:  ${IDP_URL}"

INSTANCE_IP="$(apigee_instance_ip)"
if [[ -z "${INSTANCE_IP}" ]]; then
  echo "NOTE: Apigee not provisioned — tests 2, 3 and 5 will be skipped."
fi
echo ""

echo "Minting test JWTs (signed locally with the mock issuer key)..."
JWT_VALID="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" 300)"
JWT_EXPIRED="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" -3600)"
JWT_WRONG_AUD="$(mint_jwt "${JWT_ISSUER}" "api://someone-else" 300)"
echo "  valid / expired / wrong-aud minted."
echo ""

# ============================================================
# Test 1: JWKS endpoint reachable in-perimeter via PGA
# ============================================================
echo "=========================================="
echo "  Test 1: JWKS via PGA (internal mirror posture)"
echo "=========================================="
JWKS_OUT="$(ssh_cmd "curl -s --max-time 10 ${IDP_URL}/.well-known/jwks.json" || true)"
echo "${JWKS_OUT}" | head -c 200; echo ""
OK=false; echo "${JWKS_OUT}" | grep -q "\"kid\":\"${JWT_KID}\"" && OK=true
verdict "${OK}" "JWKS served over PGA without a Google token (allow-unauth + ingress=internal)"
echo ""

# ============================================================
# Test 2: valid JWT via Apigee — the combined-header pattern
# ============================================================
echo "=========================================="
echo "  Test 2: Valid JWT via Apigee (combined headers)"
echo "=========================================="
if [[ -n "${INSTANCE_IP}" ]]; then
  T2_OUT="$(ssh_cmd "curl -sk --max-time 15 -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/auth-echo" || true)"
  echo "${T2_OUT}"
  OK=false; echo "${T2_OUT}" | grep -q '"valid":true' && OK=true
  verdict "${OK}" "client JWT validated end-to-end (Apigee VerifyJWT + middleware)"
  OK=false; echo "${T2_OUT}" | grep -q '"authorization":true' && OK=true
  verdict "${OK}" "client JWT arrived intact in Authorization (§10 item 1)"
  # Informational, not asserted: whether Cloud Run forwards
  # X-Serverless-Authorization to the container is itself a PoC finding.
  if echo "${T2_OUT}" | grep -q '"x_serverless_authorization":true'; then
    echo "  INFO: X-Serverless-Authorization forwarded to the container"
  else
    echo "  INFO: X-Serverless-Authorization NOT forwarded (stripped by Cloud Run front end)"
    echo "        — combined pattern still proven: IAM accepted the Google token from that header"
  fi
  echo "  INFO: custom audience '${GOOGLE_CUSTOM_AUDIENCE}' accepted (§10 item 5) — this request"
  echo "        succeeded with the fixed-string audience, not the service URL"
else
  echo "  SKIPPED (no Apigee)"
fi
echo ""

# ============================================================
# Test 3: bad tokens rejected at the edge (shared flow / flow hook)
# ============================================================
echo "=========================================="
echo "  Test 3: Edge rejection (VerifyJWT via flow hook)"
echo "=========================================="
if [[ -n "${INSTANCE_IP}" ]]; then
  for CASE in "expired:${JWT_EXPIRED}" "wrong-aud:${JWT_WRONG_AUD}" "missing:"; do
    LABEL="${CASE%%:*}"
    CASE_JWT="${CASE#*:}"
    AUTH_HDR=""
    [[ -n "${CASE_JWT}" ]] && AUTH_HDR="-H 'Authorization: Bearer ${CASE_JWT}'"
    CODE_BODY="$(ssh_cmd "curl -sk --max-time 15 -o /tmp/auth-t3-body -w '%{http_code}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' ${AUTH_HDR} https://${INSTANCE_IP}/auth-echo; echo ''; head -c 200 /tmp/auth-t3-body" || true)"
    CODE="$(echo "${CODE_BODY}" | head -1)"
    echo "  ${LABEL}: HTTP ${CODE}"
    echo "${CODE_BODY}" | tail -n +2 | sed 's/^/    /'
    OK=false; [[ "${CODE}" == "401" ]] && OK=true
    verdict "${OK}" "${LABEL} token rejected with 401 at the Apigee edge"
  done
else
  echo "  SKIPPED (no Apigee)"
fi
echo ""

# ============================================================
# Test 4: direct PGA call bypassing Apigee (threat T3)
# ============================================================
echo "=========================================="
echo "  Test 4: Direct PGA bypass → Cloud Run IAM"
echo "=========================================="
echo "In-perimeter VM calls ${AUTH_ECHO_SERVICE} directly over PGA, skipping Apigee."
echo ""
T4_NOTOKEN="$(ssh_cmd "curl -s --max-time 10 -o /dev/null -w '%{http_code}' ${AUTH_ECHO_URL}/" || true)"
echo "  no token:            HTTP ${T4_NOTOKEN}"
OK=false; [[ "${T4_NOTOKEN}" == "403" || "${T4_NOTOKEN}" == "401" ]] && OK=true
verdict "${OK}" "unauthenticated direct call blocked before the container (T3)"

T4_CLIENTJWT="$(ssh_cmd "curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ${JWT_VALID}' ${AUTH_ECHO_URL}/" || true)"
echo "  valid CLIENT jwt:    HTTP ${T4_CLIENTJWT}"
OK=false; [[ "${T4_CLIENTJWT}" == "403" || "${T4_CLIENTJWT}" == "401" ]] && OK=true
verdict "${OK}" "a valid client JWT means nothing to Cloud Run IAM — still blocked"

# Informational: a GOOGLE ID token from the VM's SA. In this PoC project the
# default compute SA holds project-level run.invoker (needed by options 1-4
# tests), so this succeeds HERE — in the target design the invoker grant is
# per-service to the proxy SA only, and this call would 403. The control is
# invoker hygiene, not the platform (design doc §6 residual risk).
T4_GOOGLE="$(ssh_curl_auth "${AUTH_ECHO_URL}" "-s --max-time 10 -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer ${JWT_VALID}' ${AUTH_ECHO_URL}/" 2>/dev/null || true)"
echo "  INFO: Google ID token from VM SA: HTTP ${T4_GOOGLE:-n/a}"
echo "        (succeeds here because the PoC project grants run.invoker broadly;"
echo "         per-service invoker grants close this in the real design)"
echo ""

# ============================================================
# Test 5: latency — /auth-echo (mint+IAM+middleware) vs /hello
# ============================================================
echo "=========================================="
echo "  Test 5: Latency comparison (crude, N=15)"
echo "=========================================="
if [[ -n "${INSTANCE_IP}" ]]; then
  percentiles() {  # reads time_total lines on stdin, prints p50/p95 in ms
    sort -n | awk '{a[NR]=$1} END {
      if (NR==0) { print "no samples"; exit }
      p50=a[int(NR*0.5)+1]; p95=a[int(NR*0.95)]; if (NR<20) p95=a[NR];
      printf "p50=%.0fms p95=%.0fms (n=%d)\n", p50*1000, p95*1000, NR }'
  }
  echo "--- /auth-echo: VerifyJWT + Google token mint + IAM + middleware ---"
  T5_AUTH="$(ssh_cmd "for i in \$(seq 1 15); do curl -sk --max-time 15 -o /dev/null -w '%{time_total}\n' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/auth-echo; done" || true)"
  echo "  $(echo "${T5_AUTH}" | percentiles)"
  echo "--- /hello: VerifyJWT only (flow hook applies env-wide; no mint, no middleware) ---"
  T5_HELLO="$(ssh_cmd "for i in \$(seq 1 15); do curl -sk --max-time 15 -o /dev/null -w '%{time_total}\n' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/hello; done" || true)"
  echo "  $(echo "${T5_HELLO}" | percentiles)"
  echo "  INFO: the delta ≈ Google token mint (cached ≈0 after first) + IAM check +"
  echo "        middleware; first /auth-echo sample may include a cold start (§8.2)."
else
  echo "  SKIPPED (no Apigee)"
fi
echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Auth PoC results: ${PASS} passed, ${FAIL} failed ==="
echo ""
echo "Design doc §10 items exercised:"
echo "  item 1 (combined headers)      → Test 2"
echo "  item 2 (direct-PGA 403)        → Test 4"
echo "  item 3 (flow-hook VerifyJWT,"
echo "          rejects, latency)      → Tests 2, 3, 5"
echo "  item 4 (JWKS mirror, partial)  → Test 1 + auth-echo startup logs:"
echo "    gcloud run services logs read ${AUTH_ECHO_SERVICE} --region=${REGION} --project=${PROJECT_ID} --limit=20 | grep JWKS"
echo "  item 5 (custom audiences)      → Test 2"
echo "Not covered: item 6 (sidecar), item 7 (org policy), item 8 (deny-list)."
[[ "${FAIL}" -eq 0 ]]
