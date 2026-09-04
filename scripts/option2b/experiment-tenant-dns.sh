#!/usr/bin/env bash
#
# option2b/experiment-tenant-dns.sh — Is tenant DNS peering really required?
#
# THE CLAIM UNDER TEST
#
#   "The peered DNS domain and the restricted-VIP route aren't required when
#    VPC Service Controls is enabled, because enabling it redirects DNS to
#    restricted.googleapis.com anyway."
#
# (Reported from a Google support agent, 2026-09.)
#
# WHY THIS SCRIPT EXISTS
#
# docs/option-b-vpcsc-field-notes.md §4/§9 already answer half of this, but
# they answer it by BREAKING A WORKING STACK — deleting the peered DNS domain
# and watching southbound die. That leaves a loophole the claim could live in:
# maybe `enable-vpc-service-controls` installs tenant run.app resolution at
# enablement time, and deleting the peered DNS domain afterwards only removed
# something the tenant had already bound to. A stack that NEVER HAD the DNS
# peering might behave differently.
#
# This script closes that loophole by building the omission in from the start
# (shared/setup-early.sh SKIP_RESTRICTED_VIP_ROUTE=1, setup-finish.sh
# SKIP_TENANT_DNS=1) and then adding the pieces back one at a time.
#
# THE DISCRIMINATOR
#
# The claim is not simply wrong — it contains a true statement pointed at the
# wrong hostname. `enable-vpc-service-controls` really does install
# restricted-VIP DNS + routing inside the Apigee tenant, but only for
# *.googleapis.com names. Cloud Run is reached at *.run.app, which is not one.
#
# So every phase probes BOTH, through the same Apigee runtime, in the same
# minute:
#
#   /hello       → https://<svc>.run.app        (Cloud Run — the thing we want)
#   /gapi-probe  → https://storage.googleapis.com/... (a googleapis.com name)
#
# If the googleapis probe connects while the run.app probe times out, the
# claim's mechanism is demonstrably real AND demonstrably not covering Cloud
# Run — which is a much more useful finding than "support was wrong".
#
# VM controls run alongside: the workload path has its own default route and
# its own view of the private DNS zone, so it keeps working throughout. That
# is the §9 discriminator — VM fine + Apigee failing means tenant DNS/routing,
# not your VPC.
#
# PHASES
#
#   omit   assert the omitted state, then probe   (expect: run.app FAILS)
#   dns    add dns.peer + peered DNS domain, probe (expect: run.app WORKS)
#   full   add restricted-VIP route + export, probe (expect: no change)
#   probe  probe only, change nothing
#
# Run them in order. Each prints a state dump so the probe results are always
# anchored to what actually existed at the time.
#
# TRACE=1 additionally captures an Apigee debug session for the run.app proxy
# and reports resolvedAddress / connectionStatus — the "was a socket ever
# created?" test from field notes §9. Costs ~90s per probe round.
#
# Prerequisites:
#   - shared/setup-base.sh, shared/setup-slow.sh, option2/setup.sh
#   - setup-finish.sh must have run at least once so VPC-SC is enabled on the
#     servicenetworking peering (that is the mechanism under test; run it with
#     SKIP_TENANT_DNS=1 to reach the 'omit' state)
#
#   - A working transport to vm-test. On a sandbox whose egress policy denies
#     IAP (tunnel.cloudproxy.app), prefix every invocation with
#     VM_CHANNEL=metadata to use the metadata/guest-attributes channel
#     (shared/lib/vm-exec.sh) — run vm_exec_setup once first.
#
# Usage:
#   PROJECT_ID=<your-project> ./scripts/option2b/experiment-tenant-dns.sh omit
#   PROJECT_ID=<your-project> ./scripts/option2b/experiment-tenant-dns.sh dns
#   PROJECT_ID=<your-project> ./scripts/option2b/experiment-tenant-dns.sh full
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

PHASE="${1:-probe}"
GAPI_PROXY="gapi-probe"
GAPI_BASEPATH="/gapi-probe"
# Any googleapis.com REST endpoint that answers without credentials is fine —
# we are testing whether a TCP+TLS connection happens at all, not authorising
# anything. An unauthenticated bucket GET returns a 401 JSON body, which is a
# clean "we reached Google's front end" signal.
GAPI_TARGET="https://storage.googleapis.com/storage/v1/b/gcp-public-data-landsat"

