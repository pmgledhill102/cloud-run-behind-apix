#!/usr/bin/env bash
#
# option2b/test-external.sh — Prove Apigee can ONLY reach in-perimeter Cloud Run
#
# The main test suite proves the perimeter blocks the VM's access to an
# out-of-perimeter GCS bucket. This script proves the sharper claim: with the
# lockdown in place, Apigee's southbound path cannot reach a Cloud Run service
# in ANOTHER project (outside the perimeter), while in-perimeter Cloud Run
# still works.
#
# Probes:
#   0 (control) laptop → external service        → expect OK (service is up;
#                                                   the laptop is outside the
#                                                   perimeter, public path)
#   1 (control) Apigee → in-perimeter cr-hello   → expect OK (Apigee healthy)
#   2 (subject) Apigee → EXTERNAL Cloud Run      → expect BLOCKED
#   3 (subject) VM     → EXTERNAL Cloud Run      → expect BLOCKED
#
# "BLOCKED" = anything other than the service's healthy body. The tenant/VM
# resolve *.run.app to the restricted VIP (wildcard zone), so the request hits
# the VPC-SC-enforcing frontend, which denies out-of-perimeter targets — the
# exact status (403 vs 404) is not contractual, so we assert on the body and
# print what actually came back. If the healthy body ever appears, that is a
# perimeter LEAK and the test fails loudly.
#
# Requires: option2b/setup.sh applied, Apigee provisioned.
# A pass-through proxy 'cr-external-passthrough' (/external) is created and
# deployed idempotently as a test fixture; option2b/teardown.sh removes it.
#
# Usage:
#   ./scripts/option2b/test-external.sh
#   EXTERNAL_RUN_URL=https://my-svc-<num>.<region>.run.app/health ./scripts/option2b/test-external.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

# A Cloud Run service in a project OUTSIDE the perimeter, with a public
# health endpoint returning {"status":"ok"} (or similar) when reachable.
EXTERNAL_RUN_URL="${EXTERNAL_RUN_URL:-https://sandbox-manager-255182376214.europe-west2.run.app/health}"
EXTERNAL_HOST="${EXTERNAL_RUN_URL#https://}"
EXTERNAL_HOST="${EXTERNAL_HOST%%/*}"
EXTERNAL_PROXY_NAME="cr-external-passthrough"
EXTERNAL_BASEPATH="/external"
HEALTHY_PATTERN='"ok"'

echo "=== Testing perimeter: Apigee → OUT-OF-PERIMETER Cloud Run ==="
echo "Project:  ${PROJECT_ID}"
echo "External: ${EXTERNAL_RUN_URL}"
echo "Run at:   $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

TOKEN="$(gcloud auth print-access-token)"

# ============================================================
# Preconditions: Apigee org + instance
# ============================================================
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"
if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "ERROR: Apigee not provisioned — this test is specifically about the"
  echo "Apigee southbound path. Run shared/setup-slow.sh first."
  exit 1
fi

INSTANCE_IP="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"
if [[ -z "${INSTANCE_IP}" ]]; then
  echo "ERROR: Apigee instance not ACTIVE."
  exit 1
fi

# ============================================================
# Fixture: pass-through proxy to the external service (idempotent)
# ============================================================
echo "--- Fixture: proxy '${EXTERNAL_PROXY_NAME}' (${EXTERNAL_BASEPATH} → ${EXTERNAL_RUN_URL}) ---"

PROXY_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${EXTERNAL_PROXY_NAME}")"

if [[ "${PROXY_HTTP}" == "200" ]]; then
  echo "Proxy exists, skipping import."
else
  BUNDLE_DIR="$(mktemp -d)"
  mkdir -p "${BUNDLE_DIR}/apiproxy/proxies" "${BUNDLE_DIR}/apiproxy/targets"

  cat > "${BUNDLE_DIR}/apiproxy/proxies/default.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPProxyConnection>
    <BasePath>${EXTERNAL_BASEPATH}</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

  # No <Authentication> block: the external /health endpoint is public, so
  # this tests the network path in isolation (no token minting involved).
  cat > "${BUNDLE_DIR}/apiproxy/targets/default.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPTargetConnection>
    <URL>${EXTERNAL_RUN_URL}</URL>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

  cat > "${BUNDLE_DIR}/apiproxy/${EXTERNAL_PROXY_NAME}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${EXTERNAL_PROXY_NAME}">
  <Description>Test fixture: pass-through to OUT-OF-PERIMETER Cloud Run</Description>
  <BasePaths>${EXTERNAL_BASEPATH}</BasePaths>
</APIProxy>
XMLEOF

  BUNDLE_ZIP="$(mktemp).zip"
  (cd "${BUNDLE_DIR}" && zip -r "${BUNDLE_ZIP}" apiproxy/) >/dev/null
  IMPORT_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${EXTERNAL_PROXY_NAME}&action=import" \
    --data-binary "@${BUNDLE_ZIP}")"
  rm -rf "${BUNDLE_DIR}" "${BUNDLE_ZIP}"
  if echo "${IMPORT_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR importing fixture proxy:"
    echo "${IMPORT_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${IMPORT_RESPONSE}"
    exit 1
  fi
  echo "Proxy imported (revision 1)."
fi

DEPLOY_CHECK="$(curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/deployments")"
if echo "${DEPLOY_CHECK}" | grep -q "\"${EXTERNAL_PROXY_NAME}\""; then
  echo "Proxy already deployed."
