#!/usr/bin/env bash
#
# option2b/experiment-tls-validation.sh — Does Apigee actually VALIDATE the
# Cloud Run certificate on the PGA / restricted-VIP path? (#100)
#
# The option 2/2b proxy target (shared/lib/apigee-proxy.sh) carries no
# <SSLInfo> block. It never sets IgnoreValidationErrors — but Apigee only
# promises to fail a handshake on a bad certificate when <Enforce>true</Enforce>
# is set; otherwise the outcome "depends upon the setting of
# <IgnoreValidationErrors>". So "TLS works" and "the certificate is checked"
# are separate claims. This experiment tests both, with negative controls that
# travel the SAME path (Apigee → peered DNS → restricted VIP → Cloud Run) and
# differ only in the one property being checked.
#
# Probes — one proxy each, base path /tls/<id>:
#
#   p1  cr-hello   no <SSLInfo> (today's config)              expect 200
#   p2  cr-hello   Enforce=true, no truststore                expect 200
#   p3  cr-hello   Enforce=true, truststore = GTS roots only  expect 200
#   n1  cr-hello   Enforce=true, truststore = unrelated CA    expect TLS FAIL (untrusted root)
#   n2  bad name   Enforce=true                                expect TLS FAIL (hostname mismatch)
#   n3  bad name   no <SSLInfo>                                what does the default allow?
#   n4  cr-hello   truststore = unrelated CA, no Enforce       what does the default allow?
#
# "bad name" is nomatch.<cr-hello host>: resolves through the same *.run.app
# wildcard to the same restricted VIP, but is one label deeper than any
# wildcard SAN on Google's certificate, so it can never validate.
#
# Every Apigee call carries a Google ID token for cr-hello (it is IAM-closed),
# and a Host header set to the real service host — exactly as the option 2
# proxy does.
#
# Subcommands:
#   setup     create truststores + deploy the seven probe proxies
#   observe   from vm-test: the certificate the restricted VIP presents (openssl)
#   test      probe each proxy from vm-test, classify, print a table
#   teardown  undeploy + delete the probe proxies and truststores
#   all       setup, observe, test
#
# Prerequisites: shared/setup-base + setup-slow + option2 + option2b applied.
#
# Usage:
#   PROJECT_ID=<your-project> ./scripts/option2b/experiment-tls-validation.sh all
#   PROJECT_ID=<your-project> ./scripts/option2b/experiment-tls-validation.sh teardown
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

MODE="${1:-all}"

KS_GOOD="tls-probe-gts-roots"
KS_WRONG="tls-probe-wrong-root"
PROBES=(p1 p2 p3 n1 n2 n3 n4)

# GTS roots: the anchors Cloud Run's certificate chains to. Taken from the
# local CA bundle; override the directory if yours differs.
GTS_ROOT_DIR="${GTS_ROOT_DIR:-/etc/ssl/certs}"

# Keep the bearer token out of argv: curl reads the header from a process
# substitution (a pipe), never from its command line.
api() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "${method}" \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$(gcloud auth print-access-token)") \
    "$@" "${APIGEE_API}/organizations/${PROJECT_ID}${path}"
}

SERVICE_URL="$(gcloud run services describe cr-hello \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)')"
[[ -n "${SERVICE_URL}" ]] || { echo "ERROR: cr-hello not found"; exit 1; }
SERVICE_HOST="${SERVICE_URL#https://}"
BAD_HOST="nomatch.${SERVICE_HOST}"

# probe_spec <id> → "target_host|sslinfo_kind|expect|description"
probe_spec() {
  case "$1" in
    p1) echo "${SERVICE_HOST}|none|OK|no <SSLInfo> (current option 2 config)" ;;
    p2) echo "${SERVICE_HOST}|enforce|OK|Enforce=true, platform default trust" ;;
    p3) echo "${SERVICE_HOST}|enforce-good-ts|OK|Enforce=true, truststore = GTS roots only" ;;
    n1) echo "${SERVICE_HOST}|enforce-wrong-ts|TLS_FAIL|Enforce=true, truststore = unrelated CA" ;;
    n2) echo "${BAD_HOST}|enforce|TLS_FAIL|Enforce=true, hostname not on cert" ;;
    n3) echo "${BAD_HOST}|none|?|no <SSLInfo>, hostname not on cert" ;;
    n4) echo "${SERVICE_HOST}|wrong-ts-no-enforce|?|truststore = unrelated CA, no Enforce" ;;
  esac
}