# How long to let a DNS change settle before probing. Field notes §9 observed
# peered-DNS-domain create taking effect in ~70s; 150s is comfortably past it
# without being a wait-and-hope.
SETTLE_SECS="${SETTLE_SECS:-150}"

echo "=========================================================="
echo "  Experiment: is tenant DNS peering required under VPC-SC?"
echo "=========================================================="
echo "Project: ${PROJECT_ID}"
echo "Phase:   ${PHASE}"
echo "Run at:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

TOKEN="$(gcloud auth print-access-token)"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
APIGEE_AGENT_SA="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"

SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"
if [[ -z "${SERVICE_URL}" ]]; then
  echo "ERROR: Cloud Run service 'cr-hello' not found. Run shared/setup-base.sh."
  exit 1
fi
SERVICE_HOST="${SERVICE_URL#https://}"

INSTANCE_IP="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/instances/${INSTANCE_NAME}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"
if [[ -z "${INSTANCE_IP}" ]]; then
  echo "ERROR: Apigee instance '${INSTANCE_NAME}' not ACTIVE. Run shared/setup-slow.sh."
  exit 1
fi

echo "Cloud Run:      ${SERVICE_URL}"
echo "Apigee runtime: ${INSTANCE_IP}"
echo ""

# ============================================================
# State dump — what actually exists right now
# ============================================================
dump_state() {
  echo "----------------------------------------------------------"
  echo "  Tenant plumbing state"
  echo "----------------------------------------------------------"

  local peering_vpcsc
  peering_vpcsc="$(gcloud services vpc-peerings list \
    --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
    --format='value(reservedPeeringRanges)' 2>/dev/null || true)"
  echo "servicenetworking peering ranges : ${peering_vpcsc:-<none>}"

  local peered_dns
  peered_dns="$(gcloud services peered-dns-domains list \
    --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
    --format='value(name,dnsSuffix)' 2>/dev/null || true)"
  echo "peered DNS domains               : ${peered_dns:-<NONE>}"

  local route
  route="$(gcloud compute routes list --project="${PROJECT_ID}" \
    --filter='destRange=199.36.153.4/30' \
    --format='value(name,destRange)' 2>/dev/null || true)"
  echo "restricted-VIP route             : ${route:-<NONE>}"

  local export_flag
  export_flag="$(gcloud compute networks peerings list \
    --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
    --flatten='peerings[]' \
    --format='value(peerings.exportCustomRoutes)' \
    --filter='peerings.network~servicenetworking' 2>/dev/null || true)"
  echo "export custom routes on peering  : ${export_flag:-false}"

  local dnspeer
  dnspeer="$(gcloud projects get-iam-policy "${PROJECT_ID}" \
    --flatten='bindings[].members[]' \
    --format='value(bindings.members)' \
    --filter="bindings.role=roles/dns.peer AND bindings.members~${APIGEE_AGENT_SA}" \
    2>/dev/null || true)"
  echo "dns.peer on Apigee service agent : ${dnspeer:-<NONE>}"

  local zone_rrdata
  zone_rrdata="$(gcloud dns record-sets describe '*.run.app.' \
    --zone=run-app-pga --type=A --project="${PROJECT_ID}" \
    --format='value(rrdatas)' 2>/dev/null || true)"
  echo "private *.run.app A record       : ${zone_rrdata:-<NONE>}"
  echo ""
}

