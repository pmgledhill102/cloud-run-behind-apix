#!/usr/bin/env bash
#
# apigee-proxy.sh — Update Apigee proxy target URL
#
# Silently skips if Apigee is not provisioned.
#
# Source this after env.sh + helpers.sh:
#   source "${SHARED_DIR}/lib/apigee-proxy.sh"
#
# Usage:
#   update_apigee_proxy_target "https://target-url/" [--ssl-ignore] [--audience=URL]
#

update_apigee_proxy_target() {
  local target_url="$1"
  shift
  local ssl_ignore=""
  local audience=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssl-ignore) ssl_ignore="true"; shift ;;
      --audience=*) audience="${1#--audience=}"; shift ;;
      --audience) audience="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  echo "--- Update Apigee proxy target ---"

  local TOKEN
  TOKEN="$(gcloud auth print-access-token)"
  local APIGEE_HTTP
  APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}")"

  if [[ "${APIGEE_HTTP}" != "200" ]]; then
    echo "Apigee not provisioned (HTTP ${APIGEE_HTTP}), skipping proxy update."
    return 0
  fi

  # Check if proxy target is already correct
  local DEPLOYED_REV
  DEPLOYED_REV="$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/deployments" \
    | python3 -c "
import sys,json
data = json.load(sys.stdin)
deploys = data.get('deployments', [])
if deploys:
    print(deploys[0].get('revision',''))
" 2>/dev/null || true)"

  local NEEDS_UPDATE=true
  if [[ -n "${DEPLOYED_REV}" ]]; then
    local CURRENT_TARGET
    CURRENT_TARGET="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${PROXY_NAME}/revisions/${DEPLOYED_REV}?format=bundle" \
      -o /tmp/apigee-rev-check.zip 2>/dev/null && \
      unzip -p /tmp/apigee-rev-check.zip apiproxy/targets/default.xml 2>/dev/null || true)"
    rm -f /tmp/apigee-rev-check.zip
    local URL_MATCH=false
    local AUTH_MATCH=false
    echo "${CURRENT_TARGET}" | grep -q "${target_url}" && URL_MATCH=true
    if [[ -n "${audience}" ]]; then
      echo "${CURRENT_TARGET}" | grep -q "<Audience>${audience}</Audience>" && AUTH_MATCH=true
    else
      # No audience requested — match if none is configured
      echo "${CURRENT_TARGET}" | grep -q "<GoogleIDToken>" || AUTH_MATCH=true
    fi
    if [[ "${URL_MATCH}" == "true" && "${AUTH_MATCH}" == "true" ]]; then
      echo "Proxy target already set to ${target_url} (auth: ${audience:-none}), skipping."
      NEEDS_UPDATE=false
    fi
  fi

  if [[ "${NEEDS_UPDATE}" == "true" ]]; then
    echo "Updating proxy '${PROXY_NAME}' target to ${target_url}..."

    local BUNDLE_DIR
    BUNDLE_DIR="$(mktemp -d)"
    mkdir -p "${BUNDLE_DIR}/apiproxy/proxies"
    mkdir -p "${BUNDLE_DIR}/apiproxy/targets"
    mkdir -p "${BUNDLE_DIR}/apiproxy/policies"

    cat > "${BUNDLE_DIR}/apiproxy/proxies/default.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request/>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow">
    <Request/>
    <Response/>
  </PostFlow>
  <HTTPProxyConnection>
    <BasePath>/hello</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

    # Build target endpoint XML with optional SSL ignore and auth
    local SSL_BLOCK=""
    if [[ "${ssl_ignore}" == "true" ]]; then
      SSL_BLOCK="
    <SSLInfo>
      <Enabled>true</Enabled>
      <IgnoreValidationErrors>true</IgnoreValidationErrors>
    </SSLInfo>"
    fi

    local AUTH_BLOCK=""
    if [[ -n "${audience}" ]]; then
      AUTH_BLOCK="
    <Authentication>
      <GoogleIDToken>
        <Audience>${audience}</Audience>
      </GoogleIDToken>
    </Authentication>"
    fi

    cat > "${BUNDLE_DIR}/apiproxy/targets/default.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request/>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow">
    <Request/>
    <Response/>
  </PostFlow>
  <HTTPTargetConnection>
    <URL>${target_url}</URL>${SSL_BLOCK}${AUTH_BLOCK}
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

    cat > "${BUNDLE_DIR}/apiproxy/${PROXY_NAME}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${PROXY_NAME}">
  <Description>Pass-through proxy to Cloud Run cr-hello service</Description>
  <BasePaths>/hello</BasePaths>
</APIProxy>
XMLEOF

    local BUNDLE_ZIP
    BUNDLE_ZIP="$(mktemp).zip"
    (cd "${BUNDLE_DIR}" && zip -r "${BUNDLE_ZIP}" apiproxy/) >/dev/null

    local IMPORT_RESPONSE
    IMPORT_RESPONSE="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${PROXY_NAME}&action=import" \
      --data-binary "@${BUNDLE_ZIP}")"

    rm -rf "${BUNDLE_DIR}" "${BUNDLE_ZIP}"

    if echo "${IMPORT_RESPONSE}" | grep -q '"error"'; then
      echo "ERROR importing proxy revision:"
      echo "${IMPORT_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${IMPORT_RESPONSE}"
      return 1
    fi

    local NEW_REV
    NEW_REV="$(echo "${IMPORT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))" 2>/dev/null || true)"
    echo "Imported revision ${NEW_REV}."

    local DEPLOY_RESPONSE
    DEPLOY_RESPONSE="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/${NEW_REV}/deployments?override=true")"

    if echo "${DEPLOY_RESPONSE}" | grep -q '"error"'; then
      echo "ERROR deploying revision ${NEW_REV}:"
      echo "${DEPLOY_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${DEPLOY_RESPONSE}"
      return 1
    fi

    echo "Revision ${NEW_REV} deployed to '${APIGEE_ENV}'."
  fi
}
