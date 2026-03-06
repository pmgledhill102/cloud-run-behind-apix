#!/usr/bin/env bash
#
# teardown.sh — Destroy all infrastructure (idempotent)
#
# Tears down in reverse dependency order: Cloud Run first (to release VPC
# address reservations), then VM, DNS, NAT, firewall, subnet, VPC, Artifact
# Registry, and finally the service account.
#
# Safe to re-run: skips resources that don't exist.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="apigee-pga-poc"
SA_NAME="apigee-pga-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Teardown Infrastructure for project: ${PROJECT_ID} ==="
echo ""

# --- Helpers ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

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
# Step 3: Delete DNS records and zone
# ============================================================
echo ""
echo "--- Step 3: Delete DNS records and zone ---"

# Delete wildcard A record
if gcloud dns record-sets describe "*.run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  gcloud dns record-sets delete "*.run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" --quiet
  echo "DNS record '*.run.app' deleted."
else
  echo "DNS record '*.run.app' does not exist, skipping."
fi

# Delete apex A record
if gcloud dns record-sets describe "run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  gcloud dns record-sets delete "run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" --quiet
  echo "DNS record 'run.app' deleted."
else
  echo "DNS record 'run.app' does not exist, skipping."
fi

# Delete DNS zone
if resource_exists gcloud dns managed-zones describe "run-app-pga" --project="${PROJECT_ID}"; then
  gcloud dns managed-zones delete "run-app-pga" --project="${PROJECT_ID}" --quiet
  echo "DNS zone 'run-app-pga' deleted."
else
  echo "DNS zone 'run-app-pga' does not exist, skipping."
fi

# ============================================================
# Step 4: Delete Cloud NAT
# ============================================================
echo ""
echo "--- Step 4: Delete Cloud NAT ---"

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
# Step 5: Delete firewall rules
# ============================================================
echo ""
echo "--- Step 5: Delete firewall rules ---"
for fw in allow-iap-ssh-apigee allow-internal-apigee; do
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "Firewall rule '${fw}' deleted."
  else
    echo "Firewall rule '${fw}' does not exist, skipping."
  fi
done

# ============================================================
# Step 6: Delete subnet
# ============================================================
echo ""
echo "--- Step 6: Delete subnet ---"

delete_subnet_with_retry() {
  local subnet="$1"
  local max_attempts=6
  local wait_secs=10

  for attempt in $(seq 1 "${max_attempts}"); do
    if gcloud compute networks subnets delete "${subnet}" \
        --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
      echo "Subnet '${subnet}' deleted."
      return 0
    fi

    if [[ ${attempt} -lt ${max_attempts} ]]; then
      echo "  Subnet '${subnet}' still in use, retrying in ${wait_secs}s... (attempt ${attempt}/${max_attempts})"
      sleep "${wait_secs}"
      wait_secs=$((wait_secs * 2))
    else
      echo "  WARNING: Could not delete subnet '${subnet}' — still in use (Cloud Run may need more time to release)."
      FAILED_RESOURCES+=("subnet/${subnet}")
      return 0  # continue teardown
    fi
  done
}

if resource_exists gcloud compute networks subnets describe "compute-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  delete_subnet_with_retry "compute-apigee"
else
  echo "Subnet 'compute-apigee' does not exist, skipping."
fi

# ============================================================
# Step 7: Delete VPC network
# ============================================================
echo ""
echo "--- Step 7: Delete VPC network ---"
if resource_exists gcloud compute networks describe "apigee-vpc" --project="${PROJECT_ID}"; then
  if gcloud compute networks delete "apigee-vpc" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
    echo "VPC 'apigee-vpc' deleted."
  else
    echo "  WARNING: Could not delete VPC 'apigee-vpc' — subnets may still be releasing."
    FAILED_RESOURCES+=("vpc/apigee-vpc")
  fi
else
  echo "VPC 'apigee-vpc' does not exist, skipping."
fi

# ============================================================
# Step 8: Delete Artifact Registry
# ============================================================
echo ""
echo "--- Step 8: Delete Artifact Registry repository ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  gcloud artifacts repositories delete "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Repository '${REPO_NAME}' deleted."
else
  echo "Repository '${REPO_NAME}' does not exist, skipping."
fi

# ============================================================
# Step 9: Remove IAM bindings and delete service account
# ============================================================
echo ""
echo "--- Step 9: Remove IAM bindings ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  ROLES=(
    roles/compute.networkAdmin
    roles/compute.instanceAdmin.v1
    roles/run.admin
    roles/run.invoker
    roles/iam.serviceAccountUser
    roles/iap.tunnelResourceAccessor
    roles/artifactregistry.admin
    roles/dns.admin
  )
  for role in "${ROLES[@]}"; do
    echo "  Removing ${role}..."
    gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="${role}" \
      --quiet >/dev/null 2>&1 || true
  done
  echo "IAM bindings removed."
else
  echo "Service account does not exist, skipping IAM cleanup."
fi

# Remove Cloud Run Service Agent binding
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -n "${PROJECT_NUMBER}" ]]; then
  CR_SA="service-${PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com"
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CR_SA}" \
    --role="roles/compute.networkUser" \
    --quiet >/dev/null 2>&1 || true
  echo "Cloud Run Service Agent binding removed."
fi

echo ""
echo "--- Step 10: Delete service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
  echo "Service account '${SA_EMAIL}' deleted."
else
  echo "Service account '${SA_EMAIL}' does not exist, skipping."
fi

echo ""
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo "=== Teardown complete (with warnings) ==="
  echo ""
  echo "The following resources could not be deleted (Cloud Run may still be"
  echo "releasing VPC address reservations). These are free and pose no risk."
  echo "Re-run this script later, or delete manually:"
  echo ""
  for res in "${FAILED_RESOURCES[@]}"; do
    echo "  - ${res}"
  done
else
  echo "=== Teardown complete ==="
fi
