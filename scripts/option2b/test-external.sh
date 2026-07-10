#!/usr/bin/env bash
#
# option2b/test-external.sh — Prove the perimeter is governable, not just closed
#
# Two out-of-perimeter Cloud Run services, opposite expectations:
#   BLOCKED_RUN_URL — no egress rule        → perimeter must DENY it
#   ALLOWED_RUN_URL — egress allow-listed   → perimeter must ADMIT it
#     (the allow-list is applied by option2b/setup.sh Step 5:
#      projects/<ALLOWED_EGRESS_PROJECT_NUMBER>, run.routes.invoke)
#
# Probes:
#   0a (control) laptop → blocked service      → expect OK (service is up)
#   0b (control) laptop → allowed service      → expect OK (service is up)
#   1  (control) Apigee → in-perimeter cr-hello → expect OK (Apigee healthy)
#   2  (subject) Apigee → BLOCKED external     → expect BLOCKED
#   3  (subject) VM     → BLOCKED external     → expect BLOCKED
#   4  (subject) Apigee → ALLOWED external     → expect OK  (egress rule works)
#   5  (subject) VM     → ALLOWED external     → expect OK
#
# "BLOCKED" is asserted on the body (the healthy pattern must NOT appear —
# the VPC-SC refusal at the run.app frontend is a plain HTML 403, not
# contractual). "ALLOWED" is asserted on HTTP 200. Leaks and lockouts both
# fail loudly; failed controls exit INCONCLUSIVE rather than false-passing.
#
# Requires: option2b/setup.sh applied (including the egress allow-list),
# Apigee provisioned. Two fixture pass-through proxies are created and
# deployed idempotently; option2b/teardown.sh removes them.
#
# Usage:
#   ./scripts/option2b/test-external.sh
#   BLOCKED_RUN_URL=https://svc-<num>.<region>.run.app/health \
#   ALLOWED_RUN_URL=https://svc2-<num>.<region>.run.app/ \
#     ./scripts/option2b/test-external.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

# A public Cloud Run service in a project with NO egress rule — must be denied.
BLOCKED_RUN_URL="${BLOCKED_RUN_URL:-${EXTERNAL_RUN_URL:-https://sandbox-manager-255182376214.europe-west2.run.app/health}}"
# A public Cloud Run service in the egress-allow-listed project — must succeed.
ALLOWED_RUN_URL="${ALLOWED_RUN_URL:-https://neukin-barn-433004719812.europe-west1.run.app/}"
BLOCKED_HEALTHY_PATTERN='"ok"'

BLOCKED_HOST="${BLOCKED_RUN_URL#https://}"; BLOCKED_HOST="${BLOCKED_HOST%%/*}"
ALLOWED_HOST="${ALLOWED_RUN_URL#https://}"; ALLOWED_HOST="${ALLOWED_HOST%%/*}"

echo "=== Testing perimeter governance: default-deny + explicit egress allow ==="
echo "Project:  ${PROJECT_ID}"
echo "Blocked:  ${BLOCKED_RUN_URL} (no egress rule)"
echo "Allowed:  ${ALLOWED_RUN_URL} (egress allow-listed)"
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
# Fixtures: pass-through proxies to both external services (idempotent)
# ============================================================
# deploy_fixture_proxy <name> <basepath> <target-url>
deploy_fixture_proxy() {
  local name="$1" basepath="$2" target_url="$3"
  echo "--- Fixture: proxy '${name}' (${basepath} → ${target_url}) ---"

  local proxy_http
  proxy_http="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${name}")"

  if [[ "${proxy_http}" == "200" ]]; then
    echo "Proxy exists, skipping import."
  else
    local bundle_dir
    bundle_dir="$(mktemp -d)"
    mkdir -p "${bundle_dir}/apiproxy/proxies" "${bundle_dir}/apiproxy/targets"

    cat > "${bundle_dir}/apiproxy/proxies/default.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPProxyConnection>
    <BasePath>${basepath}</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

    # No <Authentication> block: both external endpoints are public, so this
    # tests the network path in isolation (no token minting involved).
    cat > "${bundle_dir}/apiproxy/targets/default.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPTargetConnection>
    <URL>${target_url}</URL>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

    cat > "${bundle_dir}/apiproxy/${name}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${name}">
  <Description>Test fixture: pass-through to out-of-perimeter Cloud Run</Description>
  <BasePaths>${basepath}</BasePaths>
