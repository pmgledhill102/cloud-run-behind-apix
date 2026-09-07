#!/usr/bin/env bash
#
# experiment-vpcsc-dns-scope.sh — which domains does enable-vpc-service-controls
# actually cover in the Apigee tenant?
#
# WHY THIS EXISTS
# ---------------
# `gcloud services vpc-peerings enable-vpc-service-controls --help` says the
# command creates Cloud DNS private zones in the service producer network, and
# names only three of them:
#
#     "The zones include googleapis.com, pkg.dev, gcr.io, and other necessary
#      domains or host names for Google APIs and services that are compatible
#      with VPC Service Controls."
#
# "and other necessary domains" is the whole problem. A customer putting Cloud
# Run behind Apigee needs to know whether `run.app` is one of them, and the
# sentence does not say.
#
# Nor can they look it up. The Service Networking API *does* expose
# `services.projects.global.networks.dnsZones.list`, which would answer the
# question directly — but it is gated on `servicenetworking.services.listDnsZones`,
# a producer-side permission that appears in no predefined role and is not even
# testable on a consumer project (verified 2026-09-07; see §"Enumeration is
# closed" in docs/repro/dns-peering.md). The zones live in a Google-owned tenant
# project the customer cannot see into.
#
# So the only route left is behavioural: ask the tenant to reach a name and see
# whether it can. This script does that for a *set* of hostnames rather than the
# single pair in experiment-tenant-dns.sh, turning "and other necessary domains"
# into an observed list.
#
# HOW IT DISCRIMINATES
# --------------------
# Each probe is an Apigee pass-through proxy whose target is one hostname. The
# probe runs from the test VM against the Apigee runtime IP, so what is measured
# is what the *tenant* can reach, not what your VPC can reach.
#
# Three outcomes are distinguishable, and the distinction is the point:
#
#   connected      any HTTP status came back (200/401/403/404) — a socket was
#                  opened, so DNS resolved AND a route existed. The status code
#                  itself is irrelevant; a 401 from an unauthenticated storage
#                  GET proves reachability just as well as a 200.
#   no socket      503 TARGET_CONNECT_TIMEOUT at ~3.3s — the tenant resolved the
#                  name to something it has no route to, or could not resolve it.
#                  This is the signature of a domain OUTSIDE the zone set.
#   trace-confirmed  with TRACE=1, the debug session's resolvedAddress field
#                  shows the IP the tenant actually resolved to. 199.36.153.x
#                  means the restricted VIP (in scope); a public IP means the
#                  tenant used public DNS and is now stranded (out of scope);
#                  the field being ABSENT means no socket at all.
#
# THE CONTROL THAT MAKES IT AIRTIGHT
# ----------------------------------
# `www.google.com` is probed deliberately. It is emphatically not a VPC-SC
# domain, so it must fail after enablement — that failure is what demonstrates
# the default internet route really was removed. Without it, a `run.app` failure
# could be argued to be a Cloud Run quirk rather than a routing consequence.
#
# Usage:
#   PROJECT_ID=<p> ./scripts/option2b/experiment-vpcsc-dns-scope.sh before
#   PROJECT_ID=<p> ./scripts/option2b/experiment-vpcsc-dns-scope.sh enable
#   PROJECT_ID=<p> ./scripts/option2b/experiment-vpcsc-dns-scope.sh after
#
#   before  — map the domains with VPC-SC OFF (baseline: the tenant has its
#             default internet route, so everything should connect)
#   enable  — run enable-vpc-service-controls, then wait for it to settle
#   after   — map the same domains with VPC-SC ON (the measurement)
#
# TRACE=1 additionally captures a debug session per probe and reports
# resolvedAddress. Slower (~90s per probe) but far stronger evidence.
#
set -euo pipefail

PHASE="${1:-after}"
case "${PHASE}" in
  before|enable|after) ;;
  *) echo "Usage: $0 {before|enable|after}" >&2; exit 2 ;;
esac

source "$(dirname "${BASH_SOURCE[0]}")/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

SETTLE_SECS="${SETTLE_SECS:-180}"

# ------------------------------------------------------------
# Evidence capture (same contract as experiment-tenant-dns.sh)
# ------------------------------------------------------------
if [[ -n "${EVIDENCE_DIR:-}" && -z "${_EVIDENCE_REEXEC:-}" ]]; then
  mkdir -p "${EVIDENCE_DIR}"
  _stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  EVIDENCE_TRANSCRIPT="${EVIDENCE_DIR}/${_stamp}-scope-${PHASE}.log"
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

INSTANCE_IP="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"
if [[ -z "${INSTANCE_IP}" ]]; then
  echo "ERROR: Apigee instance '${INSTANCE_NAME}' not ACTIVE. Run shared/setup-slow.sh." >&2
  exit 1
fi