sslinfo_xml() {
  case "$1" in
    none) ;;
    enforce) cat << 'X'
    <SSLInfo>
      <Enabled>true</Enabled>
      <Enforce>true</Enforce>
    </SSLInfo>
X
    ;;
    enforce-good-ts) cat << X
    <SSLInfo>
      <Enabled>true</Enabled>
      <Enforce>true</Enforce>
      <TrustStore>${KS_GOOD}</TrustStore>
    </SSLInfo>
X
    ;;
    enforce-wrong-ts) cat << X
    <SSLInfo>
      <Enabled>true</Enabled>
      <Enforce>true</Enforce>
      <TrustStore>${KS_WRONG}</TrustStore>
    </SSLInfo>
X
    ;;
    wrong-ts-no-enforce) cat << X
    <SSLInfo>
      <Enabled>true</Enabled>
      <TrustStore>${KS_WRONG}</TrustStore>
    </SSLInfo>
X
    ;;
  esac
}

# ============================================================
# setup
# ============================================================
ensure_keystore() {
  local ks="$1"
  if api GET "/environments/${APIGEE_ENV}/keystores/${ks}" | grep -q "\"name\": *\"${ks}\""; then
    echo "Keystore '${ks}' exists."
  else
    api POST "/environments/${APIGEE_ENV}/keystores" \
      -H 'Content-Type: application/json' -d "{\"name\":\"${ks}\"}" >/dev/null
    echo "Keystore '${ks}' created."
  fi
}

ensure_cert_alias() {
  local ks="$1" alias="$2" pem="$3"
  if api GET "/environments/${APIGEE_ENV}/keystores/${ks}/aliases/${alias}" | grep -q "\"alias\""; then
    echo "  alias '${alias}' exists."
    return 0
  fi
  local out
  out="$(api POST "/environments/${APIGEE_ENV}/keystores/${ks}/aliases?alias=${alias}&format=pem" \
    -F "certFile=@${pem}")"
  if echo "${out}" | grep -q '"error"'; then
    echo "ERROR uploading ${alias} to ${ks}:"; echo "${out}"; exit 1
  fi
  echo "  alias '${alias}' uploaded."
}

deploy_probe() {
  local id="$1" spec host kind desc name bundle zip out rev
  spec="$(probe_spec "${id}")"
  IFS='|' read -r host kind _ desc <<< "${spec}"
  name="tls-probe-${id}"
  echo "--- ${name}: /tls/${id} → https://${host}/ (${desc}) ---"

  bundle="$(mktemp -d)"
  mkdir -p "${bundle}/apiproxy/proxies" "${bundle}/apiproxy/targets" "${bundle}/apiproxy/policies"
  cat > "${bundle}/apiproxy/${name}.xml" << X
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${name}"><Description>TLS validation probe ${id}: ${desc}</Description></APIProxy>
X
  cat > "${bundle}/apiproxy/policies/SetHostHeader.xml" << X
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<AssignMessage name="SetHostHeader">
  <Set><Headers><Header name="Host">${SERVICE_HOST}</Header></Headers></Set>
</AssignMessage>
X
  cat > "${bundle}/apiproxy/proxies/default.xml" << X
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxyEndpoint name="default">
  <PreFlow name="PreFlow"><Request/><Response/></PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPProxyConnection><BasePath>/tls/${id}</BasePath></HTTPProxyConnection>
  <RouteRule name="default"><TargetEndpoint>default</TargetEndpoint></RouteRule>
</ProxyEndpoint>
X
  cat > "${bundle}/apiproxy/targets/default.xml" << X
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<TargetEndpoint name="default">
  <PreFlow name="PreFlow">
    <Request><Step><Name>SetHostHeader</Name></Step></Request>
    <Response/>
  </PreFlow>
  <Flows/>
  <PostFlow name="PostFlow"><Request/><Response/></PostFlow>
  <HTTPTargetConnection>
    <URL>https://${host}/</URL>
$(sslinfo_xml "${kind}")
    <Authentication>
      <GoogleIDToken><Audience>${SERVICE_URL}</Audience></GoogleIDToken>
    </Authentication>
  </HTTPTargetConnection>
</TargetEndpoint>
X
  echo "  target XML:"
  sed 's/^/    | /' "${bundle}/apiproxy/targets/default.xml" | sed -n '/HTTPTargetConnection>/,/\/HTTPTargetConnection>/p'

  zip="$(mktemp -u).zip"
  (cd "${bundle}" && zip -qr "${zip}" apiproxy/)
  out="$(api POST "/apis?name=${name}&action=import" \
    -H 'Content-Type: application/octet-stream' --data-binary "@${zip}")"
  rm -rf "${bundle}" "${zip}"
  if echo "${out}" | grep -q '"error"'; then echo "ERROR importing ${name}:"; echo "${out}"; exit 1; fi
  rev="$(echo "${out}" | python3 -c 'import sys,json; print(json.load(sys.stdin)["revision"])')"
  out="$(api POST "/environments/${APIGEE_ENV}/apis/${name}/revisions/${rev}/deployments?override=true&serviceAccount=${SA_EMAIL}")"
  if echo "${out}" | grep -q '"error"'; then echo "ERROR deploying ${name}:"; echo "${out}"; exit 1; fi
  echo "  revision ${rev} deploying."
}

