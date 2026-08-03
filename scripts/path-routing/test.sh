#!/usr/bin/env bash
#
# path-routing/test.sh — §9 items 1–3 live proofs (issue #62)
#
#   Phase 1 (item 1a): most-specific base-path match — /payments vs
#     /payments/cards are DIFFERENT proxies; requests land on the right one
#     (proven via X-Served-By, not just the target service)
#   Phase 2 (item 3): base-path conflict — deploy a second proxy claiming
#     /payments/cards; capture the exact error and which stage rejects it
#   Phase 3 (item 2): the carve-out — extract /payments/cards/issuing into
#     its own proxy under a 1s probe loop; prove no 404/5xx window and
#     observe the X-Served-By flip
#   Phase 4 (item 1b): fallback — delete pr-payments-cards; /payments/cards
#     falls back to /payments (and the carved-out proxy keeps its subtree)
#
# MUTATES STATE: phases 2–4 change proxy deployments. Re-run via
# teardown.sh + setup.sh.
#
# If the auth PoC flow hook is live, requests need a client JWT — minted
# here from scripts/auth state (run auth/setup.sh first in that case).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-routing.sh"
source "${SCRIPT_DIR}/lib-proxy.sh"

PASS=0
FAIL=0
verdict() {  # verdict <ok-bool> <label>
  if [[ "$1" == "true" ]]; then
    echo "  PASS: $2"; PASS=$((PASS+1))
  else
    echo "  FAIL: $2"; FAIL=$((FAIL+1))
  fi
}

echo "=== Path-routing PoC tests — project: ${PROJECT_ID} ==="
echo "Run at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

INSTANCE_IP="$(curl -s -H "Authorization: Bearer $(apigee_token)" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"
[[ -n "${INSTANCE_IP}" ]] || { echo "ERROR: no Apigee instance."; exit 1; }

# Client JWT if the auth flow hook is live (harmless extra header if not)
AUTH_HEADER=""
if [[ -f "${SCRIPT_DIR}/../auth/state/idp-private.pem" ]]; then
  source "${SCRIPT_DIR}/../auth/env-auth.sh"
  JWT="$(mint_jwt "${JWT_ISSUER}" "${JWT_AUDIENCE}" 1800)"
  AUTH_HEADER="-H 'Authorization: Bearer ${JWT}'"
  echo "Client JWT minted (flow hook assumed live)."
fi
echo ""

# call <path> → "code|served-by|service" via vm-test
call() {
  local path="$1"
  ssh_cmd "curl -sk --max-time 15 -D /tmp/pr-headers -o /tmp/pr-body -w '%{http_code}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' ${AUTH_HEADER} https://${INSTANCE_IP}${path}; printf '|'; grep -i '^x-served-by:' /tmp/pr-headers | tr -d '\r' | cut -d' ' -f2; printf '|'; grep '^Service:' /tmp/pr-body | cut -d' ' -f2" 2>/dev/null | tr -d '\n'
}

check_route() {  # check_route <path> <want-proxy> <want-service> <label>
  local out code served svc
  out="$(call "$1")"
  code="${out%%|*}"
  served="$(echo "${out}" | cut -d'|' -f2)"
  svc="$(echo "${out}" | cut -d'|' -f3)"
  echo "  $1 → HTTP ${code}, proxy=${served:-none}, service=${svc:-none}"
  local ok=false
  [[ "${code}" == "200" && "${served}" == "$2" && "${svc}" == "$3" ]] && ok=true
  verdict "${ok}" "$4"
}

# ============================================================
# Phase 1: most-specific base-path match (item 1a — the load-bearing wall)
# ============================================================
echo "=========================================="
echo "  Phase 1: Most-specific base-path match"
echo "=========================================="
check_route "/payments/ping" "${PROXY_PAYMENTS}" "${SVC_PAYMENTS}" \
  "/payments lands on pr-payments"
check_route "/payments/cards/ping" "${PROXY_CARDS}" "${SVC_CARDS}" \
  "/payments/cards lands on pr-payments-cards (most-specific proxy wins)"
check_route "/payments/cards/issuing/ping" "${PROXY_CARDS}" "${SVC_ISSUING}" \
  "/payments/cards/issuing routed to issuing svc INSIDE pr-payments-cards (conditional route)"
echo ""

# ============================================================
# Phase 2: base-path conflict (item 3)
# ============================================================
echo "=========================================="
echo "  Phase 2: Base-path conflict"
echo "=========================================="
CARDS_URL="$(gcloud run services describe "${SVC_CARDS}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
BUNDLE_DIR="$(mktemp -d)"
build_single_bundle "${BUNDLE_DIR}" "${PROXY_DUP}" "/payments/cards" "${CARDS_URL}"
echo "Importing '${PROXY_DUP}' claiming /payments/cards..."
DUP_REV="$(import_proxy "${PROXY_DUP}" "${BUNDLE_DIR}" || true)"
rm -rf "${BUNDLE_DIR}"
if [[ -z "${DUP_REV}" ]]; then
  echo "  Import itself was rejected (import-time enforcement)."
  verdict "true" "duplicate base path rejected (at import)"