# ============================================================
# Fixture: an Apigee proxy pointed at a googleapis.com host
# ============================================================
# This is the whole discriminator, so it gets the same Host rewrite the
# run.app proxy has (shared/lib/apigee-proxy.sh) — Apigee otherwise forwards
# the inbound env-group Host, and a Host mismatch at the GFE would produce a
# 404 that is easy to misread as a connectivity failure.
ensure_gapi_proxy() {
  echo "--- Fixture: proxy '${GAPI_PROXY}' (${GAPI_BASEPATH} → ${GAPI_TARGET}) ---"

  local deployed_rev
  deployed_rev="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${GAPI_PROXY}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0].get('revision','') if d else '')
" 2>/dev/null || true)"

  if [[ -n "${deployed_rev}" ]]; then
    echo "Already deployed (revision ${deployed_rev}), skipping."
    return 0
  fi

  local target_host="${GAPI_TARGET#https://}"
  target_host="${target_host%%/*}"

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
    <BasePath>${GAPI_BASEPATH}</BasePath>
  </HTTPProxyConnection>
  <RouteRule name="default">
    <TargetEndpoint>default</TargetEndpoint>
  </RouteRule>
</ProxyEndpoint>
XMLEOF

  # Deliberately unauthenticated: a 401 from the storage API is proof the
  # tenant reached Google's front end, which is the only thing being measured.
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
    <URL>${GAPI_TARGET}</URL>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

  cat > "${bundle_dir}/apiproxy/${GAPI_PROXY}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${GAPI_PROXY}">
  <Description>Experiment fixture: pass-through to a googleapis.com host</Description>
  <BasePaths>${GAPI_BASEPATH}</BasePaths>
</APIProxy>
XMLEOF

  local bundle_zip import_response new_rev
  bundle_zip="$(mktemp).zip"
  (cd "${bundle_dir}" && zip -r "${bundle_zip}" apiproxy/) >/dev/null
  import_response="$(curl -s -X POST \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/octet-stream" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${GAPI_PROXY}&action=import" \
    --data-binary "@${bundle_zip}")"
  rm -rf "${bundle_dir}" "${bundle_zip}"
  if echo "${import_response}" | grep -q '"error"'; then
    echo "ERROR importing '${GAPI_PROXY}':"
    echo "${import_response}" | python3 -m json.tool 2>/dev/null || echo "${import_response}"
    exit 1
  fi
  new_rev="$(echo "${import_response}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))" 2>/dev/null || true)"
  echo "Imported revision ${new_rev}."

  local deploy_response
  deploy_response="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${GAPI_PROXY}/revisions/${new_rev}/deployments?override=true")"
  if echo "${deploy_response}" | grep -q '"error"'; then
    echo "ERROR deploying '${GAPI_PROXY}':"
    echo "${deploy_response}" | python3 -m json.tool 2>/dev/null || echo "${deploy_response}"
    exit 1
  fi

  local elapsed=0 state
  while true; do
    state="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${GAPI_PROXY}/revisions/${new_rev}/deployments" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
    [[ "${state}" == "READY" ]] && { echo "Deployment READY."; break; }
    if (( elapsed >= 180 )); then
      echo "WARNING: not READY after 180s (state: ${state:-unknown})."
      break
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
  sleep 10
  echo ""
}

# ============================================================
# Probes
# ============================================================
# apigee_probe <basepath> — returns "<http_code>|<elapsed>|<body first line>"
apigee_probe() {
  local basepath="$1"
  ssh_cmd "curl -sk --max-time 20 -o /tmp/probe-body -w '%{http_code}|%{time_total}' \
    -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${INSTANCE_IP}${basepath} ; \
    echo '|' ; head -c 300 /tmp/probe-body | tr '\n' ' '" 2>/dev/null || echo "SSH-FAILED"
}

