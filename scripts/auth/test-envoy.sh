#!/usr/bin/env bash
#
# auth/test-envoy.sh — Verify the sidecar variant and compare with the library
#
# Maps to docs/auth/jwt-enforcement-design.md §10 item 6 (issue #39):
#   Test E1: valid JWT via Apigee /auth-echo-envoy → 200, enforced by Envoy
#            (app reports mode off), client JWT intact in Authorization
#   Test E2: Envoy edge rejection, isolated from Apigee: direct VM calls with
#            a Google token in X-Serverless-Authorization + bad client JWTs
#   Test E3: latency comparison /auth-echo-envoy vs /auth-echo (N=15 each)
#   INFO:    cold-start signals from service logs
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

echo "=== Auth PoC sidecar variant tests — project: ${PROJECT_ID} ==="

if [[ ! -f "${AUTH_PRIVATE_KEY}" ]]; then
  echo "ERROR: no keypair at ${AUTH_PRIVATE_KEY} — run ./scripts/auth/setup.sh first."
  exit 1
fi

ENVOY_URL="$(gcloud run services describe "${AUTH_ECHO_ENVOY_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
LIB_URL="$(gcloud run services describe "${AUTH_ECHO_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
if [[ -z "${ENVOY_URL}" ]]; then
  echo "ERROR: ${AUTH_ECHO_ENVOY_SERVICE} not deployed — run ./scripts/auth/setup-envoy.sh first."
  exit 1
fi
echo "envoy variant: ${ENVOY_URL}"
echo "library:       ${LIB_URL:-<not deployed>}"

INSTANCE_IP="$(apigee_instance_ip)"
[[ -z "${INSTANCE_IP}" ]] && echo "NOTE: Apigee not provisioned — tests E1 and E3 will be skipped."
echo ""

echo "Minting test JWTs..."
JWT_VALID="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" 300)"
JWT_EXPIRED="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" -3600)"
JWT_WRONG_AUD="$(mint_jwt "${JWT_ISSUER}" "api://someone-else" 300)"
echo "  valid / expired / wrong-aud minted."
echo ""

# ============================================================
# Test E1: valid JWT via Apigee — Envoy enforces, app trusts
# ============================================================
echo "=========================================="
echo "  Test E1: Valid JWT via Apigee → Envoy variant"
echo "=========================================="
if [[ -n "${INSTANCE_IP}" ]]; then
  E1_TIMED="$(ssh_cmd "curl -sk --max-time 20 -w '\ntime_total=%{time_total}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/auth-echo-envoy" || true)"
  E1_OUT="$(echo "${E1_TIMED}" | sed '$d')"
  echo "${E1_OUT}"
  echo "  INFO: first-request $(echo "${E1_TIMED}" | tail -1) (cold start if the instance was scaled to zero)"
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

for CASE in "expired:${JWT_EXPIRED}" "wrong-aud:${JWT_WRONG_AUD}" "missing:"; do
  LABEL="${CASE%%:*}"
  CASE_JWT="${CASE#*:}"
  EXTRA=""
  [[ -n "${CASE_JWT}" ]] && EXTRA="-H 'Authorization: Bearer ${CASE_JWT}'"
  E2_OUT="$(e2_call "${EXTRA}")"
  CODE="$(echo "${E2_OUT}" | head -1)"
  BODY="$(echo "${E2_OUT}" | tail -n +2)"
  echo "  ${LABEL}: HTTP ${CODE}  (${BODY})"
  OK=false; [[ "${CODE}" == "401" ]] && OK=true
  verdict "${OK}" "${LABEL} token rejected 401 by the Envoy ingress container"
done
echo ""

# ============================================================
# Test E3: latency — sidecar vs library (both via Apigee)
# ============================================================
echo "=========================================="
echo "  Test E3: Latency — sidecar vs library (crude, N=15)"
echo "=========================================="
if [[ -n "${INSTANCE_IP}" && -n "${LIB_URL}" ]]; then
  percentiles() {
    sort -n | awk '{a[NR]=$1} END {
      if (NR==0) { print "no samples"; exit }
      p50=a[int(NR*0.5)+1]; p95=a[int(NR*0.95)]; if (NR<20) p95=a[NR];
      printf "p50=%.0fms p95=%.0fms (n=%d)\n", p50*1000, p95*1000, NR }'
  }
  echo "--- /auth-echo-envoy: Envoy jwt_authn + hop to app (middleware off) ---"
  E3_ENVOY="$(ssh_cmd "for i in \$(seq 1 15); do curl -sk --max-time 15 -o /dev/null -w '%{time_total}\n' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/auth-echo-envoy; done" || true)"
  echo "  $(echo "${E3_ENVOY}" | percentiles)"
  echo "--- /auth-echo: library middleware in-process ---"
  E3_LIB="$(ssh_cmd "for i in \$(seq 1 15); do curl -sk --max-time 15 -o /dev/null -w '%{time_total}\n' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' -H 'Authorization: Bearer ${JWT_VALID}' https://${INSTANCE_IP}/auth-echo; done" || true)"
  echo "  $(echo "${E3_LIB}" | percentiles)"
  echo "  INFO: both paths share Apigee VerifyJWT (flow hook) + Google token mint +"
  echo "        Cloud Run IAM; the delta isolates Envoy-hop vs in-process validation."
else
  echo "  SKIPPED (needs Apigee + the library variant deployed)"
fi
echo ""

# ============================================================
# INFO: cold-start signals from logs
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
echo "=== Sidecar variant results: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]]
