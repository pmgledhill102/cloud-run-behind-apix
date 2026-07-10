#!/usr/bin/env bash
#
# option2b/teardown.sh — Remove VPC-SC perimeter (reverse of setup.sh)
#
# Deletes: service perimeter, scoped access policy (only if it is ours and
# empty), and disables VPC-SC on the servicenetworking peering.
#
# Leaves: accesscontextmanager.googleapis.com enabled (harmless, free), and
# everything belonging to option2 (run option2/teardown.sh separately).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

PERIMETER_NAME="apigee_poc_perimeter"
POLICY_TITLE="apigee-poc-policy"

echo "=== Teardown Option 2b (VPC-SC perimeter) — project: ${PROJECT_ID} ==="
echo ""

ORG_ID="$(gcloud projects get-ancestors "${PROJECT_ID}" \
  --format='csv[no-heading](id,type)' | awk -F, '$2=="organization"{print $1}')"

POLICY_ID="${ACCESS_POLICY_ID:-}"
if [[ -z "${POLICY_ID}" && -n "${ORG_ID}" ]]; then
  POLICY_ID="$(gcloud access-context-manager policies list \
    --organization="${ORG_ID}" \
    --billing-project="${PROJECT_ID}" \
    --format='value(name)' \
    --filter="title=${POLICY_TITLE}" 2>/dev/null | head -1 || true)"
  POLICY_ID="${POLICY_ID##*/}"
fi

# ============================================================
# Step 1: Delete service perimeter
# ============================================================
echo "--- Step 1: Delete service perimeter ---"
if [[ -z "${POLICY_ID}" ]]; then
  echo "Access policy '${POLICY_TITLE}' not found, skipping perimeter deletion."
elif resource_exists gcloud access-context-manager perimeters describe \
    "${PERIMETER_NAME}" --policy="${POLICY_ID}" --billing-project="${PROJECT_ID}"; then
  gcloud access-context-manager perimeters delete "${PERIMETER_NAME}" \
    --policy="${POLICY_ID}" \
    --billing-project="${PROJECT_ID}" \
    --quiet
  echo "Perimeter '${PERIMETER_NAME}' deleted."
else
  echo "Perimeter '${PERIMETER_NAME}' does not exist, skipping."
fi

# ============================================================
# Step 2: Delete scoped access policy (only ours, only if empty)
# ============================================================
echo ""
echo "--- Step 2: Delete access policy ---"
if [[ -z "${POLICY_ID}" ]]; then
  echo "No policy to delete, skipping."
elif [[ -n "${ACCESS_POLICY_ID:-}" ]]; then
  echo "Policy ${POLICY_ID} was supplied via ACCESS_POLICY_ID — not ours to delete, skipping."
else
  REMAINING="$(gcloud access-context-manager perimeters list \
    --policy="${POLICY_ID}" \
    --billing-project="${PROJECT_ID}" \
    --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${REMAINING}" != "0" ]]; then
    echo "Policy ${POLICY_ID} still contains ${REMAINING} perimeter(s), skipping deletion."
  else
    gcloud access-context-manager policies delete "${POLICY_ID}" \
      --billing-project="${PROJECT_ID}" \
      --quiet
    echo "Access policy '${POLICY_TITLE}' (${POLICY_ID}) deleted."
  fi
fi

# ============================================================
# Step 3: Disable VPC-SC on the servicenetworking peering
# ============================================================
echo ""
echo "--- Step 3: Disable VPC-SC on servicenetworking peering ---"
if gcloud services vpc-peerings disable-vpc-service-controls \
    --network="${APIGEE_NETWORK}" \
    --project="${PROJECT_ID}" 2>/dev/null; then
  echo "VPC-SC disabled on peering for '${APIGEE_NETWORK}'."
else
  echo "WARNING: could not disable VPC-SC on the peering (may already be off,"
  echo "         or the peering no longer exists). Non-fatal."
fi

# ============================================================
# Step 4: Remove restricted-VIP route, route export, dns.peer
# ============================================================
echo ""
echo "--- Step 4: Remove restricted-VIP route + route export + dns.peer ---"
if resource_exists gcloud compute routes describe "restricted-vip" --project="${PROJECT_ID}"; then
  gcloud compute routes delete "restricted-vip" --project="${PROJECT_ID}" --quiet
  echo "Route 'restricted-vip' deleted."
else
  echo "Route 'restricted-vip' does not exist, skipping."
fi

PEERING_NAME="$(gcloud compute networks peerings list \
  --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
  --format='value(name)' --filter='network~servicenetworking' 2>/dev/null || true)"
if [[ -n "${PEERING_NAME}" ]]; then
  gcloud compute networks peerings update "${PEERING_NAME}" \
    --network="${APIGEE_NETWORK}" \
    --no-export-custom-routes \
    --project="${PROJECT_ID}" 2>/dev/null \
    && echo "Custom route export disabled on peering '${PEERING_NAME}'." \
    || echo "WARNING: could not disable custom route export. Non-fatal."
else
  echo "Servicenetworking peering not found, skipping route export."
fi

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
APIGEE_AGENT_SA="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"
if gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${APIGEE_AGENT_SA}" \
    --role="roles/dns.peer" \
    --condition=None \
    --quiet >/dev/null 2>&1; then
  echo "dns.peer removed from Apigee service agent."
else
  echo "dns.peer binding not present, skipping."
fi

echo ""
echo "=== Teardown complete ==="
echo ""
echo "NOTE: perimeter deletion also takes a few minutes to propagate — blocked"
echo "requests may keep failing briefly after this script finishes."
