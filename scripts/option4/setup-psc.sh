#!/usr/bin/env bash
#
# setup-psc.sh — Create ILB, Service Attachment, and PSC endpoint (idempotent)
#
# Producer side: Regional internal HTTPS load balancer in workloads-vpc
# with Service Attachment.
# Consumer side: PSC endpoint in apigee-vpc pointing to the Service Attachment.
#
# Run this AFTER setup-infra.sh has completed.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-apigee}"

REGION="europe-north2"

# Apigee (optional — detected automatically)
APIGEE_API="${APIGEE_API:-https://eu-apigee.googleapis.com/v1}"
APIGEE_ENV="${APIGEE_ENV:-test}"
PROXY_NAME="cr-hello-passthrough"
PSC_CONSUMER_IP="10.0.0.50"
APIGEE_TARGET_URL="https://${PSC_CONSUMER_IP}/"

echo "=== Setup PSC Service Attachment — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Producer (workloads-vpc)
# ============================================================

# ============================================================
# Step 1: Reserve ILB IP
# ============================================================
echo "--- Step 1: Reserve ILB IP ---"
if resource_exists gcloud compute addresses describe "ilb-ip-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Address 'ilb-ip-workloads' already exists, skipping."
else
  gcloud compute addresses create "ilb-ip-workloads" \
    --region="${REGION}" \
    --subnet=compute-workloads \
    --addresses=10.100.0.10 \
    --project="${PROJECT_ID}"
  echo "Address 'ilb-ip-workloads' (10.100.0.10) reserved."
fi

# ============================================================
# Step 2: Create Serverless NEG
# ============================================================
echo ""
echo "--- Step 2: Create Serverless NEG ---"
if resource_exists gcloud compute network-endpoint-groups describe "neg-cr-hello" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "NEG 'neg-cr-hello' already exists, skipping."
else
  gcloud compute network-endpoint-groups create "neg-cr-hello" \
    --region="${REGION}" \
    --network-endpoint-type=serverless \
    --cloud-run-service=cr-hello \
    --project="${PROJECT_ID}"
  echo "NEG 'neg-cr-hello' created."
fi

# ============================================================
# Step 3: Create backend service
# ============================================================
echo ""
echo "--- Step 3: Create backend service ---"
if resource_exists gcloud compute backend-services describe "backend-cr-hello" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Backend service 'backend-cr-hello' already exists, skipping."
else
  gcloud compute backend-services create "backend-cr-hello" \
    --region="${REGION}" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --protocol=HTTPS \
    --project="${PROJECT_ID}"
  gcloud compute backend-services add-backend "backend-cr-hello" \
    --region="${REGION}" \
    --network-endpoint-group=neg-cr-hello \
    --network-endpoint-group-region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Backend service 'backend-cr-hello' created with NEG backend."
fi

# ============================================================
# Step 4: URL map
# ============================================================
echo ""
echo "--- Step 4: Create URL map ---"
if resource_exists gcloud compute url-maps describe "urlmap-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "URL map 'urlmap-workloads' already exists, skipping."
else
  gcloud compute url-maps create "urlmap-workloads" \
    --region="${REGION}" \
    --default-service=backend-cr-hello \
    --project="${PROJECT_ID}"
  echo "URL map 'urlmap-workloads' created."
fi

# ============================================================
# Step 5: Self-signed SSL certificate
# ============================================================
echo ""
echo "--- Step 5: Create self-signed SSL certificate ---"
if resource_exists gcloud compute ssl-certificates describe "cert-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "SSL certificate 'cert-workloads' already exists, skipping."
else
  CERT_DIR="$(mktemp -d)"
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "${CERT_DIR}/key.pem" \
    -out "${CERT_DIR}/cert.pem" \
    -subj "/CN=api.internal.example.com" 2>/dev/null
  gcloud compute ssl-certificates create "cert-workloads" \
    --region="${REGION}" \
    --certificate="${CERT_DIR}/cert.pem" \
    --private-key="${CERT_DIR}/key.pem" \
    --project="${PROJECT_ID}"
  rm -rf "${CERT_DIR}"
  echo "SSL certificate 'cert-workloads' created."
fi

# ============================================================
# Step 6: Target HTTPS proxy
# ============================================================
echo ""
echo "--- Step 6: Create target HTTPS proxy ---"
if resource_exists gcloud compute target-https-proxies describe "proxy-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Target HTTPS proxy 'proxy-workloads' already exists, skipping."
else
  gcloud compute target-https-proxies create "proxy-workloads" \
    --region="${REGION}" \
    --url-map=urlmap-workloads \
    --ssl-certificates=cert-workloads \
    --project="${PROJECT_ID}"
  echo "Target HTTPS proxy 'proxy-workloads' created."
