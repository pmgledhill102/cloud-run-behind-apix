#!/usr/bin/env bash
#
# experiment-ip-target.sh — can Apigee reach Cloud Run by targeting the
# restricted VIP as an IP literal, if the request carries Google auth headers?
#
# WHY THIS EXISTS
# ---------------
# docs/option-b-vpcsc-field-notes.md §4.1 records one ad hoc test (2026-09-04):
# a target of `https://199.36.153.5/` with an AssignMessage-set Host header got
#
#     403 "The service you are trying to access is not available on Google's
#          Restricted VIPs"
#
# and concluded that the front end selects the backend from TLS SNI, so an IP
# literal cannot work and the peered DNS domain is load-bearing. That test left
# no transcript, and it did not record two things a reader needs:
#
#   1. whether the target carried <Authentication><GoogleIDToken>, and
#   2. whether Host was the run.app hostname or — as the shared helper derives
#      it from the target URL — the IP itself.
#
# A Google support engineer has since said the failure was ONLY because the
# request lacked Google auth headers (proposing GoogleIDToken + IncludeEmail
# with the run.app audience), and separately that an IP target cannot work
# because Apigee checks the certificate path. This script measures both claims
# rather than arguing about them.
#
# HOW IT DISCRIMINATES
# --------------------
# One pass-through proxy per variant. Four target the IP literal and differ in
# exactly one thing each; two target the run.app hostname as controls:
#
#   ip-hostrun-auth           Host=run.app  ignore-cert  GoogleIDToken+IncludeEmail
#                             — the engineer's exact proposal
#   ip-hostrun-noauth         Host=run.app  ignore-cert  no auth
#                             — does the auth header change the front end's verdict?
#   ip-hostip-auth            Host=<the IP> ignore-cert  GoogleIDToken+IncludeEmail
#                             — what update_apigee_proxy_target would have sent
#   ip-hostrun-auth-validate  Host=run.app  VALIDATE     GoogleIDToken+IncludeEmail
#                             — the "Apigee checks the cert path" claim
#   dns-auth        (control) URL=run.app               GoogleIDToken+IncludeEmail
#                             — proves auth + IAM work on this stack (expect 200)
#   dns-noauth      (control) URL=run.app               no auth
#                             — the Cloud Run IAM 403 signature, for comparison
#
# Reading the outcomes:
#   - A 403 body saying "not available on Google's Restricted VIPs" is emitted
#     by the front end before any Cloud Run service is selected. If
#     ip-hostrun-auth still gets it while dns-auth gets 200, the auth header
#     is not what was missing.
#   - A Cloud Run IAM rejection says "The request was not authenticated ...
#     Empty Authorization header value" (auth-poc-field-notes §7.6). If any IP
#     variant gets THAT, the front end did route on Host and auth is the
#     remaining problem — the engineer would be right.
#   - Any HTTP body at all means the TLS handshake completed. A certificate
#     rejection by Apigee shows up as a 503 with tlsHandshakeStatus != COMPLETED
#     and no body. ip-hostrun-auth-validate measures whether that happens.
#   - With TRACE=1 the debug session records tlsHandshakeStatus,
#     resolvedAddress, and the headers on the request Apigee actually sent to
#     the target — so "was Host really the run.app name?" is answered from the
#     wire, not from the policy XML.
#
# NOTE on the auth header in traces: Apigee attaches the GoogleIDToken at
# send time and does not always surface it in the debug session's target
# RequestMessage. The dns-auth control (200 through an IAM-closed service) is
# the proof the token was sent; the trace's Authorization line is corroboration
# when present, not the primary evidence.
#
# Usage:
#   PROJECT_ID=<p> ./scripts/option2b/experiment-ip-target.sh run       # default
#   PROJECT_ID=<p> ./scripts/option2b/experiment-ip-target.sh cleanup   # remove the probe proxies
#
#   TRACE=1        capture a debug session per variant (~90 s each)
#   VIP_IP=...     which restricted-VIP address to target (default 199.36.153.5)
#   EVIDENCE_DIR=docs/repro/evidence EVIDENCE_REDACT=1   write a transcript
#
# Prerequisites: shared/setup-base.sh, shared/setup-slow.sh, option2/setup.sh
# (the run.app zone in apigee-vpc pointing at the restricted VIP). option2b is
# optional — the script records whether VPC-SC is enabled on the peering so a
# reader can tell which state the transcript came from.
#
set -euo pipefail