else
  DEPLOY_RESPONSE="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${EXTERNAL_PROXY_NAME}/revisions/1/deployments?override=true")"
  if echo "${DEPLOY_RESPONSE}" | grep -q '"error"'; then
    echo "ERROR deploying fixture proxy:"
    echo "${DEPLOY_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${DEPLOY_RESPONSE}"
    exit 1
  fi
  echo "Deployment started; waiting for READY..."
  ELAPSED=0
  while true; do
    STATE="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${EXTERNAL_PROXY_NAME}/revisions/1/deployments" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
    [[ "${STATE}" == "READY" ]] && { echo "Deployment READY."; break; }
    if (( ELAPSED >= 180 )); then
      echo "WARNING: deployment not READY after 180s (state: ${STATE:-unknown}); probing anyway."
      break
    fi
    sleep 10; ELAPSED=$((ELAPSED + 10))
  done
  sleep 10  # small settle for runtime routing
fi
echo ""

# ============================================================
# Probe 0 (control): laptop → external service (outside perimeter)
# ============================================================
echo "=========================================="
echo "  Probe 0 (control): laptop → external service"
echo "=========================================="
echo "Expect OK — proves the external service is actually up."
echo ""
LAPTOP_OUT="$(curl -s --max-time 15 "${EXTERNAL_RUN_URL}" || true)"
echo "${LAPTOP_OUT:-(no response)}"
if echo "${LAPTOP_OUT}" | grep -qi "${HEALTHY_PATTERN}"; then
  RESULT0="PASS"
else
  RESULT0="FAIL"
  echo "(external service unreachable from the laptop — blocked results below"
  echo " would be INCONCLUSIVE: the service may simply be down)"
fi
echo ""

# ============================================================
# Probe 1 (control): Apigee → in-perimeter cr-hello
# ============================================================
echo "=========================================="
echo "  Probe 1 (control): Apigee → in-perimeter cr-hello"
echo "=========================================="
echo "Expect OK — proves Apigee southbound is healthy inside the perimeter."
echo ""
CONTROL_OUT="$(ssh_cmd "curl -sk --max-time 15 -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}/hello" || true)"
echo "${CONTROL_OUT:-(no response)}"
if echo "${CONTROL_OUT}" | grep -q "^OK"; then
  RESULT1="PASS"
else
  RESULT1="FAIL"
fi
echo ""

# ============================================================
# Probe 2 (subject): Apigee → EXTERNAL Cloud Run
# ============================================================
echo "=========================================="
echo "  Probe 2 (subject): Apigee → EXTERNAL Cloud Run"
echo "=========================================="
echo "Expect BLOCKED — the target project is outside the perimeter."
echo ""
APIGEE_EXT_OUT="$(ssh_cmd "curl -sk --max-time 20 -w '\nHTTP_STATUS:%{http_code}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}${EXTERNAL_BASEPATH}" || true)"
echo "${APIGEE_EXT_OUT:-(no response)}"
if echo "${APIGEE_EXT_OUT}" | grep -qi "${HEALTHY_PATTERN}"; then
  RESULT2="LEAK"
else
  RESULT2="PASS"
fi
echo ""

# ============================================================
# Probe 3 (subject): VM → EXTERNAL Cloud Run directly
# ============================================================
echo "=========================================="
echo "  Probe 3 (subject): VM → EXTERNAL Cloud Run"
echo "=========================================="
echo "Expect BLOCKED — same perimeter, no Apigee involved."
echo ""
echo "--- DNS seen by the VM (wildcard zone should give 199.36.153.x) ---"
ssh_cmd "getent hosts ${EXTERNAL_HOST}" || echo "  (resolution failed)"
echo ""
VM_EXT_OUT="$(ssh_cmd "curl -s --max-time 20 -w '\nHTTP_STATUS:%{http_code}' '${EXTERNAL_RUN_URL}'" || true)"
echo "${VM_EXT_OUT:-(no response)}"
if echo "${VM_EXT_OUT}" | grep -qi "${HEALTHY_PATTERN}"; then
  RESULT3="LEAK"
else
  RESULT3="PASS"
fi
echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Test results ==="
echo ""
echo "Probe 0 [${RESULT0}]  control: laptop → external service (expect OK)"
echo "Probe 1 [${RESULT1}]  control: Apigee → in-perimeter cr-hello (expect OK)"
echo "Probe 2 [${RESULT2}]  Apigee → external Cloud Run (expect BLOCKED)"
echo "Probe 3 [${RESULT3}]  VM → external Cloud Run (expect BLOCKED)"
echo ""
if [[ "${RESULT2}" == "LEAK" || "${RESULT3}" == "LEAK" ]]; then
  echo "FAIL: the external service's healthy body was returned from inside the"
  echo "perimeter — the lockdown is NOT containing Cloud Run egress."
  exit 1
elif [[ "${RESULT0}" == "FAIL" ]]; then
  echo "INCONCLUSIVE: probes 2/3 were blocked, but the external service was"
  echo "unreachable from the laptop too — verify it is up and re-run."
  exit 1
elif [[ "${RESULT1}" == "FAIL" ]]; then
  echo "INCONCLUSIVE: Apigee could not reach the IN-perimeter service either,"
  echo "so probe 2's block may just mean Apigee southbound is broken."
  exit 1
else
  echo "PROVEN: Apigee (and the VM) can reach in-perimeter Cloud Run but NOT a"
  echo "Cloud Run service outside the perimeter. Egress is bounded by VPC-SC."
fi
