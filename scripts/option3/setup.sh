#!/usr/bin/env bash
#
# option3/setup.sh — Option C: PSC Endpoint for Google APIs (~1 min)
#
# Creates: PSC endpoint (all-apis), private DNS zone for run.app
#
# For scaled variant (20 services):
#   SERVICE_COUNT=20 ./scripts/option3/setup.sh
#
# Prerequisites: shared/setup-base.sh completed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SHARED_DIR}/lib/apigee-proxy.sh"

SERVICE_COUNT="${SERVICE_COUNT:-1}"
PSC_IP="10.0.1.100"

echo "=== Option 3: PSC for Google APIs — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo "PSC endpoint IP: ${PSC_IP}"
echo "Service count: ${SERVICE_COUNT}"
echo ""

# ============================================================
# Step 1: Deploy additional Cloud Run services (if scaled)
# ============================================================
if [[ "${SERVICE_COUNT}" -gt 1 ]]; then
  echo "--- Step 1: Deploy ${SERVICE_COUNT} Cloud Run services ---"
  for i in $(seq -w 1 "${SERVICE_COUNT}"); do
    svc="cr-svc-${i}"
    if resource_exists gcloud run services describe "${svc}" \
        --region="${REGION}" --project="${PROJECT_ID}"; then
      echo "Service '${svc}' already exists, skipping."
    else
      echo "Deploying '${svc}'..."
      gcloud run deploy "${svc}" \
        --image="${IMAGE_URL}" \
        --region="${REGION}" \
        --ingress=internal \
        --max-instances=5 \
        --min-instances=0 \
        --cpu-throttling \
        --no-allow-unauthenticated \
        --project="${PROJECT_ID}" \
        --quiet
      echo "Service '${svc}' deployed."
    fi
  done
  echo ""
fi

# ============================================================
# Step 2: Reserve internal IP for PSC endpoint
# ============================================================
echo "--- Step 2: Reserve internal IP for PSC endpoint ---"
if resource_exists gcloud compute addresses describe "pscgoogleapisip" \
    --global --project="${PROJECT_ID}"; then
  echo "Address 'pscgoogleapisip' already exists, skipping."
else
  gcloud compute addresses create "pscgoogleapisip" \
    --global \
    --purpose=PRIVATE_SERVICE_CONNECT \
    --addresses="${PSC_IP}" \
    --network="${APIGEE_NETWORK}" \
    --project="${PROJECT_ID}"
  echo "Address 'pscgoogleapisip' (${PSC_IP}) reserved."
fi

# ============================================================
# Step 3: Create PSC forwarding rule for Google APIs
# ============================================================
echo ""
echo "--- Step 3: Create PSC forwarding rule ---"
if resource_exists gcloud compute forwarding-rules describe "pscgoogleapis" \
    --global --project="${PROJECT_ID}"; then
  echo "Forwarding rule 'pscgoogleapis' already exists, skipping."
else
  gcloud compute forwarding-rules create "pscgoogleapis" \
    --global \
    --network="${APIGEE_NETWORK}" \
    --address=pscgoogleapisip \
    --target-google-apis-bundle=all-apis \
    --project="${PROJECT_ID}"
  echo "Forwarding rule 'pscgoogleapis' created (target: all-apis)."
fi

# ============================================================
# Step 4: Create private DNS zone for run.app
# ============================================================
echo ""
echo "--- Step 4: Create private DNS zone for run.app ---"
if resource_exists gcloud dns managed-zones describe "run-app-psc" --project="${PROJECT_ID}"; then
  echo "DNS zone 'run-app-psc' already exists, skipping."
else
  gcloud dns managed-zones create "run-app-psc" \
    --dns-name="run.app." \
    --visibility=private \
    --networks="${APIGEE_NETWORK}" \
    --description="Route run.app to PSC endpoint for Google APIs" \
    --project="${PROJECT_ID}"
  echo "DNS zone 'run-app-psc' created."
fi

# ============================================================
# Step 5: Create wildcard A record for *.run.app
# ============================================================
echo ""
echo "--- Step 5: Create DNS record *.run.app → ${PSC_IP} ---"
if gcloud dns record-sets describe "*.run.app." \
    --zone="run-app-psc" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  echo "DNS record '*.run.app' already exists, skipping."
else
  gcloud dns record-sets create "*.run.app." \
    --zone="run-app-psc" \
    --type=A \
    --ttl=300 \
    --rrdatas="${PSC_IP}" \
    --project="${PROJECT_ID}"
  echo "DNS record '*.run.app → ${PSC_IP}' created."
fi

# ============================================================
# Step 6: Update Apigee proxy target (optional)
# ============================================================
echo ""
SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"
if [[ -n "${SERVICE_URL}" ]]; then
  update_apigee_proxy_target "${SERVICE_URL}/" --audience="${SERVICE_URL}"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Option 3 setup complete ==="
echo ""
echo "Traffic flow: VM → PSC endpoint (${PSC_IP}) → Google backbone → Cloud Run"
if [[ "${SERVICE_COUNT}" -gt 1 ]]; then
  echo "Services: ${SERVICE_COUNT} (cr-svc-01..${SERVICE_COUNT})"
  echo "Key finding: single wildcard DNS covers all services."
fi
echo ""
echo "Run ./scripts/option3/test.sh to verify."