PHASE="${1:-run}"
case "${PHASE}" in
  run|cleanup) ;;
  *) echo "Usage: $0 {run|cleanup}" >&2; exit 2 ;;
esac

source "$(dirname "${BASH_SOURCE[0]}")/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

VIP_IP="${VIP_IP:-199.36.153.5}"

# ------------------------------------------------------------
# Evidence capture (same contract as experiment-vpcsc-dns-scope.sh)
# ------------------------------------------------------------
if [[ -n "${EVIDENCE_DIR:-}" && -z "${_EVIDENCE_REEXEC:-}" ]]; then
  mkdir -p "${EVIDENCE_DIR}"
  _stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  EVIDENCE_TRANSCRIPT="${EVIDENCE_DIR}/${_stamp}-iptarget-${PHASE}.log"
  export _EVIDENCE_REEXEC=1 EVIDENCE_TRANSCRIPT EVIDENCE_STAMP="${_stamp}"
  if [[ -n "${EVIDENCE_REDACT:-}" ]]; then
    _num="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
    _sed=(-e "s/${PROJECT_ID}/<PROJECT_ID>/g")
    [[ -n "${_num}" ]] && _sed+=(-e "s/${_num}/<PROJECT_NUMBER>/g")
    "${BASH_SOURCE[0]}" ${@+"$@"} 2>&1 | sed "${_sed[@]}" | tee "${EVIDENCE_TRANSCRIPT}"
  else
    "${BASH_SOURCE[0]}" ${@+"$@"} 2>&1 | tee "${EVIDENCE_TRANSCRIPT}"
  fi
  exit "${PIPESTATUS[0]}"
fi

TOKEN="$(gcloud auth print-access-token)"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"

SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"
if [[ -z "${SERVICE_URL}" ]]; then
  echo "ERROR: Cloud Run service 'cr-hello' not found. Run shared/setup-base.sh." >&2
  exit 1
fi
SERVICE_HOST="${SERVICE_URL#https://}"

INSTANCE_IP="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"
if [[ -z "${INSTANCE_IP}" ]]; then
  echo "ERROR: Apigee instance '${INSTANCE_NAME}' not ACTIVE. Run shared/setup-slow.sh." >&2
  exit 1
fi

# ------------------------------------------------------------
# The variant table
# ------------------------------------------------------------
# name|basepath|target-url|host-header|ssl-mode|auth|what it isolates
#   ssl-mode: ignore   — <IgnoreValidationErrors>true</IgnoreValidationErrors>
#             validate — <IgnoreValidationErrors>false</IgnoreValidationErrors>
#             default  — no <SSLInfo> block at all (the hostname controls)
#   auth:     idtoken  — <GoogleIDToken><Audience>SERVICE_URL</Audience><IncludeEmail>true</IncludeEmail>
#             none     — no <Authentication> block
VARIANTS="$(cat <<EOF
ip-hostrun-auth|/ipt-hostrun-auth|https://${VIP_IP}/|${SERVICE_HOST}|ignore|idtoken|the engineer's proposal: IP + run.app Host + GoogleIDToken
ip-hostrun-noauth|/ipt-hostrun-noauth|https://${VIP_IP}/|${SERVICE_HOST}|ignore|none|same, minus auth — does the header change the verdict?
ip-hostip-auth|/ipt-hostip-auth|https://${VIP_IP}/|${VIP_IP}|ignore|idtoken|what the shared helper would have sent (Host = the IP)
ip-hostrun-auth-validate|/ipt-hostrun-validate|https://${VIP_IP}/|${SERVICE_HOST}|validate|idtoken|the "Apigee checks the cert path" claim
dns-auth|/ipt-dns-auth|${SERVICE_URL}/|${SERVICE_HOST}|default|idtoken|CONTROL: auth + IAM work here (expect 200)
dns-noauth|/ipt-dns-noauth|${SERVICE_URL}/|${SERVICE_HOST}|default|none|CONTROL: the Cloud Run IAM 403 signature
EOF
)"

