#!/usr/bin/env bash
#
# teardown-iam.sh — Remove service account and IAM bindings
#
# Run AFTER teardown-base.sh.
#
# Usage:
#   ./scripts/shared/teardown-iam.sh
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

echo "=== Teardown IAM — project: ${PROJECT_ID} ==="
echo ""

# ============================================================
# Step 1: Remove IAM bindings
# ============================================================
echo "--- Step 1: Remove IAM bindings ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  ROLES=(
    roles/compute.networkAdmin
    roles/compute.instanceAdmin.v1
    roles/compute.securityAdmin
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

# ============================================================
# Step 2: Remove Cloud Run Service Agent binding
# ============================================================
echo ""
echo "--- Step 2: Remove Cloud Run Service Agent binding ---"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)' 2>/dev/null || true)"
if [[ -n "${PROJECT_NUMBER}" ]]; then
  CR_SA="service-${PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com"
  gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${CR_SA}" \
    --role="roles/compute.networkUser" \
    --quiet >/dev/null 2>&1 || true
  echo "Cloud Run Service Agent binding removed."
fi

# ============================================================
# Step 3: Delete service account
# ============================================================
echo ""
echo "--- Step 3: Delete service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts delete "${SA_EMAIL}" --project="${PROJECT_ID}" --quiet
  echo "Service account '${SA_EMAIL}' deleted."
else
  echo "Service account '${SA_EMAIL}' does not exist, skipping."
fi

echo ""
echo "=== IAM teardown complete ==="
