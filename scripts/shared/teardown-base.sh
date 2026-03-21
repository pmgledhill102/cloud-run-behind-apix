#!/usr/bin/env bash
#
# teardown-base.sh — Delete base infrastructure (reverse of setup-base.sh)
#
# Deletes: Cloud Run, VM, Cloud NAT, firewall rules, subnet, VPC,
# Artifact Registry.
#
# Run option-specific teardown scripts FIRST, then teardown-slow.sh,
# then this script.
#
# Usage:
#   ./scripts/shared/teardown-base.sh
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

echo "=== Teardown Base Infrastructure — project: ${PROJECT_ID} ==="
echo ""

FAILED_RESOURCES=()

# ============================================================
# Step 1: Delete Cloud Run service
# ============================================================
echo "--- Step 1: Delete Cloud Run service ---"
if resource_exists gcloud run services describe "cr-hello" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud run services delete "cr-hello" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Service 'cr-hello' deleted."
else
  echo "Service 'cr-hello' does not exist, skipping."
fi

# ============================================================
# Step 2: Delete Compute VM
# ============================================================
echo ""
echo "--- Step 2: Delete Compute VM ---"
if resource_exists gcloud compute instances describe "vm-test" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  gcloud compute instances delete "vm-test" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  echo "Instance 'vm-test' deleted."
else
  echo "Instance 'vm-test' does not exist, skipping."
fi

# ============================================================
# Step 3: Delete Cloud NAT
# ============================================================
echo ""
echo "--- Step 3: Delete Cloud NAT ---"

if gcloud compute routers nats describe "public-nat-apigee" \
    --router="nat-router-apigee" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud compute routers nats delete "public-nat-apigee" \
    --router="nat-router-apigee" --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "NAT gateway 'public-nat-apigee' deleted."
else
  echo "NAT gateway 'public-nat-apigee' does not exist, skipping."
fi

if resource_exists gcloud compute routers describe "nat-router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute routers delete "nat-router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Cloud Router 'nat-router-apigee' deleted."
else
  echo "Cloud Router 'nat-router-apigee' does not exist, skipping."
fi

# ============================================================
# Step 4: Delete firewall rules
# ============================================================
echo ""
echo "--- Step 4: Delete firewall rules ---"
for fw in allow-iap-ssh-apigee allow-internal-apigee; do
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "Firewall rule '${fw}' deleted."
  else
    echo "Firewall rule '${fw}' does not exist, skipping."
  fi
done

# ============================================================
# Step 5: Delete subnet
# ============================================================
echo ""
echo "--- Step 5: Delete subnet ---"
if resource_exists gcloud compute networks subnets describe "compute-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  delete_subnet_with_retry "compute-apigee"
else
  echo "Subnet 'compute-apigee' does not exist, skipping."
fi

# ============================================================
# Step 6: Delete VPC
# ============================================================
echo ""
echo "--- Step 6: Delete VPC ---"
if resource_exists gcloud compute networks describe "${APIGEE_NETWORK}" --project="${PROJECT_ID}"; then
  # Check for Apigee servicenetworking peering — VPC must stay if Apigee is still provisioned
  if gcloud compute networks peerings list --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
      --format="value(name)" 2>/dev/null | grep -q servicenetworking; then
    echo "VPC '${APIGEE_NETWORK}' has Apigee peering — skipping (run teardown-slow.sh first to remove)."
  elif gcloud compute networks delete "${APIGEE_NETWORK}" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
    echo "VPC '${APIGEE_NETWORK}' deleted."
  else
    echo "  WARNING: Could not delete VPC '${APIGEE_NETWORK}' — subnets may still be releasing."
    FAILED_RESOURCES+=("vpc/${APIGEE_NETWORK}")
  fi
else
  echo "VPC '${APIGEE_NETWORK}' does not exist, skipping."
fi

# ============================================================
# Step 7: Delete Artifact Registry
# ============================================================
echo ""
echo "--- Step 7: Delete Artifact Registry ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  gcloud artifacts repositories delete "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Repository '${REPO_NAME}' deleted."
else
  echo "Repository '${REPO_NAME}' does not exist, skipping."
fi

echo ""
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo "=== Teardown complete (with warnings) ==="
  echo ""
  echo "The following resources could not be deleted:"
  for res in "${FAILED_RESOURCES[@]}"; do
    echo "  - ${res}"
  done
else
  echo "=== Teardown complete ==="
fi