echo "=========================================================="
echo "  IP-literal restricted-VIP target — auth, cert, Host isolated"
echo "=========================================================="
echo "Project:        ${PROJECT_ID}"
echo "Phase:          ${PHASE}"
echo "Cloud Run:      ${SERVICE_URL}"
echo "VIP target:     https://${VIP_IP}/"
echo "Apigee runtime: ${INSTANCE_IP}"
echo "Deploy SA:      ${SA_EMAIL}"
echo "Run at:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

vpcsc_state() {
  curl -s -H "Authorization: Bearer ${TOKEN}" \
    "https://servicenetworking.googleapis.com/v1/services/servicenetworking.googleapis.com/projects/${PROJECT_NUMBER}/global/networks/${APIGEE_NETWORK}/vpcServiceControls" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('enabled','?'))" 2>/dev/null || echo "?"
}

echo "enable-vpc-service-controls on the peering: $(vpcsc_state)"
echo "Cloud Run ingress/auth: $(gcloud run services describe cr-hello --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(metadata.annotations."run.googleapis.com/ingress")' 2>/dev/null || echo '?'), IAM-closed (setup-base deploys --no-allow-unauthenticated)"
echo ""

deployed_revision() {
  local proxy="$1"
  curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0].get('revision','') if d else '')
" 2>/dev/null || true
}

# ------------------------------------------------------------
# Phase: cleanup
# ------------------------------------------------------------
if [[ "${PHASE}" == "cleanup" ]]; then
  echo "--- Removing probe proxies ---"
  while IFS='|' read -r vname basepath target host ssl auth what; do
    [[ -n "${vname}" ]] || continue
    proxy="ipt-${vname}"
    rev="$(deployed_revision "${proxy}")"
    if [[ -n "${rev}" ]]; then
      curl -s -X DELETE -H "Authorization: Bearer ${TOKEN}" \
        "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/revisions/${rev}/deployments" >/dev/null
      echo "  ${proxy}: undeployed rev ${rev}"
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${proxy}")"
    echo "  ${proxy}: delete -> HTTP ${code}"
  done <<< "${VARIANTS}"
  exit 0
fi

# ------------------------------------------------------------
# Fixture: one proxy per variant
# ------------------------------------------------------------
ensure_variant_proxy() {
  local vname="$1" basepath="$2" target="$3" host="$4" ssl="$5" auth="$6"
  local proxy="ipt-${vname}"

  local rev
  rev="$(deployed_revision "${proxy}")"
  if [[ -n "${rev}" && "${FORCE_PROXY_UPDATE:-}" != "true" ]]; then
    echo "  ${proxy}: already deployed (rev ${rev})"
    return 0
  fi

  local bundle_dir
  bundle_dir="$(mktemp -d)"
  mkdir -p "${bundle_dir}/apiproxy/proxies" \
           "${bundle_dir}/apiproxy/targets" \
           "${bundle_dir}/apiproxy/policies"

  cat > "${bundle_dir}/apiproxy/policies/SetHostHeader.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<AssignMessage name="SetHostHeader">
  <Set>
    <Headers>
      <Header name="Host">${host}</Header>
    </Headers>
  </Set>
</AssignMessage>
XMLEOF

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

  local ssl_block=""
  case "${ssl}" in
    ignore)
      ssl_block="
    <SSLInfo>
      <Enabled>true</Enabled>
      <IgnoreValidationErrors>true</IgnoreValidationErrors>
    </SSLInfo>" ;;
    validate)
      ssl_block="
    <SSLInfo>
      <Enabled>true</Enabled>
      <IgnoreValidationErrors>false</IgnoreValidationErrors>
    </SSLInfo>" ;;
    default) ssl_block="" ;;
  esac

  # The engineer's snippet, verbatim in shape: audience = the run.app URL,
  # IncludeEmail on.
  local auth_block=""
  if [[ "${auth}" == "idtoken" ]]; then
    auth_block="
    <Authentication>
      <GoogleIDToken>
        <Audience>${SERVICE_URL}</Audience>
        <IncludeEmail>true</IncludeEmail>
      </GoogleIDToken>
    </Authentication>"
  fi

  cat > "${bundle_dir}/apiproxy/targets/default.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request><Step><Name>SetHostHeader</Name></Step></Request>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPTargetConnection>
    <URL>${target}</URL>${ssl_block}${auth_block}
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

  cat > "${bundle_dir}/apiproxy/${proxy}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${proxy}">
  <Description>IP-target probe ${vname}: ${target} Host=${host} ssl=${ssl} auth=${auth}</Description>
  <BasePaths>${basepath}</BasePaths>
