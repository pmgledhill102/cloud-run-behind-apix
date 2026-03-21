#!/usr/bin/env bash
#
# option3/teardown.sh — Tear down Option 3 resources (idempotent)
#
# Deletes: DNS, PSC forwarding rule, PSC IP, extra Cloud Run services (if scaled)
#
# For scaled variant:
#   SERVICE_COUNT=20 ./scripts/option3/teardown.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

SERVICE_COUNT="${SERVICE_COUNT:-1}"

echo "=== Option 3 Teardown — project: ${PROJECT_ID} ==="
echo ""

# ============================================================
# Step 1: Delete DNS records and zone
# ============================================================
echo "--- Step 1: Delete DNS records and zone ---"

if gcloud dns record-sets describe "*.run.app." \
    --zone="run-app-psc" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  gcloud dns record-sets delete "*.run.app." \
    --zone="run-app-psc" --type=A --project="${PROJECT_ID}" --quiet
  echo "DNS record '*.run.app' deleted."
else
  echo "DNS record '*.run.app' does not exist, skipping."
fi

if resource_exists gcloud dns managed-zones describe "run-app-psc" --project="${PROJECT_ID}"; then
  gcloud dns managed-zones delete "run-app-psc" --project="${PROJECT_ID}" --quiet
  echo "DNS zone 'run-app-psc' deleted."
else
  echo "DNS zone 'run-app-psc' does not exist, skipping."
fi

# ============================================================
# Step 2: Delete PSC forwarding rule and IP
# ============================================================
echo ""
echo "--- Step 2: Delete PSC endpoint ---"

if resource_exists gcloud compute forwarding-rules describe "pscgoogleapis" \
    --global --project="${PROJECT_ID}"; then
  gcloud compute forwarding-rules delete "pscgoogleapis" \
    --global --project="${PROJECT_ID}" --quiet
  echo "Forwarding rule 'pscgoogleapis' deleted."
else
  echo "Forwarding rule 'pscgoogleapis' does not exist, skipping."
fi

if resource_exists gcloud compute addresses describe "pscgoogleapisip" \
    --global --project="${PROJECT_ID}"; then
  gcloud compute addresses delete "pscgoogleapisip" \
    --global --project="${PROJECT_ID}" --quiet
  echo "Address 'pscgoogleapisip' deleted."
else
  echo "Address 'pscgoogleapisip' does not exist, skipping."
fi

# ============================================================
# Step 3: Delete extra Cloud Run services (if scaled)
# ============================================================
if [[ "${SERVICE_COUNT}" -gt 1 ]]; then
  echo ""
  echo "--- Step 3: Delete ${SERVICE_COUNT} Cloud Run services ---"
  for i in $(seq -w 1 "${SERVICE_COUNT}"); do
    svc="cr-svc-${i}"
    if resource_exists gcloud run services describe "${svc}" \
        --region="${REGION}" --project="${PROJECT_ID}"; then
      gcloud run services delete "${svc}" \
        --region="${REGION}" --project="${PROJECT_ID}" --quiet
      echo "Service '${svc}' deleted."
    else
      echo "Service '${svc}' does not exist, skipping."
    fi
  done
fi

echo ""
echo "=== Option 3 teardown complete ==="