wait_ready() {
  local id name state elapsed
  for id in "${PROBES[@]}"; do
    name="tls-probe-${id}"; elapsed=0
    while :; do
      state="$(api GET "/environments/${APIGEE_ENV}/apis/${name}/deployments" \
        | python3 -c 'import sys,json; d=json.load(sys.stdin).get("deployments",[]); print(d[0].get("state","") if d else "")' 2>/dev/null || true)"
      [[ "${state}" == "READY" ]] && { echo "  ${name}: READY"; break; }
      (( elapsed >= 300 )) && { echo "  ${name}: not READY after 300s (${state:-unknown})"; break; }
      sleep 10; elapsed=$((elapsed + 10))
    done
  done
}

do_setup() {
  echo "=== setup — project ${PROJECT_ID}, env ${APIGEE_ENV} ==="
  echo "cr-hello:  ${SERVICE_URL}"
  echo "bad name:  ${BAD_HOST}"
  echo ""
  echo "--- Truststore '${KS_GOOD}': GTS Root R1-R4 (from ${GTS_ROOT_DIR}) ---"
  ensure_keystore "${KS_GOOD}"
  local r
  for r in R1 R2 R3 R4; do
    ensure_cert_alias "${KS_GOOD}" "gts-root-$(echo "${r}" | tr "[:upper:]" "[:lower:]")" "${GTS_ROOT_DIR}/GTS_Root_${r}.pem"
  done

  echo "--- Truststore '${KS_WRONG}': a freshly minted, unrelated self-signed CA ---"
  ensure_keystore "${KS_WRONG}"
  local tmp; tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=tls-probe unrelated CA" \
    -keyout "${tmp}/ca.key" -out "${tmp}/ca.pem" 2>/dev/null
  ensure_cert_alias "${KS_WRONG}" "unrelated-ca" "${tmp}/ca.pem"
  rm -rf "${tmp}"
  echo ""

  local id
  for id in "${PROBES[@]}"; do deploy_probe "${id}"; done
  echo ""
  echo "--- Waiting for deployments ---"
  wait_ready
  sleep 15   # runtime routing settle
}

# ============================================================
# observe — what the restricted VIP actually presents
# ============================================================
do_observe() {
  echo "=== observe — certificate presented at the restricted VIP (from vm-test) ==="
  local h
  for h in "${SERVICE_HOST}" "${BAD_HOST}"; do
    echo ""
    echo "--- SNI ${h} ---"
    ssh_cmd "getent hosts ${h}; \
      echo | openssl s_client -connect ${h}:443 -servername ${h} -verify_hostname ${h} 2>/dev/null \
        | grep -E 'Protocol|Cipher is|Verify return code|Verification'; \
      echo | openssl s_client -connect ${h}:443 -servername ${h} -showcerts 2>/dev/null \
        | awk '/BEGIN CERT/{n++} n==1' | sed -n '/BEGIN/,/END/p' \
        | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null \
        | tr ',' '\n' | grep -E 'subject=|issuer=|notAfter|run.app' | sed 's/^ *//' | head -20; \
      echo | openssl s_client -connect ${h}:443 -servername ${h} -showcerts 2>/dev/null \
        | grep -E '^ *[0-9] s:|^ *i:'" || echo "  (vm-test unreachable)"
  done
}

