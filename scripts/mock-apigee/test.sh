#!/usr/bin/env bash
#
# mock-apigee/test.sh — Verify the mock-Apigee gateway mirrors the real flows
#
#   Test M1: valid JWT → /auth-echo 200 with BOTH auth headers seen
#            (client JWT intact in Authorization + Google ID token minted
#             into X-Serverless-Authorization — the combined-header pattern)
#   Test M2: expired / wrong-aud / missing JWT rejected at the mock edge
#            (Envoy jwt_authn signatures: 401/403/401 — NOT Apigee's
#             {"fault":...} taxonomy; flows faithful, error surface differs)
#   Test M3: valid JWT → /hello 200 (plain passthrough proxy shape)
#   Test M4: southbound resolves run.app to the restricted VIP from the
#            gateway VM (PGA path, not public IPs)
#
# Calls originate from vm-test in apigee-vpc — same topology as the real
# tests hitting the Apigee instance at 10.2.0.2, one peering hop away.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/../auth/env-auth.sh"
source "${SCRIPT_DIR}/env-mock.sh"

PASS=0
FAIL=0
verdict() {  # verdict <ok-bool> <label>
  if [[ "$1" == "true" ]]; then
    echo "  PASS: $2"; PASS=$((PASS+1))
  else
    echo "  FAIL: $2"; FAIL=$((FAIL+1))
  fi
}

echo "=== Mock-Apigee tests — project: ${PROJECT_ID} ==="
echo "Run at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

if [[ ! -f "${AUTH_PRIVATE_KEY}" ]]; then
  echo "ERROR: no keypair at ${AUTH_PRIVATE_KEY} — run ./scripts/auth/setup.sh first."
  exit 1
fi
if ! resource_exists gcloud compute instances describe "${MOCK_GW_VM}" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  echo "ERROR: gateway VM '${MOCK_GW_VM}' not found — run ./scripts/mock-apigee/setup.sh first."
  exit 1
fi

echo "Minting test JWTs (signed locally with the mock issuer key)..."
JWT_VALID="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" 300)"
JWT_EXPIRED="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" -300)"
JWT_WRONG_AUD="$(mint_jwt "${JWT_ISSUER}" "api://someone-else" 300)"
echo "  valid / expired / wrong-aud minted."
echo ""

# ============================================================
# Readiness: first boot pulls the image (~1-2 min)
# ============================================================
echo "Waiting for the gateway to answer /healthz (first boot pulls the image)..."
READY=false
for attempt in $(seq 1 24); do
  CODE="$(ssh_cmd "curl -sk --max-time 5 -o /dev/null -w '%{http_code}' https://${MOCK_GW_IP}/healthz" 2>/dev/null || true)"
  if [[ "${CODE}" == "200" ]]; then
    echo "  gateway ready after ${attempt} attempt(s)."
    READY=true
    break
  fi
  echo "  not ready (HTTP ${CODE:-none}) — retrying in 5s (${attempt}/24)"
  sleep 5
done
if [[ "${READY}" != "true" ]]; then
  echo "ERROR: gateway never became ready. Container logs:"
  echo "  gcloud compute ssh ${MOCK_GW_VM} --zone=${ZONE} --tunnel-through-iap --project=${PROJECT_ID} --command='docker ps -a; docker logs \$(docker ps -aq | head -1) 2>&1 | tail -50'"
  exit 1
fi
echo ""

# ============================================================
# Test M1: valid JWT → /auth-echo (combined headers)
# ============================================================
echo "=========================================="
echo "  Test M1: Valid JWT → /auth-echo (combined headers)"
echo "=========================================="
M1_OUT="$(ssh_cmd "curl -sk --max-time 15 -H 'Authorization: Bearer ${JWT_VALID}' https://${MOCK_GW_IP}/auth-echo" || true)"
echo "${M1_OUT}"
OK=false; echo "${M1_OUT}" | grep -q '"service":"cr-auth-echo"' && OK=true
verdict "${OK}" "request reached cr-auth-echo through the mock gateway"
OK=false; echo "${M1_OUT}" | grep -q '"authorization":true' && OK=true
verdict "${OK}" "client JWT arrived intact in Authorization"
OK=false; echo "${M1_OUT}" | grep -q '"x_serverless_authorization":true' && OK=true
verdict "${OK}" "Google ID token minted into X-Serverless-Authorization (gcp_authn)"
echo ""

