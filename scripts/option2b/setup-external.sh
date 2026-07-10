#!/usr/bin/env bash
#
# option2b/setup-external.sh — Deploy governance-test fixture proxies (~1-2 min)
#
# Creates the two Apigee pass-through proxies that test-external.sh probes:
#   cr-external-blocked  (/external-blocked → BLOCKED_RUN_URL)
#   cr-external-allowed  (/external-allowed → ALLOWED_RUN_URL)
#
# Kept separate from setup.sh so the main script owns only the perimeter
# pattern itself, and separate from test-external.sh so tests observe rather
# than provision. Idempotent AND drift-aware: if a fixture is already deployed
# but targets a different URL (env override or default change), a new revision
# is imported and deployed — a name-only existence check would silently keep
# serving the stale target.
#
# URLs come from shared/env.sh (BLOCKED_RUN_URL / ALLOWED_RUN_URL) — override
# via environment. Removal: option2b/teardown.sh Step 0.
#
# Prerequisites: Apigee provisioned (shared/setup-slow.sh).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

echo "=== Option 2b: governance-test fixtures — project: ${PROJECT_ID} ==="
echo "Blocked fixture: /external-blocked → ${BLOCKED_RUN_URL}"
echo "Allowed fixture: /external-allowed → ${ALLOWED_RUN_URL}"
echo ""

TOKEN="$(gcloud auth print-access-token)"

APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"
if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "ERROR: Apigee not provisioned — the fixtures are Apigee proxies."
  echo "Run shared/setup-slow.sh first."
  exit 1
fi

# deploy_fixture_proxy <name> <basepath> <target-url>
deploy_fixture_proxy() {
  local name="$1" basepath="$2" target_url="$3"
  echo "--- Fixture: proxy '${name}' (${basepath} → ${target_url}) ---"

  # Drift-aware skip: "a proxy with this name exists" is not enough — compare
  # the DEPLOYED revision's actual target URL (same approach as
  # shared/lib/apigee-proxy.sh).
  local deployed_rev
  deployed_rev="$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0].get('revision','') if d else '')
" 2>/dev/null || true)"

  if [[ -n "${deployed_rev}" ]]; then
    local current_target
    current_target="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${name}/revisions/${deployed_rev}?format=bundle" \
      -o "/tmp/fixture-rev-check-$$.zip" 2>/dev/null && \
      unzip -p "/tmp/fixture-rev-check-$$.zip" apiproxy/targets/default.xml 2>/dev/null || true)"
    rm -f "/tmp/fixture-rev-check-$$.zip"
    if echo "${current_target}" | grep -qF "<URL>${target_url}</URL>"; then
      echo "Deployed revision ${deployed_rev} already targets ${target_url}, skipping."
      return 0
    fi
    echo "Deployed revision ${deployed_rev} targets a different URL — updating."
  fi

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

  # No <Authentication> block: both external endpoints are public, so the
  # governance test exercises the network path in isolation (no token minting).
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

  local bundle_zip import_response new_rev
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
  new_rev="$(echo "${import_response}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))" 2>/dev/null || true)"
  if [[ -z "${new_rev}" ]]; then
    echo "ERROR: could not determine imported revision for '${name}'."
    exit 1
  fi
  echo "Proxy imported (revision ${new_rev})."

  local deploy_response
  deploy_response="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/${new_rev}/deployments?override=true")"
  if echo "${deploy_response}" | grep -q '"error"'; then
    echo "ERROR deploying fixture proxy '${name}':"
    echo "${deploy_response}" | python3 -m json.tool 2>/dev/null || echo "${deploy_response}"
    exit 1
  fi
  echo "Deployment of revision ${new_rev} started; waiting for READY..."
  local elapsed=0 state
  while true; do
    state="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/${new_rev}/deployments" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
    [[ "${state}" == "READY" ]] && { echo "Deployment READY."; break; }
    if (( elapsed >= 180 )); then
      echo "WARNING: deployment not READY after 180s (state: ${state:-unknown})."
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
echo "=== Fixtures ready ==="
echo ""
echo "Run ./scripts/option2b/test-external.sh to execute the governance test."