else
  echo "  Import accepted (rev ${DUP_REV}) — conflict must be deploy-time. Deploying..."
  set +e
  DEPLOY_RESPONSE="$(deploy_proxy "${PROXY_DUP}" "${DUP_REV}")"
  DEPLOY_OK=$?
  set -e
  if [[ ${DEPLOY_OK} -ne 0 ]]; then
    echo "  Deploy rejected. Exact error:"
    echo "${DEPLOY_RESPONSE}" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' || echo "    ${DEPLOY_RESPONSE}"
    verdict "true" "duplicate base path rejected at deploy time with explicit error"
  else
    echo "  DEPLOY SUCCEEDED — checking whether it actually serves (shadowing?)..."
    sleep 20
    OUT="$(call "/payments/cards/ping")"
    echo "  post-dup routing: ${OUT}"
    verdict "false" "duplicate base path rejected (IT WAS NOT — capture behaviour above)"
  fi
fi
undeploy_and_delete_proxy "${PROXY_DUP}"
echo ""

# ============================================================
# Phase 3: the carve-out under a 1s probe (item 2)
# ============================================================
echo "=========================================="
echo "  Phase 3: Live carve-out of /payments/cards/issuing"
echo "=========================================="
ISSUING_URL="$(gcloud run services describe "${SVC_ISSUING}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"

echo "Starting ${PROBE_SECONDS}s probe loop (1/s) against /payments/cards/issuing/ping..."
PROBE_FILE="$(mktemp)"
ssh_cmd "for i in \$(seq 1 ${PROBE_SECONDS}); do printf '%s ' \"\$(date '+%H:%M:%S')\"; curl -sk --max-time 5 -D /tmp/pr-probe-h -o /dev/null -w '%{http_code}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' ${AUTH_HEADER} https://${INSTANCE_IP}/payments/cards/issuing/ping; printf ' '; grep -i '^x-served-by:' /tmp/pr-probe-h | tr -d '\r' | cut -d' ' -f2; echo ''; sleep 1; done" > "${PROBE_FILE}" 2>/dev/null &
PROBE_PID=$!
sleep 5

echo "Deploying dedicated proxy '${PROXY_ISSUING}' (/payments/cards/issuing)..."
BUNDLE_DIR="$(mktemp -d)"
build_single_bundle "${BUNDLE_DIR}" "${PROXY_ISSUING}" "/payments/cards/issuing" "${ISSUING_URL}"
REV="$(import_proxy "${PROXY_ISSUING}" "${BUNDLE_DIR}")"
deploy_proxy "${PROXY_ISSUING}" "${REV}" > /dev/null
wait_deployment_ready "${PROXY_ISSUING}" "${REV}"
rm -rf "${BUNDLE_DIR}"

echo "Removing the issuing conditional route from '${PROXY_CARDS}' (new revision)..."
CARDS_URL="$(gcloud run services describe "${SVC_CARDS}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
BUNDLE_DIR="$(mktemp -d)"
build_cards_bundle "${BUNDLE_DIR}" "false" "${CARDS_URL}" ""
REV="$(import_proxy "${PROXY_CARDS}" "${BUNDLE_DIR}")"
deploy_proxy "${PROXY_CARDS}" "${REV}" > /dev/null
wait_deployment_ready "${PROXY_CARDS}" "${REV}"
rm -rf "${BUNDLE_DIR}"

echo "Waiting for the probe window to close..."
wait "${PROBE_PID}" || true

TOTAL="$(wc -l < "${PROBE_FILE}" | tr -d ' ')"
NON200="$(awk '$2 != 200' "${PROBE_FILE}" | wc -l | tr -d ' ')"
FIRST_NEW="$(awk -v p="${PROXY_ISSUING}" '$3 == p {print $1; exit}' "${PROBE_FILE}")"
LAST_OLD="$(awk -v p="${PROXY_CARDS}" '$3 == p {print $1}' "${PROBE_FILE}" | tail -1)"
echo "  probe samples: ${TOTAL}; non-200: ${NON200}"
echo "  last served by ${PROXY_CARDS}:    ${LAST_OLD:-none}"
echo "  first served by ${PROXY_ISSUING}: ${FIRST_NEW:-never}"
if [[ "${NON200}" != "0" ]]; then
  echo "  non-200 samples:"
  awk '$2 != 200 {print "    " $0}' "${PROBE_FILE}"
fi
OK=false; [[ "${NON200}" == "0" && "${TOTAL}" -gt 100 ]] && OK=true
verdict "${OK}" "no 404/5xx window during the carve-out (${TOTAL} samples at 1/s)"
OK=false; [[ -n "${FIRST_NEW}" ]] && OK=true
verdict "${OK}" "traffic flipped to the dedicated proxy (most-specific match re-won)"
rm -f "${PROBE_FILE}"
echo ""

# ============================================================
# Phase 4: fallback after deleting the middle proxy (item 1b)
# ============================================================
echo "=========================================="
echo "  Phase 4: Fallback — delete pr-payments-cards"
echo "=========================================="
undeploy_and_delete_proxy "${PROXY_CARDS}"
sleep 20
check_route "/payments/cards/ping" "${PROXY_PAYMENTS}" "${SVC_PAYMENTS}" \
  "/payments/cards falls back to pr-payments after the nested proxy is deleted"
check_route "/payments/cards/issuing/ping" "${PROXY_ISSUING}" "${SVC_ISSUING}" \
  "carved-out subtree unaffected by deleting the proxy 'between' its path and /payments"
echo ""

echo "=== Path-routing results: ${PASS} passed, ${FAIL} failed ==="
echo ""
echo "State is now post-test (cards proxy deleted, issuing carved out)."
echo "Run teardown.sh then setup.sh to restore the start state."
[[ "${FAIL}" -eq 0 ]]