</APIProxy>
XMLEOF

    local bundle_zip import_response
    bundle_zip="$(mktemp).zip"
    (cd "${bundle_dir}" && zip -r "${bundle_zip}" apiproxy/) >/dev/null
    import_response="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${name}&action=import" \
      --data-binary "@${bundle_zip}")"
    rm -rf "${bundle_dir}" "${bundle_zip}"
    if echo "${import_response}" | grep -q '"error"'; then
      echo "ERROR importing fixture proxy '${name}':"
      echo "${import_response}" | python3 -m json.tool 2>/dev/null || echo "${import_response}"
      exit 1
    fi
    echo "Proxy imported (revision 1)."
  fi

  local deploy_check
  deploy_check="$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/deployments")"
  if echo "${deploy_check}" | grep -q "\"${name}\""; then
    echo "Proxy already deployed."
    return 0
  fi

  local deploy_response
  deploy_response="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/1/deployments?override=true")"
  if echo "${deploy_response}" | grep -q '"error"'; then
    echo "ERROR deploying fixture proxy '${name}':"
    echo "${deploy_response}" | python3 -m json.tool 2>/dev/null || echo "${deploy_response}"
    exit 1
  fi
  echo "Deployment started; waiting for READY..."
  local elapsed=0 state
  while true; do
    state="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/1/deployments" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
    [[ "${state}" == "READY" ]] && { echo "Deployment READY."; break; }
    if (( elapsed >= 180 )); then
      echo "WARNING: deployment not READY after 180s (state: ${state:-unknown}); probing anyway."
      break
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  sleep 10  # small settle for runtime routing
}

deploy_fixture_proxy "cr-external-blocked" "/external-blocked" "${BLOCKED_RUN_URL}"
echo ""
deploy_fixture_proxy "cr-external-allowed" "/external-allowed" "${ALLOWED_RUN_URL}"
echo ""

# ============================================================
# Probes 0a/0b (controls): laptop → both external services
# ============================================================
echo "=========================================="
echo "  Probes 0a/0b (controls): laptop → external services"
echo "=========================================="
echo "Expect OK for both — proves the services are actually up."
echo ""
echo "--- 0a: ${BLOCKED_RUN_URL} ---"
LAPTOP_BLOCKED_OUT="$(curl -s --max-time 15 "${BLOCKED_RUN_URL}" || true)"
echo "${LAPTOP_BLOCKED_OUT:-(no response)}"
if echo "${LAPTOP_BLOCKED_OUT}" | grep -qi "${BLOCKED_HEALTHY_PATTERN}"; then
  RESULT0A="PASS"
else
  RESULT0A="FAIL"
fi
echo ""
echo "--- 0b: ${ALLOWED_RUN_URL} ---"
LAPTOP_ALLOWED_CODE="$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "${ALLOWED_RUN_URL}" || echo "000")"
echo "HTTP ${LAPTOP_ALLOWED_CODE}"
if [[ "${LAPTOP_ALLOWED_CODE}" == "200" ]]; then
  RESULT0B="PASS"
else
  RESULT0B="FAIL"
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
# Probe 2 (subject): Apigee → BLOCKED external
# ============================================================
echo "=========================================="
echo "  Probe 2 (subject): Apigee → BLOCKED external"
echo "=========================================="
echo "Expect BLOCKED — no egress rule for this project."
echo ""
APIGEE_BLOCKED_OUT="$(ssh_cmd "curl -sk --max-time 20 -w '\nHTTP_STATUS:%{http_code}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}/external-blocked" || true)"
echo "${APIGEE_BLOCKED_OUT:-(no response)}"
if echo "${APIGEE_BLOCKED_OUT}" | grep -qi "${BLOCKED_HEALTHY_PATTERN}"; then
  RESULT2="LEAK"
else
  RESULT2="PASS"
fi
echo ""

# ============================================================
# Probe 3 (subject): VM → BLOCKED external directly
# ============================================================
echo "=========================================="
echo "  Probe 3 (subject): VM → BLOCKED external"
echo "=========================================="
echo "Expect BLOCKED — same perimeter, no Apigee involved."
echo ""
echo "--- DNS seen by the VM (wildcard zone should give 199.36.153.x) ---"
ssh_cmd "getent hosts ${BLOCKED_HOST}" || echo "  (resolution failed)"
echo ""
VM_BLOCKED_OUT="$(ssh_cmd "curl -s --max-time 20 -w '\nHTTP_STATUS:%{http_code}' '${BLOCKED_RUN_URL}'" || true)"
echo "${VM_BLOCKED_OUT:-(no response)}"
if echo "${VM_BLOCKED_OUT}" | grep -qi "${BLOCKED_HEALTHY_PATTERN}"; then
  RESULT3="LEAK"