# ------------------------------------------------------------
# The probe table
# ------------------------------------------------------------
# name|basepath|target-url|classification
#
# Classification records what the gcloud reference text leads you to expect,
# so the output can be read as "documented list vs observed behaviour":
#   DOC-NAMED   — named explicitly in the gcloud help text
#   DOC-VAGUE   — would have to fall under "other necessary domains"
#   CONTROL     — definitely not a VPC-SC domain; must fail once the default
#                 route is removed
PROBES="$(cat <<EOF
gapi|/scope-gapi|https://storage.googleapis.com/storage/v1/b/gcp-public-data-landsat|DOC-NAMED googleapis.com
pkgdev|/scope-pkgdev|https://${REGION}-docker.pkg.dev/v2/|DOC-NAMED pkg.dev
gcrio|/scope-gcrio|https://gcr.io/v2/|DOC-NAMED gcr.io
runapp|/scope-runapp|${SERVICE_URL}/|DOC-VAGUE run.app  <<< THE DISPUTED ONE
inet|/scope-inet|https://www.google.com/generate_204|CONTROL public internet
EOF
)"

echo "=========================================================="
echo "  VPC-SC DNS scope map — which domains does the tenant reach?"
echo "=========================================================="
echo "Project:        ${PROJECT_ID}"
echo "Phase:          ${PHASE}"
echo "Cloud Run:      ${SERVICE_URL}"
echo "Apigee runtime: ${INSTANCE_IP}"
echo "Run at:         $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

vpcsc_state() {
  curl -s -H "Authorization: Bearer ${TOKEN}" \
    "https://servicenetworking.googleapis.com/v1/services/servicenetworking.googleapis.com/projects/${PROJECT_NUMBER}/global/networks/${APIGEE_NETWORK}/vpcServiceControls" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('enabled','?'))" 2>/dev/null || echo "?"
}

echo "enable-vpc-service-controls currently: $(vpcsc_state)"
echo ""

# ------------------------------------------------------------
# Fixture: one pass-through proxy per probe
# ------------------------------------------------------------
ensure_probe_proxy() {
  local pname="$1" basepath="$2" target="$3"
  local proxy="probe-${pname}"

  local deployed_rev
  deployed_rev="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0].get('revision','') if d else '')
" 2>/dev/null || true)"
  if [[ -n "${deployed_rev}" ]]; then
    echo "  ${proxy}: already deployed (rev ${deployed_rev})"
    return 0
  fi

  local target_host="${target#https://}"
  target_host="${target_host%%/*}"

  local bundle_dir
  bundle_dir="$(mktemp -d)"
  mkdir -p "${bundle_dir}/apiproxy/proxies" \
           "${bundle_dir}/apiproxy/targets" \
           "${bundle_dir}/apiproxy/policies"

  # Apigee sends the env-group hostname as Host unless told otherwise; the
  # target front end needs its own name to route and to serve the right cert.
  cat > "${bundle_dir}/apiproxy/policies/SetHostHeader.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<AssignMessage name="SetHostHeader">
  <Set>
    <Headers>
      <Header name="Host">${target_host}</Header>
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

  # Deliberately unauthenticated. Any HTTP status proves a socket was opened,
  # which is the only thing being measured; authenticating would add a failure
  # mode that has nothing to do with DNS scope.
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
    <URL>${target}</URL>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

  cat > "${bundle_dir}/apiproxy/${proxy}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${proxy}">
  <Description>VPC-SC DNS scope probe: ${target_host}</Description>
  <BasePaths>${basepath}</BasePaths>
</APIProxy>
XMLEOF

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

  local deploy_response
  deploy_response="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/revisions/${new_rev}/deployments?override=true")"
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
  echo "  ${proxy}: deployed rev ${new_rev} (${basepath} -> ${target_host})"
}

# ------------------------------------------------------------
# Probe: run from the VM against the Apigee runtime IP
# ------------------------------------------------------------
# Returns "<http_code>|<seconds>|<first 200 bytes of body>"
apigee_probe() {
  local basepath="$1"
  ssh_cmd "curl -sk --max-time 20 -o /tmp/scope-body -w '%{http_code}|%{time_total}' \
    -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}${basepath} ; \
    echo -n '|' ; head -c 200 /tmp/scope-body | tr '\n' ' '" 2>/dev/null || echo "SSH-FAILED||"
}

# ------------------------------------------------------------
# Optional trace: what IP did the tenant actually resolve to?
# ------------------------------------------------------------
trace_probe() {
  local pname="$1" basepath="$2"
  local proxy="probe-${pname}"
  local rev
  rev="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${proxy}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0].get('revision','') if d else '')
" 2>/dev/null || true)"
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
want = ('resolvedAddress', 'connectionStatus', 'tlsHandshakeStatus', 'error.class')
found = {}
def walk(o):
    if isinstance(o, dict):
        n, v = o.get('name'), o.get('value')
        if isinstance(n, str) and any(n.endswith(w) for w in want):
            found.setdefault(n, v)
        for x in o.values():
            walk(x)
    elif isinstance(o, list):
        for x in o:
            walk(x)
walk(d)
if not found:
    print('      resolvedAddress: ABSENT — no socket was ever created')
for k in sorted(found):
    print(f'      {k} = {found[k]}')
" 2>/dev/null || echo "      (could not parse trace)"
}

