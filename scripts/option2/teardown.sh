#!/usr/bin/env bash
#
# option2/teardown.sh — Tear down Option 2 resources (idempotent)
#
# Deletes: DNS records and zone only.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

echo "=== Option 2 Teardown — project: ${PROJECT_ID} ==="
echo ""

# ============================================================
# Step 1: Delete DNS records and zone
# ============================================================
echo "--- Step 1: Delete DNS records and zone ---"

if gcloud dns record-sets describe "*.run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  gcloud dns record-sets delete "*.run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" --quiet
  echo "DNS record '*.run.app' deleted."
else
  echo "DNS record '*.run.app' does not exist, skipping."
fi

if gcloud dns record-sets describe "run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  gcloud dns record-sets delete "run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" --quiet
  echo "DNS record 'run.app' deleted."
else
  echo "DNS record 'run.app' does not exist, skipping."
fi

if resource_exists gcloud dns managed-zones describe "run-app-pga" --project="${PROJECT_ID}"; then
  gcloud dns managed-zones delete "run-app-pga" --project="${PROJECT_ID}" --quiet
  echo "DNS zone 'run-app-pga' deleted."
else
  echo "DNS zone 'run-app-pga' does not exist, skipping."
fi

echo ""
echo "=== Option 2 teardown complete ==="
