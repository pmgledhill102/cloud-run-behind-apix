#!/usr/bin/env bash
#
# setup-psc.sh — Create PSC endpoint for Google APIs and private DNS zone (idempotent)
#
# Creates a Private Service Connect endpoint targeting the all-apis bundle,
# and a private DNS zone for run.app that resolves *.run.app to the PSC
# endpoint IP. This routes all Cloud Run traffic from the VPC through PSC
# over Google's backbone, bypassing VPN tunnels entirely.
#
# This is identical to the single-service Option C setup. The single wildcard
# DNS record (*.run.app → PSC IP) covers all 20 Cloud Run services with zero
# additional networking infrastructure.
#
# Run this AFTER setup-infra.sh has completed.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
PSC_IP="10.0.0.100"

echo "=== Setup PSC for Google APIs — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo "PSC endpoint IP: ${PSC_IP}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Reserve internal IP for PSC endpoint
# ============================================================
echo "--- Step 1: Reserve internal IP for PSC endpoint ---"
if resource_exists gcloud compute addresses describe "pscgoogleapisip" \
    --global --project="${PROJECT_ID}"; then
  echo "Address 'pscgoogleapisip' already exists, skipping."
else
  gcloud compute addresses create "pscgoogleapisip" \
    --global \
    --purpose=PRIVATE_SERVICE_CONNECT \
    --addresses="${PSC_IP}" \
    --network=apigee-vpc \
    --project="${PROJECT_ID}"
  echo "Address 'pscgoogleapisip' (${PSC_IP}) reserved."
fi

# ============================================================
# Step 2: Create PSC forwarding rule for Google APIs
# ============================================================
echo ""
echo "--- Step 2: Create PSC forwarding rule ---"
if resource_exists gcloud compute forwarding-rules describe "pscgoogleapis" \
    --global --project="${PROJECT_ID}"; then
  echo "Forwarding rule 'pscgoogleapis' already exists, skipping."
else
  gcloud compute forwarding-rules create "pscgoogleapis" \
    --global \
    --network=apigee-vpc \
    --address=pscgoogleapisip \
    --target-google-apis-bundle=all-apis \
    --project="${PROJECT_ID}"
  echo "Forwarding rule 'pscgoogleapis' created (target: all-apis)."
fi

# ============================================================
# Step 3: Create private DNS zone for run.app
# ============================================================
echo ""
echo "--- Step 3: Create private DNS zone for run.app ---"
if resource_exists gcloud dns managed-zones describe "run-app-psc" --project="${PROJECT_ID}"; then
  echo "DNS zone 'run-app-psc' already exists, skipping."
else
  gcloud dns managed-zones create "run-app-psc" \
    --dns-name="run.app." \
    --visibility=private \
    --networks=apigee-vpc \
    --description="Route run.app to PSC endpoint for Google APIs" \
    --project="${PROJECT_ID}"
  echo "DNS zone 'run-app-psc' created."
fi

# ============================================================
# Step 4: Create wildcard A record for *.run.app
# ============================================================
echo ""
echo "--- Step 4: Create DNS record *.run.app → ${PSC_IP} ---"
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
# Verification
# ============================================================
echo ""
echo "=== PSC setup complete ==="

echo ""
echo "--- PSC forwarding rule ---"
gcloud compute forwarding-rules describe "pscgoogleapis" \
  --global --project="${PROJECT_ID}" \
  --format="table(name,IPAddress,target)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- DNS zone ---"
gcloud dns managed-zones describe "run-app-psc" \
  --project="${PROJECT_ID}" \
  --format="table(name,dnsName,visibility)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- DNS records ---"
gcloud dns record-sets list \
  --zone="run-app-psc" \
  --project="${PROJECT_ID}" \
  --format="table(name,type,ttl,rrdatas)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- Auto-generated p.googleapis.com zones ---"
gcloud dns managed-zones list \
  --filter="dnsName:p.googleapis.com" \
  --project="${PROJECT_ID}" \
  --format="table(name,dnsName)" 2>/dev/null || echo "(none found)"

echo ""
echo "=== Next steps ==="
echo ""
echo "Run ./test.sh to verify DNS resolution and connectivity through PSC."