run_probes() {
  local label="$1"
  echo "=========================================================="
  echo "  PROBES — ${label}"
  echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "=========================================================="
  echo ""

  echo "--- Probe 1: Apigee → Cloud Run (*.run.app)  [the thing under test] ---"
  local p1
  p1="$(apigee_probe '/hello')"
  echo "${p1}"
  echo ""

  echo "--- Probe 2: Apigee → storage.googleapis.com  [the discriminator] ---"
  local p2
  p2="$(apigee_probe "${GAPI_BASEPATH}")"
  echo "${p2}"
  echo ""

  echo "--- Probe 3: VM → Cloud Run  [control: workload path] ---"
  ssh_curl_auth "${SERVICE_URL}" "-s --max-time 15 -o /tmp/vm-body -w 'HTTP %{http_code} in %{time_total}s\n' ${SERVICE_URL}/ ; head -c 120 /tmp/vm-body" \
    2>/dev/null || echo "  FAILED"
  echo ""

  echo "--- Probe 4: VM → storage.googleapis.com  [control] ---"
  ssh_cmd "curl -s --max-time 15 -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' '${GAPI_TARGET}'" \
    2>/dev/null || echo "  FAILED"
  echo ""

  echo "--- Probe 5: VM DNS resolution (what THIS VPC resolves) ---"
  ssh_cmd "echo -n '  ${SERVICE_HOST} -> '; getent hosts ${SERVICE_HOST} | awk '{print \$1}' | tr '\n' ' '; echo; \
           echo -n '  storage.googleapis.com -> '; getent hosts storage.googleapis.com | awk '{print \$1}' | tr '\n' ' '; echo" \
    2>/dev/null || echo "  FAILED"
  echo ""

  # ------------------------------------------------------------
  # Verdict
  # ------------------------------------------------------------
  local p1_code p2_code
  p1_code="$(echo "${p1}" | head -1 | cut -d'|' -f1)"
  p2_code="$(echo "${p2}" | head -1 | cut -d'|' -f1)"

  echo "----------------------------------------------------------"
  echo "  Verdict — ${label}"
  echo "----------------------------------------------------------"
  printf '  Apigee → *.run.app            : HTTP %s\n' "${p1_code:-?}"
  printf '  Apigee → *.googleapis.com     : HTTP %s\n' "${p2_code:-?}"
  echo ""
  if echo "${p1}" | grep -q 'TARGET_CONNECT_TIMEOUT'; then
    echo "  run.app: NO CONNECTION (TARGET_CONNECT_TIMEOUT) — the tenant"
    echo "           cannot resolve/route run.app to the restricted VIP."
  elif [[ "${p1_code}" == "200" ]]; then
    echo "  run.app: CONNECTED and served (200)."
  else
    echo "  run.app: connected but returned ${p1_code} — a policy/auth answer,"
    echo "           not a connectivity failure (a socket was created)."
  fi
  if echo "${p2}" | grep -q 'TARGET_CONNECT_TIMEOUT'; then
    echo "  googleapis: NO CONNECTION (TARGET_CONNECT_TIMEOUT)."
  elif [[ -n "${p2_code}" && "${p2_code}" != "000" ]]; then
    echo "  googleapis: CONNECTED (HTTP ${p2_code} came back from Google's"
    echo "              front end — the tenant resolved and routed it)."
  fi
  echo ""

  if [[ "${TRACE:-}" == "1" ]]; then
    trace_run_app
  fi
}

# ============================================================
# Optional: Apigee debug session on the run.app proxy
# ============================================================
# Field notes §9: on a failing connection the resolvedAddress /
# connectionStatus / tlsHandshakeStatus fields DO NOT EXIST, because no socket
# was ever created. That is the cleanest single piece of evidence available.
trace_run_app() {
  echo "--- TRACE: debug session on '${PROXY_NAME}' ---"
  local rev
  rev="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/deployments" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin).get('deployments', [])
print(d[0].get('revision','') if d else '')
" 2>/dev/null || true)"
  if [[ -z "${rev}" ]]; then
    echo "  no deployed revision; skipping trace."
    return 0
  fi

  local session
  session="$(curl -s -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/${rev}/debugsessions?timeout=300" \
    -d '{}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || true)"
  if [[ -z "${session}" ]]; then
    echo "  could not create debug session; skipping trace."
    return 0
  fi
  echo "  session ${session} created; waiting 75s for it to reach the MP..."
  sleep 75

  apigee_probe '/hello' >/dev/null || true
  sleep 15

  local txn
  txn="$(curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/${rev}/debugsessions/${session}/data" \
    | python3 -c "
import sys,json
d = json.load(sys.stdin)
# The endpoint returns a bare JSON array of transaction ids (confirmed live);
# older docs suggest a wrapped object, so tolerate both.
v = d if isinstance(d, list) else (d.get('responses') or d.get('data') or [])
print(v[0] if v and isinstance(v[0], str) else '')
" 2>/dev/null || true)"
  if [[ -z "${txn}" ]]; then
    echo "  no transaction captured (session may not have propagated in time)."
    return 0
  fi

  curl -s -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/${rev}/debugsessions/${session}/data/${txn}" \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