</APIProxy>
XMLEOF

  echo "  ${proxy}: target XML as deployed:"
  sed 's/^/      | /' "${bundle_dir}/apiproxy/targets/default.xml" | grep -E 'URL|SSLInfo|IgnoreValidation|Audience|IncludeEmail' || true
  echo "      | Host header set by SetHostHeader: ${host}"

  local bundle_zip import_response new_rev
  bundle_zip="$(mktemp).zip"
  (cd "${bundle_dir}" && zip -r "${bundle_zip}" apiproxy/) >/dev/null
  import_response="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${proxy}&action=import" \
    --data-binary "@${bundle_zip}")"
  rm -rf "${bundle_dir}" "${bundle_zip}"
  if echo "${import_response}" | grep -q '"error"'; then
    echo "  ERROR importing ${proxy}:"
    echo "${import_response}" | python3 -m json.tool 2>/dev/null || echo "${import_response}"
    return 1
  fi
  new_rev="$(echo "${import_response}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))" 2>/dev/null || true)"

  # A target with <Authentication> must be deployed with a service account
  # identity (MISSING_SERVICE_ACCOUNT otherwise) — Apigee mints the ID token
  # as that SA. Deploy every variant the same way so the SA is not a variable.
  local deploy_response
  deploy_response="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/revisions/${new_rev}/deployments?override=true&serviceAccount=${SA_EMAIL}")"
  if echo "${deploy_response}" | grep -q '"error"'; then
    echo "  ERROR deploying ${proxy}:"
    echo "${deploy_response}" | python3 -m json.tool 2>/dev/null || echo "${deploy_response}"
    return 1
  fi

  local elapsed=0 state
  while true; do
    state="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/revisions/${new_rev}/deployments" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
    [[ "${state}" == "READY" ]] && break
    if (( elapsed >= 180 )); then
      echo "  WARNING: ${proxy} not READY after 180s (state ${state:-unknown})"
      break
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  echo "  ${proxy}: deployed rev ${new_rev}"
}

# ------------------------------------------------------------
# Probe: run from the VM against the Apigee runtime IP
# ------------------------------------------------------------
# Returns "<http_code>|<seconds>|<first 300 bytes of body>"
apigee_probe() {
  local basepath="$1"
  ssh_cmd "curl -sk --max-time 20 -o /tmp/ipt-body -w '%{http_code}|%{time_total}' \
    -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}${basepath} ; \
    echo -n '|' ; head -c 300 /tmp/ipt-body | tr '\n' ' '" 2>/dev/null || echo "SSH-FAILED||"
}

