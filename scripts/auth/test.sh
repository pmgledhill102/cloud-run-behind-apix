#!/usr/bin/env bash
#
# auth/test.sh — Verify the JWT enforcement layers, both variants
#
# Maps to docs/auth/jwt-enforcement-design.md §10:
#   Test 1:  JWKS reachable in-perimeter via PGA                (item 4, partial)
#   Test 2:  valid JWT via Apigee → 200, BOTH auth headers seen (items 1, 3, 5)
#   Test 3:  expired / wrong-aud / missing JWT → rejected at edge (item 2 of §5, item 3)
#   Test 4:  direct PGA call bypassing Apigee → 403 at Cloud Run front end (item 2)
#   Test 5:  crude latency comparison /auth-echo vs /hello       (item 3, partial §8)
#   Test E1: valid JWT via Apigee /auth-echo-envoy → 200, enforced by Envoy
#            (app reports mode off), client JWT intact           (item 6)
#   Test E2: Envoy edge rejection, isolated from Apigee: direct VM calls with
#            a Google token in X-Serverless-Authorization + bad client JWTs (item 6)
#   Test E3: latency comparison sidecar vs library               (item 6)
#
# One summary; a failure in either variant fails the suite.
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

percentiles() {  # reads time_total lines on stdin, prints p50/p95 in ms
  sort -n | awk '{a[NR]=$1} END {
    if (NR==0) { print "no samples"; exit }
    p50=a[int(NR*0.5)+1]; p95=a[int(NR*0.95)]; if (NR<20) p95=a[NR];
    printf "p50=%.0fms p95=%.0fms (n=%d)\n", p50*1000, p95*1000, NR }'
}

echo "=== Auth PoC tests — project: ${PROJECT_ID} ==="

if [[ ! -f "${AUTH_PRIVATE_KEY}" ]]; then
  echo "ERROR: no keypair at ${AUTH_PRIVATE_KEY} — run ./scripts/auth/setup.sh first."
  exit 1
fi