# ------------------------------------------------------------
# Phase: enable
# ------------------------------------------------------------
if [[ "${PHASE}" == "enable" ]]; then
  echo "--- Enabling VPC Service Controls on the servicenetworking peering ---"
  gcloud services vpc-peerings enable-vpc-service-controls \
    --network="${APIGEE_NETWORK}" \
    --service=servicenetworking.googleapis.com \
    --project="${PROJECT_ID}"
  echo ""
  echo "State now: $(vpcsc_state)"
  echo "Settling for ${SETTLE_SECS}s before measuring..."
  sleep "${SETTLE_SECS}"
  echo "Done. Run '$0 after' to map the domains."
  exit 0
fi

# ------------------------------------------------------------
# Fixtures, then probes
# ------------------------------------------------------------
echo "--- Fixtures: one pass-through proxy per probe ---"
while IFS='|' read -r pname basepath target class; do
  [[ -n "${pname}" ]] || continue
  ensure_probe_proxy "${pname}" "${basepath}" "${target}"
done <<< "${PROBES}"
echo ""
sleep 10

echo "=========================================================="
echo "  RESULTS — phase '${PHASE}', VPC-SC enabled=$(vpcsc_state)"
echo "=========================================================="
printf '%-8s %-34s %-22s %s\n' "PROBE" "TARGET HOST" "RESULT" "CLASSIFICATION"
printf '%-8s %-34s %-22s %s\n' "-----" "-----------" "------" "--------------"

RESULT_LINES=""
while IFS='|' read -r pname basepath target class; do
  [[ -n "${pname}" ]] || continue
  target_host="${target#https://}"; target_host="${target_host%%/*}"

  out="$(apigee_probe "${basepath}")"
  code="$(echo "${out}" | head -1 | cut -d'|' -f1)"
  secs="$(echo "${out}" | head -1 | cut -d'|' -f2)"
  body="$(echo "${out}" | cut -d'|' -f3-)"

  if echo "${body}" | grep -q 'TARGET_CONNECT_TIMEOUT'; then
    verdict="NO SOCKET (${secs}s)"
  elif [[ "${code}" == "000" || -z "${code}" || "${code}" == "SSH-FAILED" ]]; then
    verdict="PROBE FAILED"
  else
    verdict="connected HTTP ${code}"
  fi

  printf '%-8s %-34s %-22s %s\n' "${pname}" "${target_host:0:34}" "${verdict}" "${class}"
  RESULT_LINES="${RESULT_LINES}${pname}|${target_host}|${verdict}|${class}"$'\n'
done <<< "${PROBES}"

echo ""
if [[ "${TRACE:-}" == "1" ]]; then
  echo "--- TRACE: resolvedAddress per probe (what the tenant's DNS returned) ---"
  echo "    199.36.153.4-7 = restricted VIP (domain IS in the zone set)"
  echo "    a public IP    = tenant used public DNS (domain is NOT in the zone set)"
  echo "    ABSENT         = no socket at all"
  echo ""
  while IFS='|' read -r pname basepath target class; do
    [[ -n "${pname}" ]] || continue
    target_host="${target#https://}"; target_host="${target_host%%/*}"
    echo "  ${pname} (${target_host}):"
    trace_probe "${pname}" "${basepath}"
    echo ""
  done <<< "${PROBES}"
fi

echo "--- VM control: what THIS VPC resolves (should be unaffected throughout) ---"
ssh_cmd "for h in storage.googleapis.com gcr.io ${SERVICE_URL#https://} www.google.com; do \
  echo -n \"  \$h -> \"; getent hosts \$h | awk '{print \$1}' | tr '\n' ' '; echo; done" \
  2>/dev/null || echo "  (VM probe failed)"
echo ""

echo "=========================================================="
echo "  How to read this"
echo "=========================================================="
cat <<'EOF'
  Phase 'before' (VPC-SC off): everything should connect. The tenant still has
  its default internet route, so this only proves the fixtures work.

  Phase 'after' (VPC-SC on): the discriminator.
    - DOC-NAMED domains connecting proves the mechanism is working.
    - CONTROL (www.google.com) failing proves the default route was removed.
    - run.app failing IN THE SAME RUN proves run.app is not in the zone set,
      and that its failure is a consequence of the route removal rather than
      anything specific to Cloud Run.

  If run.app fails while googleapis.com/pkg.dev/gcr.io succeed, the phrase
  "and other necessary domains" demonstrably does not include run.app, and a
  peered DNS domain (gcloud services peered-dns-domains create) is required.
EOF