# ============================================================
# test
# ============================================================
do_test() {
  echo "=== test — Apigee → restricted VIP → Cloud Run, per SSLInfo variant ==="
  echo "Run at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local instance_ip
  instance_ip="$(api GET "/instances/${INSTANCE_NAME}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("host",""))')"
  [[ -n "${instance_ip}" ]] || { echo "ERROR: Apigee instance not ACTIVE"; exit 1; }
  echo "Apigee instance: ${instance_ip}   env group host: ${APIGEE_ENV_GROUP_HOSTNAME}"
  echo "(northbound VM→Apigee uses curl -k: the PoC env group has a self-signed cert;"
  echo " this experiment is about the SOUTHBOUND Apigee→Cloud Run hop)"

  local rows=() id spec host kind expect desc out code verdict result fails=0
  for id in "${PROBES[@]}"; do
    spec="$(probe_spec "${id}")"
    IFS='|' read -r host kind expect desc <<< "${spec}"
    echo ""
    echo "--- ${id}: ${desc}  [target https://${host}/] ---"
    out="$(ssh_cmd "curl -sk --max-time 30 -w '\nHTTP_STATUS:%{http_code} TIME:%{time_total}s' \
      -H 'Host: ${APIGEE_ENV_GROUP_HOSTNAME}' https://${instance_ip}/tls/${id}" 2>&1 || true)"
    echo "${out}" | sed 's/^/  /'
    code="$(echo "${out}" | sed -n 's/.*HTTP_STATUS:\([0-9]*\).*/\1/p' | tail -1)"
    if echo "${out}" | grep -q '^OK'; then
      result="OK"
    elif echo "${out}" | grep -qiE 'SslHandshakeFailed|SSL Handshake|handshake|certificate|PKIX'; then
      result="TLS_FAIL"
    else
      result="OTHER"
    fi
    if [[ "${expect}" == "?" ]]; then
      verdict="(observed)"
    elif [[ "${result}" == "${expect}" ]]; then
      verdict="PASS"
    else
      verdict="FAIL"; fails=$((fails + 1))
    fi
    rows+=("$(printf '%-3s %-7s %-9s %-10s %-10s %s' "${id}" "${code:-000}" "${result}" "${expect}" "${verdict}" "${desc}")")
  done

  echo ""
  echo "=========================================================================="
  printf '%-3s %-7s %-9s %-10s %-10s %s\n' "id" "HTTP" "result" "expect" "verdict" "variant"
  printf '%s\n' "${rows[@]}"
  echo "=========================================================================="
  if (( fails > 0 )); then
    echo "${fails} probe(s) did not match expectation (a fresh deploy can take a"
    echo "minute to route — re-run 'test' once before diagnosing)."
    exit 1
  fi
  echo "All asserted probes matched expectation."
}

# ============================================================
# teardown
# ============================================================
do_teardown() {
  echo "=== teardown — TLS probe proxies + truststores ==="
  local id name revs rev
  for id in "${PROBES[@]}"; do
    name="tls-probe-${id}"
    revs="$(api GET "/environments/${APIGEE_ENV}/apis/${name}/deployments" 2>/dev/null \
      | python3 -c 'import sys,json; [print(d["revision"]) for d in json.load(sys.stdin).get("deployments",[])]' 2>/dev/null || true)"
    for rev in ${revs}; do
      api DELETE "/environments/${APIGEE_ENV}/apis/${name}/revisions/${rev}/deployments" >/dev/null || true
      echo "  ${name} r${rev} undeployed."
    done
    if api DELETE "/apis/${name}" | grep -q '"name"'; then
      echo "  ${name} deleted."
    else
      echo "  ${name} not present."
    fi
  done
  local ks
  for ks in "${KS_GOOD}" "${KS_WRONG}"; do
    if api DELETE "/environments/${APIGEE_ENV}/keystores/${ks}" | grep -q '"name"'; then
      echo "  keystore ${ks} deleted."
    else
      echo "  keystore ${ks} not present."
    fi
  done
}

case "${MODE}" in
  setup)    do_setup ;;
  observe)  do_observe ;;
  test)     do_test ;;
  teardown) do_teardown ;;
  all)      do_setup; echo ""; do_observe; echo ""; do_test ;;
  *) echo "Usage: $0 {setup|observe|test|teardown|all}"; exit 2 ;;
esac
