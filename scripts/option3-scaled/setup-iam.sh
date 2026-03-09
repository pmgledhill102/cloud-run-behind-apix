#!/usr/bin/env bash
#
# setup-iam.sh — Create service account and bind IAM roles
#
# Run this with your own privileged account (Owner or IAM Admin).
# After this completes, use the created service account to run setup-infra.sh.
#
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

SA_NAME="apigee-psc-scaled-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=== Setup IAM for project: ${PROJECT_ID} ==="
echo "Service account: ${SA_EMAIL}"
echo ""

# --- Enable APIs ---
echo "--- Enabling APIs ---"
gcloud services enable \
  compute.googleapis.com \
  run.googleapis.com \
  dns.googleapis.com \
  iap.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project="${PROJECT_ID}"
echo "APIs enabled."

# --- Create service account ---
echo ""
echo "--- Creating service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Service account already exists, skipping."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Apigee PSC Scaled PoC" \
    --description="Service account for Apigee-to-Cloud-Run PSC scaled PoC (20 services)" \
    --project="${PROJECT_ID}"
  echo "Service account created."
fi

# --- Bind IAM roles ---
echo ""
echo "--- Binding IAM roles ---"
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
  echo "  Binding ${role}..."
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet >/dev/null
done
echo "IAM roles bound."

# --- Grant caller permission to impersonate the SA ---
echo ""
echo "--- Granting caller serviceAccountTokenCreator ---"
CALLER_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --member="user:${CALLER_ACCOUNT}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="${PROJECT_ID}" \
  --quiet >/dev/null
echo "Caller '${CALLER_ACCOUNT}' can now impersonate '${SA_EMAIL}'."

# --- Grant Cloud Run Service Agent compute.networkUser ---
echo ""
echo "--- Granting Cloud Run Service Agent roles/compute.networkUser ---"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')"
CR_SA="service-${PROJECT_NUMBER}@serverless-robot-prod.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${CR_SA}" \
  --role="roles/compute.networkUser" \
  --condition=None \
  --quiet >/dev/null
echo "Cloud Run Service Agent granted compute.networkUser."

# --- Summary ---
echo ""
echo "=== Done ==="
echo ""
echo "Service account: ${SA_EMAIL}"
echo ""
echo "To impersonate this SA for setup-infra.sh:"
echo "  gcloud config set auth/impersonate_service_account ${SA_EMAIL}"
echo ""
echo "To stop impersonating:"
echo "  gcloud config unset auth/impersonate_service_account"
