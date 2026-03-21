#!/usr/bin/env bash
#
# option2/setup.sh — Option B: Private Google Access (PGA) (~30 sec)
#
# Creates: private DNS zone routing *.run.app to restricted VIP (199.36.153.4/30)
#
# This is the simplest option — just DNS. Combined with Private Google Access
# on the subnet (enabled by setup-base.sh), traffic routes to Cloud Run
# without VPN or PSC.
#
# Prerequisites: shared/setup-base.sh completed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SHARED_DIR}/lib/apigee-proxy.sh"

echo "=== Option 2: PGA — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo "Restricted VIP: 199.36.153.4, 199.36.153.5, 199.36.153.6, 199.36.153.7"
echo ""

# ============================================================
# Step 1: Create private DNS zone for run.app
# ============================================================
echo "--- Step 1: Create private DNS zone for run.app ---"
if resource_exists gcloud dns managed-zones describe "run-app-pga" --project="${PROJECT_ID}"; then
  echo "DNS zone 'run-app-pga' already exists, skipping."
else
  gcloud dns managed-zones create "run-app-pga" \
    --dns-name="run.app." \
    --visibility=private \
    --networks="${APIGEE_NETWORK}" \
    --description="Route run.app to restricted VIP for Private Google Access" \
    --project="${PROJECT_ID}"
  echo "DNS zone 'run-app-pga' created."
fi

# ============================================================
# Step 2: Create wildcard A record *.run.app → restricted VIP
# ============================================================
echo ""
echo "--- Step 2: Create DNS record *.run.app → restricted VIP ---"
if gcloud dns record-sets describe "*.run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  echo "DNS record '*.run.app' already exists, skipping."
else
  gcloud dns record-sets create "*.run.app." \
    --zone="run-app-pga" \
    --type=A \
    --ttl=300 \
    --rrdatas="199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7" \
    --project="${PROJECT_ID}"
  echo "DNS record '*.run.app → 199.36.153.4-7' created."
fi

# ============================================================
# Step 3: Create apex A record run.app → restricted VIP
# ============================================================
echo ""
echo "--- Step 3: Create DNS record run.app → restricted VIP ---"
if gcloud dns record-sets describe "run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  echo "DNS record 'run.app' already exists, skipping."
else
  gcloud dns record-sets create "run.app." \
    --zone="run-app-pga" \
    --type=A \
    --ttl=300 \
    --rrdatas="199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7" \
    --project="${PROJECT_ID}"
  echo "DNS record 'run.app → 199.36.153.4-7' created."
fi

# ============================================================
# Step 4: Update Apigee proxy target (optional)
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
echo "=== Option 2 setup complete ==="
echo ""
echo "Traffic flow: VM → restricted VIP (199.36.153.x) → Cloud Run"
echo ""
echo "Run ./scripts/option2/test.sh to verify."
