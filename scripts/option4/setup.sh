#!/usr/bin/env bash
#
# option4/setup.sh — Option D: PSC Published Service / Service Attachment (~2 min)
#
# Creates: workloads-vpc (+ PSC NAT subnet), ILB stack, Service Attachment,
# PSC endpoint, DNS zone, Apigee Endpoint Attachment (if provisioned)
#
# Prerequisites: shared/setup-base.sh completed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SHARED_DIR}/lib/workloads-vpc.sh"
source "${SHARED_DIR}/lib/ilb-stack.sh"
source "${SHARED_DIR}/lib/apigee-proxy.sh"

ENDPOINT_ATTACHMENT_ID="ea-cr-hello"

echo "=== Option 4: PSC Service Attachment — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# ============================================================
# Step 1: Create workloads-vpc + subnets + firewall
# ============================================================
echo ""
echo "--- Step 1: workloads-vpc ---"
create_workloads_vpc

# Option 4-specific: PSC NAT subnet
if resource_exists gcloud compute networks subnets describe "psc-nat-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet 'psc-nat-workloads' already exists, skipping."
else
  gcloud compute networks subnets create "psc-nat-workloads" \
    --network=workloads-vpc \
    --range="10.100.2.0/24" \
    --region="${REGION}" \
    --purpose=PRIVATE_SERVICE_CONNECT \
    --project="${PROJECT_ID}"
  echo "Subnet 'psc-nat-workloads' (10.100.2.0/24) created."
fi

# Option 4-specific firewall: PSC NAT to ILB
if resource_exists gcloud compute firewall-rules describe "allow-psc-nat-to-ilb-workloads" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-psc-nat-to-ilb-workloads' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-psc-nat-to-ilb-workloads" \
    --network=workloads-vpc \
    --allow=tcp \
    --source-ranges="10.100.2.0/24" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-psc-nat-to-ilb-workloads' created."
fi

# ============================================================
# Step 2: Create ILB stack
# ============================================================
echo ""
echo "--- Step 2: ILB stack ---"
create_ilb_stack

# ============================================================
# Step 3: Create Service Attachment
# ============================================================
echo ""
echo "--- Step 3: Service Attachment ---"
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
# Step 4: PSC endpoint (consumer side)
# ============================================================
echo ""
echo "--- Step 4: PSC endpoint ---"

SA_URI="$(gcloud compute service-attachments describe "sa-workloads" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(selfLink)')"

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

if resource_exists gcloud compute forwarding-rules describe "psc-endpoint-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "PSC endpoint 'psc-endpoint-apigee' already exists, skipping."
else
  gcloud compute forwarding-rules create "psc-endpoint-apigee" \
    --region="${REGION}" \
    --network="${APIGEE_NETWORK}" \
    --subnet=compute-apigee \
    --address=psc-consumer-ip \
    --target-service-attachment="${SA_URI}" \
    --project="${PROJECT_ID}"
  echo "PSC endpoint 'psc-endpoint-apigee' created."
fi

# ============================================================
# Step 5: DNS zone + A record
# ============================================================
echo ""
echo "--- Step 5: DNS ---"

if resource_exists gcloud dns managed-zones describe "api-internal-zone" --project="${PROJECT_ID}"; then
  echo "DNS zone 'api-internal-zone' already exists, skipping."
else
  gcloud dns managed-zones create "api-internal-zone" \
    --dns-name="api.internal.example.com." \
    --description="Private zone for Apigee to Cloud Run via PSC" \
    --visibility=private \
    --networks="${APIGEE_NETWORK}" \
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
# Step 6: Apigee Endpoint Attachment (if provisioned)
# ============================================================
echo ""
echo "--- Step 6: Apigee Endpoint Attachment ---"

TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"

EA_HOST=""

if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "Apigee not provisioned (HTTP ${APIGEE_HTTP}), skipping."
else
  SA_RESOURCE="projects/${PROJECT_ID}/regions/${REGION}/serviceAttachments/sa-workloads"

  EA_JSON="$(curl -s \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/endpointAttachments/${ENDPOINT_ATTACHMENT_ID}")"
  EA_STATE="$(echo "${EA_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
  EA_HOST="$(echo "${EA_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"

  if [[ "${EA_STATE}" == "ACTIVE" && -n "${EA_HOST}" ]]; then
    echo "Endpoint attachment '${ENDPOINT_ATTACHMENT_ID}' already ACTIVE (host: ${EA_HOST}), skipping."
  else
    if [[ -n "${EA_STATE}" && "${EA_STATE}" != "ACTIVE" ]]; then
      echo "Endpoint attachment exists (state: ${EA_STATE}). Waiting..."
    else
      echo "Creating Apigee endpoint attachment '${ENDPOINT_ATTACHMENT_ID}'..."
      echo "  Service Attachment: ${SA_RESOURCE}"

      EA_RESPONSE="$(curl -s -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${APIGEE_API}/organizations/${PROJECT_ID}/endpointAttachments?endpointAttachmentId=${ENDPOINT_ATTACHMENT_ID}" \
        -d "{
          \"location\": \"${REGION}\",
          \"serviceAttachment\": \"${SA_RESOURCE}\"
        }")"

      if echo "${EA_RESPONSE}" | grep -q '"error"'; then
        echo "ERROR creating endpoint attachment:"
        echo "${EA_RESPONSE}" | python3 -m json.tool 2>/dev/null || echo "${EA_RESPONSE}"
      else
        echo "Endpoint attachment creation started (LRO)."
      fi
    fi

    echo "Waiting for endpoint attachment to become ACTIVE..."
    TIMEOUT=600
    INTERVAL=15
    ELAPSED=0
    while true; do
      if (( ELAPSED > 0 && ELAPSED % 300 == 0 )); then
        TOKEN="$(gcloud auth print-access-token)"
      fi

      EA_JSON="$(curl -s \
        -H "Authorization: Bearer ${TOKEN}" \
        "${APIGEE_API}/organizations/${PROJECT_ID}/endpointAttachments/${ENDPOINT_ATTACHMENT_ID}")"
      EA_STATE="$(echo "${EA_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('state',''))" 2>/dev/null || true)"
      EA_HOST="$(echo "${EA_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('host',''))" 2>/dev/null || true)"

      if [[ "${EA_STATE}" == "ACTIVE" && -n "${EA_HOST}" ]]; then
        echo "Endpoint attachment ACTIVE (host: ${EA_HOST})."
        break
      fi
      if (( ELAPSED >= TIMEOUT )); then
        echo "WARNING: Timed out waiting for endpoint attachment. Check manually."
        break
      fi
      echo "  State: ${EA_STATE} (${ELAPSED}s elapsed)..."
      sleep "${INTERVAL}"
      ELAPSED=$((ELAPSED + INTERVAL))
    done
  fi

  # Update Apigee proxy target
  if [[ -n "${EA_HOST}" ]]; then
    SERVICE_URL="$(gcloud run services describe "cr-hello" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format='value(status.url)' 2>/dev/null || true)"
    update_apigee_proxy_target "https://${EA_HOST}/" --ssl-ignore --audience="${SERVICE_URL}"
  fi
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Option 4 setup complete ==="
echo ""
echo "Traffic flow:"
echo "  VM → PSC endpoint (10.0.0.50) → Service Attachment → ILB → Cloud Run"
if [[ -n "${EA_HOST}" ]]; then
  echo "  Apigee → Endpoint Attachment (${EA_HOST}) → Service Attachment → ILB → Cloud Run"
fi
echo ""
echo "Run ./scripts/option4/test.sh to verify."