# ============================================================
# Test M2: edge rejection (Envoy jwt_authn = the flow hook)
# ============================================================
echo "=========================================="
echo "  Test M2: Edge rejection (jwt_authn, all routes)"
echo "=========================================="
# Envoy's taxonomy: 401 expired/missing, 403 audience mismatch — documented
# as different from Apigee VerifyJWT's uniform 401 {"fault":...} responses.
for CASE in "expired:401:${JWT_EXPIRED}" "wrong-aud:403:${JWT_WRONG_AUD}" "missing:401:"; do
  LABEL="${CASE%%:*}"
  REST="${CASE#*:}"
  WANT="${REST%%:*}"
  CASE_JWT="${REST#*:}"
  AUTH_HDR=""
  [[ -n "${CASE_JWT}" ]] && AUTH_HDR="-H 'Authorization: Bearer ${CASE_JWT}'"
  M2_OUT="$(ssh_cmd "curl -sk --max-time 10 -o /tmp/mock-m2-body -w '%{http_code}' ${AUTH_HDR} https://${MOCK_GW_IP}/auth-echo; echo ''; head -c 100 /tmp/mock-m2-body" || true)"
  CODE="$(echo "${M2_OUT}" | head -1)"
  BODY="$(echo "${M2_OUT}" | tail -n +2)"
  echo "  ${LABEL}: HTTP ${CODE}  (${BODY})"
  OK=false; [[ "${CODE}" == "${WANT}" ]] && OK=true
  verdict "${OK}" "${LABEL} token rejected ${WANT} at the mock edge"
done
echo ""

# ============================================================
# Test M3: valid JWT → /hello (passthrough proxy shape)
# ============================================================
echo "=========================================="
echo "  Test M3: Valid JWT → /hello (passthrough)"
echo "=========================================="
M3_OUT="$(ssh_cmd "curl -sk --max-time 15 -H 'Authorization: Bearer ${JWT_VALID}' https://${MOCK_GW_IP}/hello" || true)"
echo "${M3_OUT}" | head -3
OK=false; echo "${M3_OUT}" | grep -q "Service: cr-hello" && OK=true
verdict "${OK}" "/hello reached cr-hello through the mock gateway (JWT required, ID token minted)"
echo ""

# ============================================================
# Test M4: southbound goes via the restricted VIP (PGA path)
# ============================================================
echo "=========================================="
echo "  Test M4: Southbound DNS → restricted VIP"
echo "=========================================="
AUTH_ECHO_HOST_ONLY="$(gcloud run services describe "${AUTH_ECHO_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
AUTH_ECHO_HOST_ONLY="${AUTH_ECHO_HOST_ONLY#https://}"
# COS has no getent — resolve inside the gateway container (Ubuntu-based,
# shares the host network + resolv.conf: the exact resolver path Envoy uses).
M4_OUT="$(gcloud compute ssh "${MOCK_GW_VM}" \
  --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
  --command="docker exec \$(docker ps -q | head -1) getent hosts ${AUTH_ECHO_HOST_ONLY}" 2> >(grep -v 'NumPy' >&2) || true)"
echo "${M4_OUT}"
OK=false; echo "${M4_OUT}" | grep -q "199\.36\.153\." && OK=true
verdict "${OK}" "gateway VM resolves run.app to 199.36.153.x (restricted VIP, not public)"
echo ""

echo "=== Mock-Apigee results: ${PASS} passed, ${FAIL} failed ==="
echo ""
echo "Reminder: mock = inner loop. Anything proven here still needs one"
echo "real-Apigee run (options 2/2b + auth suites) before documenting."
[[ "${FAIL}" -eq 0 ]]