want = ('resolvedAddress', 'connectionStatus', 'tlsHandshakeStatus',
        'isFromClientPool', 'socketUseCount', 'error.class', 'state')
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
print('  --- connection fields from the trace ---')
if not found:
    print('  NONE PRESENT — no socket was ever created (see field notes §9).')
for k in sorted(found):
    print(f'  {k} = {found[k]}')
" 2>/dev/null || echo "  (could not parse trace)"
  echo ""
}

# ============================================================
# Mutations
# ============================================================
add_dns_peering() {
  echo "--- Adding: dns.peer grant + peered DNS domain 'run-app' ---"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${APIGEE_AGENT_SA}" \
    --role="roles/dns.peer" \
    --condition=None --quiet >/dev/null
  echo "dns.peer granted to ${APIGEE_AGENT_SA}."

  if gcloud services peered-dns-domains list \
      --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
      --format='value(name)' 2>/dev/null | grep -qx "run-app"; then
    echo "Peered DNS domain 'run-app' already exists."
  else
    gcloud services peered-dns-domains create "run-app" \
      --network="${APIGEE_NETWORK}" \
      --dns-suffix="run.app." \
      --project="${PROJECT_ID}"
    echo "Peered DNS domain 'run-app' created."
  fi
  echo ""
  echo "Settling ${SETTLE_SECS}s before probing..."
  sleep "${SETTLE_SECS}"
  echo ""
}

add_route_and_export() {
  echo "--- Adding: restricted-VIP route + custom route export ---"
  if gcloud compute routes describe "restricted-vip" --project="${PROJECT_ID}" &>/dev/null; then
    echo "Route 'restricted-vip' already exists."
  else
    gcloud compute routes create "restricted-vip" \
      --network="${APIGEE_NETWORK}" \
      --destination-range="199.36.153.4/30" \
      --next-hop-gateway="default-internet-gateway" \
      --project="${PROJECT_ID}"
    echo "Route 'restricted-vip' created."
  fi

  local peering_name
  peering_name="$(gcloud compute networks peerings list \
    --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
    --flatten='peerings[]' --format='value(peerings.name)' \
    --filter='peerings.network~servicenetworking' 2>/dev/null || true)"
  if [[ -n "${peering_name}" ]]; then
    gcloud compute networks peerings update "${peering_name}" \
      --network="${APIGEE_NETWORK}" --export-custom-routes \
      --project="${PROJECT_ID}"
    echo "Custom route export enabled on '${peering_name}'."
  else
    echo "WARNING: servicenetworking peering not found."
  fi
  echo ""
  echo "Settling ${SETTLE_SECS}s before probing..."
  sleep "${SETTLE_SECS}"
  echo ""
}

# ============================================================
# Drive
# ============================================================
ensure_gapi_proxy

case "${PHASE}" in
  omit)
    dump_state
    echo "Expected state for this phase: NO peered DNS domain, NO route,"
    echo "NO custom route export, NO dns.peer. If any is present, this phase"
    echo "is not testing what it claims — tear down and rebuild with"
    echo "SKIP_TENANT_DNS=1 SKIP_RESTRICTED_VIP_ROUTE=1."
    echo ""
    run_probes "PHASE 'omit' — VPC-SC on the peering, nothing else"
    ;;
  dns)
    add_dns_peering
    dump_state
    run_probes "PHASE 'dns' — + dns.peer + peered DNS domain (still no route)"
    ;;
  full)
    add_route_and_export
    dump_state
    run_probes "PHASE 'full' — + restricted-VIP route + custom route export"
    ;;
  probe)
    dump_state
    run_probes "probe only (no changes made)"
    ;;
  *)
    echo "ERROR: unknown phase '${PHASE}'. Use: omit | dns | full | probe"
    exit 1
    ;;
esac

echo "=========================================================="
echo "  Phase '${PHASE}' complete — $(date '+%H:%M:%S %Z')"
echo "=========================================================="
