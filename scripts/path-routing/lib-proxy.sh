#!/usr/bin/env bash
#
# lib-proxy.sh — Apigee proxy bundle authoring + deploy helpers for the
# path-routing PoC (issue #62). Source after shared/env.sh + helpers.sh.
#
# Every proxy built here sets an X-Served-By response header naming the
# proxy — the tests must distinguish WHICH proxy answered, and the target
# service's echo alone cannot (pre/post carve-out both land on the same
# Cloud Run service).
#

apigee_token() {
  gcloud auth print-access-token
}

# write_bundle_common <dir> <proxy-name> <base-path>
# Writes the APIProxy metadata + the X-Served-By AssignMessage policy.
write_bundle_common() {
  local dir="$1" name="$2" base_path="$3"
  mkdir -p "${dir}/apiproxy/proxies" "${dir}/apiproxy/targets" "${dir}/apiproxy/policies"

  cat > "${dir}/apiproxy/${name}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${name}">
  <Description>Path-routing PoC (#62): ${base_path}</Description>
  <BasePaths>${base_path}</BasePaths>
</APIProxy>
XMLEOF

  cat > "${dir}/apiproxy/policies/AM-ServedBy.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<AssignMessage continueOnError="false" enabled="true" name="AM-ServedBy">
  <Set>
    <Headers>
      <Header name="X-Served-By">${name}</Header>
    </Headers>
  </Set>
  <IgnoreUnresolvedVariables>true</IgnoreUnresolvedVariables>
  <AssignTo createNew="false" transport="http" type="response"/>
</AssignMessage>
XMLEOF
}

# write_target <dir> <endpoint-name> <target-url>
# GoogleIDToken audience = service URL (scenario A in the design doc §4).
write_target() {
  local dir="$1" endpoint="$2" url="$3"
  cat > "${dir}/apiproxy/targets/${endpoint}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="${endpoint}">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPTargetConnection>
    <URL>${url}</URL>
    <Authentication>
      <GoogleIDToken>
        <Audience>${url}</Audience>
      </GoogleIDToken>
    </Authentication>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF
}

# write_proxy_endpoint <dir> <base-path> <route-rules-xml>
# route-rules-xml: pre-rendered <RouteRule> block(s), conditional rules
# FIRST (route rules evaluate in order; the unconditional default last).
write_proxy_endpoint() {
  local dir="$1" base_path="$2" route_rules="$3"
  cat > "${dir}/apiproxy/proxies/default.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <Flows/>
  <PostFlow name="PostFlow">
    <Request/>
    <Response>
      <Step><Name>AM-ServedBy</Name></Step>
    </Response>
  </PostFlow>
  <HTTPProxyConnection>
    <BasePath>${base_path}</BasePath>
  </HTTPProxyConnection>
${route_rules}
</ProxyEndpoint>
XMLEOF
}

# import_proxy <name> <bundle-dir> → echoes new revision (empty on error)
# Prints the API error to stderr on failure.
import_proxy() {
  local name="$1" dir="$2"
  local zip_file response rev
  zip_file="$(mktemp).zip"
  (cd "${dir}" && zip -qr "${zip_file}" apiproxy/)
  response="$(curl -s -X POST \
    -H "Authorization: Bearer $(apigee_token)" \
    -H "Content-Type: application/octet-stream" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${name}&action=import" \
    --data-binary "@${zip_file}")"
  rm -f "${zip_file}"
  if echo "${response}" | grep -q '"error"'; then
    echo "${response}" >&2
    return 1
  fi
  rev="$(echo "${response}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))")"
  echo "${rev}"
}

# deploy_proxy <name> <revision> → echoes raw deploy response; returns
# non-zero if the response is an error (caller captures both — the conflict
# test WANTS the error body).
deploy_proxy() {
  local name="$1" rev="$2"
  local response
  response="$(curl -s -X POST \
    -H "Authorization: Bearer $(apigee_token)" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/${rev}/deployments?override=true&serviceAccount=${SA_EMAIL}")"
  echo "${response}"
  ! echo "${response}" | grep -q '"error"'
}

# wait_deployment_ready <name> <revision> — polls until state READY
wait_deployment_ready() {
  local name="$1" rev="$2"
  local state
  for _ in $(seq 1 60); do
    state="$(curl -s -H "Authorization: Bearer $(apigee_token)" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/${rev}/deployments" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
    if [[ "${state}" == "READY" ]]; then
      echo "  '${name}' rev ${rev} READY."
      return 0
    fi
    sleep 5
  done
  echo "  WARNING: '${name}' rev ${rev} not READY after 300s (state: ${state:-unknown})."
  return 1
}

# undeploy_and_delete_proxy <name> — idempotent, silent on absence
undeploy_and_delete_proxy() {
  local name="$1"
  local rev
  rev="$(curl -s -H "Authorization: Bearer $(apigee_token)" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0]['revision'] if d else '')" 2>/dev/null || true)"
  if [[ -n "${rev}" ]]; then
    curl -s -X DELETE -H "Authorization: Bearer $(apigee_token)" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${name}/revisions/${rev}/deployments" > /dev/null
    echo "  '${name}' rev ${rev} undeployed."
  fi
  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $(apigee_token)" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${name}")"
  if [[ "${http_code}" == "200" ]]; then
    echo "  '${name}' deleted."
  elif [[ "${http_code}" != "404" ]]; then
    echo "  WARNING: deleting '${name}' returned HTTP ${http_code}."
  fi
}

# build_cards_bundle <dir> <with_issuing:true|false> <cards-url> <issuing-url>
# The /payments/cards proxy: with_issuing=true is the §3 start state
# (issuing served via a conditional route INSIDE this proxy); false is the
# post-carve-out state (issuing route removed, dedicated proxy owns it).
build_cards_bundle() {
  local dir="$1" with_issuing="$2" cards_url="$3" issuing_url="$4"
  write_bundle_common "${dir}" "${PROXY_CARDS}" "/payments/cards"
  write_target "${dir}" "cards" "${cards_url}"
  local rules
  if [[ "${with_issuing}" == "true" ]]; then
    write_target "${dir}" "issuing" "${issuing_url}"
    rules='  <RouteRule name="issuing">
    <Condition>(proxy.pathsuffix MatchesPath "/issuing/**")</Condition>
    <TargetEndpoint>issuing</TargetEndpoint>
  </RouteRule>
  <RouteRule name="default">
    <TargetEndpoint>cards</TargetEndpoint>
  </RouteRule>'
  else
    rules='  <RouteRule name="default">
    <TargetEndpoint>cards</TargetEndpoint>
  </RouteRule>'
  fi
  write_proxy_endpoint "${dir}" "/payments/cards" "${rules}"
}

# build_single_bundle <dir> <proxy-name> <base-path> <target-url>
build_single_bundle() {
  local dir="$1" name="$2" base_path="$3" url="$4"
  write_bundle_common "${dir}" "${name}" "${base_path}"
  write_target "${dir}" "default" "${url}"
  write_proxy_endpoint "${dir}" "${base_path}" '  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>'
}