fi

# ============================================================
# Step 7: Forwarding rule (ILB)
# ============================================================
echo ""
echo "--- Step 7: Create forwarding rule (ILB) ---"
if resource_exists gcloud compute forwarding-rules describe "fwd-rule-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Forwarding rule 'fwd-rule-workloads' already exists, skipping."
else
  gcloud compute forwarding-rules create "fwd-rule-workloads" \
    --region="${REGION}" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --network=workloads-vpc \
    --subnet=compute-workloads \
    --address=ilb-ip-workloads \
    --ports=443 \
    --target-https-proxy=proxy-workloads \
    --target-https-proxy-region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Forwarding rule 'fwd-rule-workloads' created."
fi

# ============================================================
# Step 8: Service Attachment
# ============================================================
echo ""
echo "--- Step 8: Create Service Attachment ---"
if resource_exists gcloud compute service-attachments describe "sa-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Service Attachment 'sa-workloads' already exists, skipping."
else
  gcloud compute service-attachments create "sa-workloads" \
    --region="${REGION}" \
    --producer-forwarding-rule=fwd-rule-workloads \
    --connection-preference=ACCEPT_AUTOMATIC \
    --nat-subnets=psc-nat-workloads \
    --project="${PROJECT_ID}"
  echo "Service Attachment 'sa-workloads' created."
fi

# ============================================================
# Consumer (apigee-vpc)
# ============================================================

# ============================================================
# Step 9: Get Service Attachment URI
# ============================================================
echo ""
echo "--- Step 9: Get Service Attachment URI ---"
SA_URI="$(gcloud compute service-attachments describe "sa-workloads" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(selfLink)')"
echo "Service Attachment URI: ${SA_URI}"

# ============================================================
# Step 10: Reserve PSC consumer IP
# ============================================================
echo ""
echo "--- Step 10: Reserve PSC consumer IP ---"
if resource_exists gcloud compute addresses describe "psc-consumer-ip" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Address 'psc-consumer-ip' already exists, skipping."
else
  gcloud compute addresses create "psc-consumer-ip" \
    --region="${REGION}" \
    --subnet=compute-apigee \
    --addresses=10.0.0.50 \
    --project="${PROJECT_ID}"
  echo "Address 'psc-consumer-ip' (10.0.0.50) reserved."
fi

# ============================================================
# Step 11: Create PSC endpoint
# ============================================================
echo ""
echo "--- Step 11: Create PSC endpoint ---"
if resource_exists gcloud compute forwarding-rules describe "psc-endpoint-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "PSC endpoint 'psc-endpoint-apigee' already exists, skipping."
else
  gcloud compute forwarding-rules create "psc-endpoint-apigee" \
    --region="${REGION}" \
    --network=apigee-vpc \
    --subnet=compute-apigee \
    --address=psc-consumer-ip \
    --target-service-attachment="${SA_URI}" \
    --project="${PROJECT_ID}"
  echo "PSC endpoint 'psc-endpoint-apigee' created."
fi

# ============================================================
# Step 12: DNS zone + A record
# ============================================================
echo ""
echo "--- Step 12: Create DNS zone and A record ---"

if resource_exists gcloud dns managed-zones describe "api-internal-zone" --project="${PROJECT_ID}"; then
  echo "DNS zone 'api-internal-zone' already exists, skipping."
else
  gcloud dns managed-zones create "api-internal-zone" \
    --dns-name="api.internal.example.com." \
    --description="Private zone for Apigee to Cloud Run via PSC" \
    --visibility=private \
    --networks=apigee-vpc \
    --project="${PROJECT_ID}"
  echo "DNS zone 'api-internal-zone' created."
fi

if gcloud dns record-sets describe "api.internal.example.com." \
    --zone="api-internal-zone" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  echo "DNS record 'api.internal.example.com' already exists, skipping."
else
  gcloud dns record-sets create "api.internal.example.com." \
    --zone="api-internal-zone" \
    --type=A \
    --ttl=300 \
    --rrdatas="10.0.0.50" \
    --project="${PROJECT_ID}"
  echo "DNS record 'api.internal.example.com -> 10.0.0.50' created."
fi

# ============================================================
# Verification
# ============================================================
echo ""
echo "=== PSC setup complete ==="

echo ""
echo "--- Service Attachment ---"
gcloud compute service-attachments describe "sa-workloads" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="table(name,connectionPreference,natSubnets)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- PSC endpoint ---"
gcloud compute forwarding-rules describe "psc-endpoint-apigee" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="table(name,IPAddress,pscConnectionStatus)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- DNS zone ---"
gcloud dns managed-zones describe "api-internal-zone" \
  --project="${PROJECT_ID}" \
  --format="table(name,dnsName,visibility)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- DNS records ---"