AUTH_ECHO_URL="$(gcloud run services describe "${AUTH_ECHO_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
ENVOY_URL="$(gcloud run services describe "${AUTH_ECHO_ENVOY_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
IDP_URL="$(gcloud run services describe "${IDP_MOCK_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
if [[ -z "${AUTH_ECHO_URL}" || -z "${ENVOY_URL}" || -z "${IDP_URL}" ]]; then
  echo "ERROR: services not deployed — run ./scripts/auth/setup.sh first."
  exit 1
fi
echo "auth-echo (library):       ${AUTH_ECHO_URL}"
echo "auth-echo-envoy (sidecar): ${ENVOY_URL}"
echo "idp-mock:                  ${IDP_URL}"

INSTANCE_IP="$(apigee_instance_ip)"
if [[ -z "${INSTANCE_IP}" ]]; then
  echo "NOTE: Apigee not provisioned — tests 2, 3, 5, E1 and E3 will be skipped."
fi
echo ""

echo "Minting test JWTs (signed locally with the mock issuer key)..."
JWT_VALID="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" 300)"
JWT_EXPIRED="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" -3600)"
JWT_WRONG_AUD="$(mint_jwt "${JWT_ISSUER}" "api://someone-else" 300)"
echo "  valid / expired / wrong-aud minted."
echo ""

# ============================================================
# Warm-up: tolerate 503 "no healthy upstream" on fresh proxies
# ============================================================
# Freshly deployed Apigee proxies can 503 for a minute or two while the
# tenant warms the target cluster (observed live 2026-08-03). Absorb that
# here — retry the first request per proxy path — so the tests below never
# count a warming 503 as an enforcement failure.
warm_proxy() {  # warm_proxy <base-path>
  local path="$1" max_attempts="${WARM_MAX_ATTEMPTS:-12}" attempt out code
  for attempt in $(seq 1 "${max_attempts}"); do
    out="$(ssh_cmd "curl -sk --max-time 15 -o /tmp/auth-warm-body -w '%{http_code}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}${path}; echo ''; head -c 80 /tmp/auth-warm-body" || true)"
    code="$(echo "${out}" | head -1)"
    if [[ "${code}" != "503" ]]; then
      echo "  ${path}: HTTP ${code} after ${attempt} attempt(s) — ready"
      return 0
    fi
    echo "  ${path}: HTTP 503 ($(echo "${out}" | tail -n +2)) — retrying in 10s (${attempt}/${max_attempts})"
    sleep 10
  done
  echo "  WARNING: ${path} still 503 after ${max_attempts} attempts — tests will see it as-is"
}
if [[ -n "${INSTANCE_IP}" ]]; then
  echo "Warming proxy paths (fresh deploys can 503 'no healthy upstream')..."
  warm_proxy "/auth-echo"
  warm_proxy "/auth-echo-envoy"
  echo ""
fi

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
# The Google token rides X-Serverless-Authorization (not via ssh_curl_auth,
# which would put it in Authorization and collide with the client JWT there):
# IAM validates it from that header while the middleware still sees the
# client JWT — the combined-header pattern, minted VM-side.
T4_GOOGLE="$(ssh_cmd "ID_TOKEN=\$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${AUTH_ECHO_URL}') && curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H \"X-Serverless-Authorization: Bearer \$ID_TOKEN\" -H 'Authorization: Bearer ${JWT_VALID}' ${AUTH_ECHO_URL}/" 2>/dev/null || true)"
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
T5_AUTH=""
if [[ -n "${INSTANCE_IP}" ]]; then
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
# Test E1: valid JWT via Apigee — Envoy enforces, app trusts
# ============================================================
echo "=========================================="
echo "  Test E1: Valid JWT via Apigee → Envoy variant"
echo "=========================================="
if [[ -n "${INSTANCE_IP}" ]]; then
  E1_OUT="$(ssh_cmd "curl -sk --max-time 20 -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/auth-echo-envoy" || true)"
  echo "${E1_OUT}"
  OK=false; echo "${E1_OUT}" | grep -q '"mode":"off' && OK=true
  verdict "${OK}" "request passed Envoy jwt_authn; app middleware off (sidecar enforced)"
  OK=false; echo "${E1_OUT}" | grep -q '"authorization":true' && OK=true
  verdict "${OK}" "client JWT arrived intact in Authorization (forward: true)"
else
  echo "  SKIPPED (no Apigee)"
fi
echo ""

# ============================================================
# Test E2: Envoy rejection isolated from Apigee (direct calls)
# ============================================================
# The env flow hook would reject bad tokens at the Apigee edge before Envoy
# ever saw them — so to prove ENVOY's enforcement we bypass Apigee: Google ID
# token in X-Serverless-Authorization satisfies Cloud Run IAM (broad invoker
# in this PoC project), leaving Envoy as the deciding layer.
echo "=========================================="
echo "  Test E2: Envoy edge rejection (direct, IAM satisfied)"
echo "=========================================="
e2_call() {  # e2_call <extra-curl-args> → "code body"
  ssh_cmd "ID_TOKEN=\$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${ENVOY_URL}') && curl -s --max-time 10 -o /tmp/e2-body -w '%{http_code}' -H \"X-Serverless-Authorization: Bearer \$ID_TOKEN\" $1 ${ENVOY_URL}/; echo ''; head -c 120 /tmp/e2-body" 2>/dev/null || true
}

E2_VALID="$(e2_call "-H 'Authorization: Bearer ${JWT_VALID}'")"
CODE="$(echo "${E2_VALID}" | head -1)"
echo "  valid:     HTTP ${CODE}"
OK=false; [[ "${CODE}" == "200" ]] && OK=true
verdict "${OK}" "valid client JWT passes Envoy (control)"

# Envoy's rejection taxonomy differs from Apigee VerifyJWT and the library
# (both 401 across the board): jwt_authn returns 401 Unauthenticated for
# expired/missing tokens but 403 Forbidden for an audience mismatch
# ("Audiences in Jwt are not allowed") — found live.
for CASE in "expired:401:${JWT_EXPIRED}" "wrong-aud:403:${JWT_WRONG_AUD}" "missing:401:"; do
  LABEL="${CASE%%:*}"
  REST="${CASE#*:}"
  WANT="${REST%%:*}"
  CASE_JWT="${REST#*:}"
  EXTRA=""
  [[ -n "${CASE_JWT}" ]] && EXTRA="-H 'Authorization: Bearer ${CASE_JWT}'"
  E2_OUT="$(e2_call "${EXTRA}")"
  CODE="$(echo "${E2_OUT}" | head -1)"
  BODY="$(echo "${E2_OUT}" | tail -n +2)"
  echo "  ${LABEL}: HTTP ${CODE}  (${BODY})"
  OK=false; [[ "${CODE}" == "${WANT}" ]] && OK=true
  verdict "${OK}" "${LABEL} token rejected ${WANT} by the Envoy ingress container"
done
echo ""

# ============================================================
# Test E3: latency — sidecar vs library (both via Apigee)
# ============================================================
echo "=========================================="
echo "  Test E3: Latency — sidecar vs library (crude, N=15)"
echo "=========================================="
if [[ -n "${INSTANCE_IP}" ]]; then
  echo "--- /auth-echo-envoy: Envoy jwt_authn + hop to app (middleware off) ---"
  E3_ENVOY="$(ssh_cmd "for i in \$(seq 1 15); do curl -sk --max-time 15 -o /dev/null -w '%{time_total}\n' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/auth-echo-envoy; done" || true)"
  echo "  $(echo "${E3_ENVOY}" | percentiles)"
  echo "--- /auth-echo: library middleware in-process (samples from Test 5) ---"
  echo "  $(echo "${T5_AUTH}" | percentiles)"
  echo "  INFO: both paths share Apigee VerifyJWT (flow hook) + Google token mint +"
  echo "        Cloud Run IAM; the delta isolates Envoy-hop vs in-process validation."
else
  echo "  SKIPPED (no Apigee)"
fi
echo ""

# ============================================================
# INFO: sidecar container startup signals (last 30 log lines)
# ============================================================
echo "=========================================="
echo "  INFO: container startup signals (last 30 log lines)"
echo "=========================================="
gcloud run services logs read "${AUTH_ECHO_ENVOY_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --limit=30 2>/dev/null \
  | grep -Ei "listening|started|startup|probe|ready" | tail -6 || echo "  (no matching log lines)"
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
echo "  item 6 (Envoy sidecar)         → Tests E1, E2, E3"
echo "Not covered: item 7 (org policy), item 8 (deny-list)."
[[ "${FAIL}" -eq 0 ]]