classify() {
  local code="$1" body="$2"
  if echo "${body}" | grep -q 'TARGET_CONNECT_TIMEOUT'; then
    echo "NO SOCKET"
  elif echo "${body}" | grep -qi 'not available on Google.s Restricted VIPs'; then
    echo "FRONT-END REJECT (restricted-VIP 403)"
  elif echo "${body}" | grep -qi 'request was not authenticated\|Authorization header'; then
    echo "CLOUD RUN IAM ${code}"
  elif echo "${body}" | grep -qi 'requested URL.*was not found\|Page not found'; then
    echo "FRONT-END 404 (Host not routed)"
  elif echo "${body}" | grep -qiE 'SSL|TLS|handshake|certificate'; then
    echo "TLS FAILURE ${code}"
  elif [[ "${code}" == "000" || -z "${code}" || "${code}" == "SSH-FAILED" ]]; then
    echo "PROBE FAILED"
  else
    echo "HTTP ${code}"
  fi
}

# ------------------------------------------------------------
# Optional trace: what did Apigee actually put on the wire?
# ------------------------------------------------------------
trace_variant() {
  local vname="$1" basepath="$2"
  local proxy="ipt-${vname}"
  local rev
  rev="$(deployed_revision "${proxy}")"
  [[ -n "${rev}" ]] || { echo "      (no deployed revision; no trace)"; return 0; }

  local session
  session="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/revisions/${rev}/debugsessions?timeout=300" \
    -d '{}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)"
  [[ -n "${session}" ]] || { echo "      (could not create debug session)"; return 0; }

  sleep 75
  apigee_probe "${basepath}" >/dev/null || true
  sleep 15

  local txn
  txn="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/revisions/${rev}/debugsessions/${session}/data" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin)
v = d if isinstance(d, list) else (d.get('responses') or d.get('data') or [])
print(v[0] if v and isinstance(v[0], str) else '')
" 2>/dev/null || true)"
  [[ -n "${txn}" ]] || { echo "      (no transaction captured)"; return 0; }

  curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/revisions/${rev}/debugsessions/${session}/data/${txn}" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
want = ('resolvedAddress', 'connectionStatus', 'tlsHandshakeStatus', 'error.class',
        'target.url', 'target.host', 'error.message', 'fault.name')
found = {}
requests, responses = [], []
SENSITIVE = ('authorization', 'x-serverless-authorization')
def hdrs(lst):
    out = []
    for h in lst or []:
        n, v = h.get('name',''), h.get('value','')
        if n.lower() in SENSITIVE:
            out.append(f'{n}: <present, {len(v)} chars>')
        elif n.lower() in ('host', 'x-forwarded-for', 'content-type', 'user-agent', 'x-forwarded-proto'):
            out.append(f'{n}: {v}')
    return out
def walk(o):
    if isinstance(o, dict):
        n, v = o.get('name'), o.get('value')
        if isinstance(n, str) and any(n.endswith(w) for w in want):
            found.setdefault(n, v)
        ar = o.get('ActionResult')
        if ar == 'RequestMessage':
            requests.append((o.get('verb',''), o.get('uRI',''), hdrs(o.get('headers'))))
        elif ar == 'ResponseMessage':
            responses.append((o.get('statusCode',''), o.get('reasonPhrase',''),
                              hdrs(o.get('headers')), (o.get('content') or '')[:200].replace('\n',' ')))
        for x in o.values():
            walk(x)
    elif isinstance(o, list):
        for x in o:
            walk(x)
walk(d)
for k in sorted(found):
    print(f'      {k} = {found[k]}')
if not any(k.endswith('resolvedAddress') for k in found):
    print('      resolvedAddress: ABSENT — no socket was ever created')
print('      request messages on the wire (client-side first, target-side after):')
for verb, uri, hs in requests:
    print(f'        {verb} {uri}')
    for h in hs:
        print(f'          {h}')
print('      response messages:')
for code, reason, hs, body in responses:
    print(f'        {code} {reason}')
    for h in hs:
        print(f'          {h}')
    if body:
        print(f'          body: {body}')
" 2>/dev/null || echo "      (could not parse trace)"
}

# ------------------------------------------------------------
# Fixtures, then probes
# ------------------------------------------------------------
echo "--- Fixtures: one proxy per variant (all deployed as ${SA_EMAIL}) ---"
while IFS='|' read -r vname basepath target host ssl auth what; do
  [[ -n "${vname}" ]] || continue
  ensure_variant_proxy "${vname}" "${basepath}" "${target}" "${host}" "${ssl}" "${auth}"