else
  RESULT3="PASS"
fi
echo ""

# ============================================================
# Probe 4 (subject): Apigee → ALLOWED external
# ============================================================
echo "=========================================="
echo "  Probe 4 (subject): Apigee → ALLOWED external"
echo "=========================================="
echo "Expect OK — the egress allow-list admits this project."
echo ""
APIGEE_ALLOWED_OUT="$(ssh_cmd "curl -sk --max-time 20 -w '\nHTTP_STATUS:%{http_code}' -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}/external-allowed" || true)"
echo "${APIGEE_ALLOWED_OUT:-(no response)}"
if echo "${APIGEE_ALLOWED_OUT}" | grep -q "HTTP_STATUS:200"; then
  RESULT4="PASS"
else
  RESULT4="FAIL"
fi
echo ""

# ============================================================
# Probe 5 (subject): VM → ALLOWED external directly
# ============================================================
echo "=========================================="
echo "  Probe 5 (subject): VM → ALLOWED external"
echo "=========================================="
echo "Expect OK — same egress rule, no Apigee involved."
echo ""
echo "--- DNS seen by the VM (wildcard zone should give 199.36.153.x) ---"
ssh_cmd "getent hosts ${ALLOWED_HOST}" || echo "  (resolution failed)"
echo ""
VM_ALLOWED_OUT="$(ssh_cmd "curl -s --max-time 20 -w '\nHTTP_STATUS:%{http_code}' '${ALLOWED_RUN_URL}'" || true)"
echo "${VM_ALLOWED_OUT:-(no response)}"
if echo "${VM_ALLOWED_OUT}" | grep -q "HTTP_STATUS:200"; then
  RESULT5="PASS"
else
  RESULT5="FAIL"
fi
echo ""

# ============================================================
# Summary
# ============================================================
echo "=== Test results ==="
echo ""
echo "Probe 0a [${RESULT0A}]  control: laptop → blocked-list service (expect OK)"
echo "Probe 0b [${RESULT0B}]  control: laptop → allow-list service (expect OK)"
echo "Probe 1  [${RESULT1}]  control: Apigee → in-perimeter cr-hello (expect OK)"
echo "Probe 2  [${RESULT2}]  Apigee → BLOCKED external (expect BLOCKED)"
echo "Probe 3  [${RESULT3}]  VM → BLOCKED external (expect BLOCKED)"
echo "Probe 4  [${RESULT4}]  Apigee → ALLOWED external (expect OK)"
echo "Probe 5  [${RESULT5}]  VM → ALLOWED external (expect OK)"
echo ""
if [[ "${RESULT2}" == "LEAK" || "${RESULT3}" == "LEAK" ]]; then
  echo "FAIL: a non-allow-listed external service was reachable from inside the"
  echo "perimeter — the lockdown is NOT containing Cloud Run egress."
  exit 1
elif [[ "${RESULT0A}" == "FAIL" || "${RESULT0B}" == "FAIL" ]]; then
  echo "INCONCLUSIVE: an external service was unreachable from the laptop too —"
  echo "verify both services are up and re-run."
  exit 1
elif [[ "${RESULT1}" == "FAIL" ]]; then
  echo "INCONCLUSIVE: Apigee could not reach the IN-perimeter service either,"
  echo "so blocked results may just mean Apigee southbound is broken."
  exit 1
elif [[ "${RESULT4}" == "FAIL" || "${RESULT5}" == "FAIL" ]]; then
  echo "FAIL: the allow-listed service was NOT reachable from inside the"
  echo "perimeter. Check option2b/setup.sh applied the egress allow-list"
  echo "(Step 5) and allow a few minutes for the perimeter change to"
  echo "propagate — then re-run."
  exit 1
else
  echo "PROVEN: the perimeter is governable — Cloud Run egress is denied by"
  echo "default and admitted ONLY where the egress allow-list names the"
  echo "target project. Apigee and the VM behave identically."
fi