gcloud dns record-sets list \
  --zone="api-internal-zone" \
  --project="${PROJECT_ID}" \
  --format="table(name,type,ttl,rrdatas)" 2>/dev/null || echo "(not ready yet)"

# ============================================================
# Step 13: Update Apigee proxy target (if Apigee is provisioned)
# ============================================================
echo ""
echo "--- Step 13: Configure Apigee proxy (if provisioned) ---"

TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "Apigee not provisioned (HTTP ${APIGEE_HTTP}), skipping proxy update."
  echo ""
  echo "=== Next steps ==="
  echo ""
  echo "Run ./test.sh to verify PSC connectivity from the VM."
else
  # Check if proxy target is already correct
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

  NEEDS_UPDATE=true
  if [[ -n "${DEPLOYED_REV}" ]]; then
    CURRENT_TARGET_XML="$(curl -s \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Accept: application/xml" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis/${PROXY_NAME}/revisions/${DEPLOYED_REV}/targets/default" 2>/dev/null || true)"
    if echo "${CURRENT_TARGET_XML}" | grep -q "${PSC_CONSUMER_IP}"; then
      echo "Proxy target already set to ${APIGEE_TARGET_URL}, skipping."
      NEEDS_UPDATE=false
    fi
  fi

  if [[ "${NEEDS_UPDATE}" == "true" ]]; then
    echo "Updating proxy '${PROXY_NAME}' target to ${APIGEE_TARGET_URL}..."

    # Build proxy bundle with correct target URL
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
    <URL>${APIGEE_TARGET_URL}</URL>
    <SSLInfo>
      <Enabled>true</Enabled>
      <IgnoreValidationErrors>true</IgnoreValidationErrors>
    </SSLInfo>
  </HTTPTargetConnection>
</TargetEndpoint>
XMLEOF

    cat > "${BUNDLE_DIR}/apiproxy/${PROXY_NAME}.xml" << XMLEOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy name="${PROXY_NAME}">
  <Description>Pass-through proxy to Cloud Run cr-hello service via PSC</Description>
  <BasePaths>/hello</BasePaths>
</APIProxy>
XMLEOF

    BUNDLE_ZIP="$(mktemp).zip"
    (cd "${BUNDLE_DIR}" && zip -r "${BUNDLE_ZIP}" apiproxy/) >/dev/null

    # Import new revision
    IMPORT_RESPONSE="$(curl -s -X POST \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/octet-stream" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/apis?name=${PROXY_NAME}&action=import" \
      --data-binary "@${BUNDLE_ZIP}")"

    rm -rf "${BUNDLE_DIR}" "${BUNDLE_ZIP}"

    if echo "${IMPORT_RESPONSE}" | grep -q '"error"'; then
      echo "ERROR importing proxy revision:"
      echo "${IMPORT_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${IMPORT_RESPONSE}"
    else
      NEW_REV="$(echo "${IMPORT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('revision',''))" 2>/dev/null || true)"
      echo "Imported revision ${NEW_REV}."

      # Deploy new revision (override undeploys the old one)
      DEPLOY_RESPONSE="$(curl -s -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        "${APIGEE_API}/organizations/${PROJECT_ID}/environments/${APIGEE_ENV}/apis/${PROXY_NAME}/revisions/${NEW_REV}/deployments?override=true")"

      if echo "${DEPLOY_RESPONSE}" | grep -q '"error"'; then
        echo "ERROR deploying revision ${NEW_REV}:"
        echo "${DEPLOY_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${DEPLOY_RESPONSE}"
      else
        echo "Revision ${NEW_REV} deployed to '${APIGEE_ENV}'."
      fi
    fi
  fi

  # Get instance IP for summary
  INSTANCE_IP="$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/instances/instance-${REGION}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('host','unknown'))" 2>/dev/null || echo 'unknown')"

  echo ""
  echo "=== Apigee proxy configured ==="
  echo ""
  echo "  Proxy:  ${PROXY_NAME} → /hello"
  echo "  Target: ${APIGEE_TARGET_URL}"
  echo "  Instance IP: ${INSTANCE_IP}"
  echo ""
  echo "  Traffic flow:"
  echo "    Client → Apigee (${INSTANCE_IP}) → PSC (${PSC_CONSUMER_IP})"
  echo "    → Service Attachment → ILB → Cloud Run"
  echo ""
  echo "  Note: Target uses PSC IP directly (Apigee runtime cannot"
  echo "  resolve Cloud DNS private zones via VPC peering)."
  echo ""
  echo "=== Next steps ==="
  echo ""
  echo "Run ./test.sh to verify both direct PSC and Apigee end-to-end connectivity."
fi