done <<< "${VARIANTS}"
echo ""
sleep 10

echo "=========================================================="
echo "  RESULTS — VPC-SC enabled=$(vpcsc_state)"
echo "=========================================================="
printf '%-26s %-16s %-8s %-8s %-38s %s\n' "VARIANT" "HOST HEADER" "CERT" "AUTH" "VERDICT" "BODY (first 120)"
printf '%-26s %-16s %-8s %-8s %-38s %s\n' "-------" "-----------" "----" "----" "-------" "----------------"

while IFS='|' read -r vname basepath target host ssl auth what; do
  [[ -n "${vname}" ]] || continue
  out="$(apigee_probe "${basepath}")"
  code="$(echo "${out}" | head -1 | cut -d'|' -f1)"
  secs="$(echo "${out}" | head -1 | cut -d'|' -f2)"
  body="$(echo "${out}" | cut -d'|' -f3-)"
  verdict="$(classify "${code}" "${body}") (${secs}s)"
  hostshow="${host}"; [[ "${host}" == "${SERVICE_HOST}" ]] && hostshow="run.app name"
  printf '%-26s %-16s %-8s %-8s %-38s %s\n' "${vname}" "${hostshow}" "${ssl}" "${auth}" "${verdict}" "${body:0:120}"
done <<< "${VARIANTS}"
echo ""

if [[ "${TRACE:-}" == "1" ]]; then
  echo "--- TRACE: per-variant debug session (what Apigee put on the wire) ---"
  echo "    tlsHandshakeStatus=COMPLETED  = the certificate did not stop the request"
  echo "    resolvedAddress               = the IP the tenant actually connected to"
  echo "    target-side request Host      = the Host header as sent, not as configured"
  echo ""
  while IFS='|' read -r vname basepath target host ssl auth what; do
    [[ -n "${vname}" ]] || continue
    echo "  ${vname} (${what}):"
    trace_variant "${vname}" "${basepath}"
    echo ""
  done <<< "${VARIANTS}"
fi

echo "--- VM control: what THIS VPC resolves for the service ---"
ssh_cmd "echo -n '  ${SERVICE_HOST} -> '; getent hosts ${SERVICE_HOST} | awk '{print \$1}' | tr '\n' ' '; echo" \
  2>/dev/null || echo "  (VM probe failed)"
echo ""

echo "=========================================================="
echo "  How to read this"
echo "=========================================================="
cat <<'EOF'
  The controls first. dns-auth must be HTTP 200: that proves the GoogleIDToken
  block, the deploy SA and Cloud Run IAM all work on this stack. dns-noauth
  must be CLOUD RUN IAM 403 with "request was not authenticated": that is what
  a missing auth header looks like when the request DID reach Cloud Run.

  Then the IP variants:
    - ip-hostrun-auth = FRONT-END REJECT while dns-auth = 200
        the auth header was not what was missing; the front end never
        selected a Cloud Run service, so IAM was never consulted.
    - ip-hostrun-auth = CLOUD RUN IAM 403 or 200
        the front end DID route on Host; the original failure was auth (or the
        Host really was the IP). The engineer is right and §4.1 is wrong.
    - ip-hostrun-noauth vs ip-hostrun-auth differing
        auth changes the front end's verdict — unexpected, worth a trace.
    - ip-hostip-auth = FRONT-END REJECT
        what an unmodified update_apigee_proxy_target call would have produced.
    - ip-hostrun-auth-validate = TLS FAILURE / 503, tlsHandshakeStatus != COMPLETED
        Apigee's certificate validation rejects the IP target when asked to
        validate — the engineer's cert-path point is real for a proxy WITHOUT
        IgnoreValidationErrors. If it returns the same body as ip-hostrun-auth,
        validation is not what stops it either.

  Any HTTP body from the IP variants means TLS completed: a certificate
  failure produces no body.
EOF
