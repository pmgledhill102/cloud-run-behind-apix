#!/usr/bin/env bash
#
# setup-iam.sh — Create service account and bind IAM roles
#
# Single service account (apigee-poc) with superset of all roles needed
# by any option. Run this once with a privileged account (Owner or IAM Admin).
#
# Usage:
#   ./scripts/shared/setup-iam.sh
#   PROJECT_ID=my-project ./scripts/shared/setup-iam.sh
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

echo "=== Setup IAM for project: ${PROJECT_ID} ==="
echo "Service account: ${SA_EMAIL}"
echo ""

# --- Enable APIs ---
echo "--- Enabling APIs ---"
gcloud services enable \
  apigee.googleapis.com \
  compute.googleapis.com \
  servicenetworking.googleapis.com \
  cloudkms.googleapis.com \
  run.googleapis.com \
  dns.googleapis.com \
  iap.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iamcredentials.googleapis.com \
  --project="${PROJECT_ID}"
echo "APIs enabled."

# --- Create service account ---
echo ""
echo "--- Creating service account ---"
if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Service account already exists, skipping."
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="Apigee PoC" \
    --description="Service account for Apigee-to-Cloud-Run PoC (all options)" \
    --project="${PROJECT_ID}"
  echo "Service account created."
fi

# --- Bind IAM roles (superset of all options) ---
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

# --- Grant caller permission to deploy proxies as the SA ---
# Deploying an Apigee proxy with a GoogleIDToken <Authentication> block requires
# the deployer to have iam.serviceAccounts.actAs on the SA passed to the
# deployment (roles/iam.serviceAccountUser); tokenCreator alone is not enough.
echo ""
echo "--- Granting caller serviceAccountUser ---"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --member="user:${CALLER_ACCOUNT}" \
  --role="roles/iam.serviceAccountUser" \
  --project="${PROJECT_ID}" \
  --quiet >/dev/null
echo "Caller '${CALLER_ACCOUNT}' can now deploy Apigee proxies as '${SA_EMAIL}'."

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

# --- Grant Apigee runtime SA Cloud Run invoker ---
# NOTE: The Apigee runtime service agent (gcp-sa-apigee-mp) only exists once the
# Apigee org has been provisioned (setup-slow.sh). On a greenfield project this
# grant will fail because the SA does not exist yet, so it is non-fatal here —
# setup-slow.sh re-applies it after the org becomes ACTIVE.
echo ""
echo "--- Granting Apigee runtime SA roles/run.invoker ---"
APIGEE_RUNTIME_SA="service-${PROJECT_NUMBER}@gcp-sa-apigee-mp.iam.gserviceaccount.com"
if gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${APIGEE_RUNTIME_SA}" \
  --role="roles/run.invoker" \
  --condition=None \
  --quiet >/dev/null 2>&1; then
  echo "Apigee runtime SA granted run.invoker."
else
  echo "SKIPPED: Apigee runtime SA '${APIGEE_RUNTIME_SA}' does not exist yet."
  echo "         setup-slow.sh will grant this once the Apigee org is provisioned."
fi

# --- Grant default compute SA Cloud Run invoker (for test VM) ---
echo ""
echo "--- Granting default compute SA roles/run.invoker ---"
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/run.invoker" \
  --condition=None \
  --quiet >/dev/null
echo "Default compute SA granted run.invoker (for test VM auth)."

# --- Grant Apigee service agent tokenCreator on the PoC SA ---
# Apigee mints GoogleIDToken southbound credentials by impersonating the
# proxy's deploy-time SA via the Apigee service agent
# (service-<num>@gcp-sa-apigee.iam.gserviceaccount.com). Without tokenCreator
# on the SA, target calls fail at runtime with GoogleTokenGenerationFailure.
# Non-fatal: the agent may not exist before Apigee provisioning — re-run this
# script after setup-slow.sh in that case.
echo ""
echo "--- Granting Apigee service agent tokenCreator on ${SA_NAME} ---"
APIGEE_AGENT_SA="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"
if gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --member="serviceAccount:${APIGEE_AGENT_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="${PROJECT_ID}" \
  --quiet >/dev/null 2>&1; then
  echo "Apigee service agent granted tokenCreator on '${SA_EMAIL}'."
else
  echo "SKIPPED: Apigee service agent '${APIGEE_AGENT_SA}' does not exist yet."
  echo "         setup-slow.sh will grant this once Apigee is provisioned."
fi

# --- Grant default compute SA Cloud Build roles ---
# setup-base.sh builds the image with `gcloud builds submit`, which runs as the
# default compute SA. In hardened projects (automatic default-SA grants disabled)
# that SA has no roles, so the build cannot read its source, write logs, or push
# the image. Grant the minimum needed.
echo ""
echo "--- Granting default compute SA Cloud Build roles ---"
for CB_ROLE in roles/storage.objectViewer roles/logging.logWriter roles/artifactregistry.writer; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${COMPUTE_SA}" \
    --role="${CB_ROLE}" \
    --condition=None \
    --quiet >/dev/null
  echo "Default compute SA granted ${CB_ROLE}."
done

# --- Summary ---
echo ""
echo "=== Done ==="
echo ""
echo "Service account: ${SA_EMAIL}"
echo ""
echo "To impersonate this SA for setup scripts:"
echo "  gcloud config set auth/impersonate_service_account ${SA_EMAIL}"
echo ""
echo "To stop impersonating:"
echo "  gcloud config unset auth/impersonate_service_account"
