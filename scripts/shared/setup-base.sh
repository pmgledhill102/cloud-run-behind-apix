#!/usr/bin/env bash
#
# setup-base.sh — Create base infrastructure shared by all options (~5 min)
#
# Creates: apigee-vpc, compute-apigee subnet, firewall rules, Artifact Registry,
# container image, Cloud Run service (cr-hello), Cloud NAT, and test VM.
#
# Run AFTER setup-iam.sh. Can run in parallel with setup-slow.sh — both create
# apigee-vpc idempotently.
#
# Usage:
#   ./scripts/shared/setup-base.sh
#
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

echo "=== Setup Base Infrastructure — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# ============================================================
# Step 1: Artifact Registry
# ============================================================
echo "--- Step 1: Artifact Registry ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  echo "Repository '${REPO_NAME}' already exists, skipping."
else
  gcloud artifacts repositories create "${REPO_NAME}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Apigee PoC container images" \
    --project="${PROJECT_ID}"
  echo "Repository '${REPO_NAME}' created."
fi

# ============================================================
# Step 2: Build and push container image
# ============================================================
echo ""
echo "--- Step 2: Build and push container image ---"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet 2>/dev/null || true

if gcloud artifacts docker images describe "${IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${IMAGE_URL}' already exists, skipping build."
else
  echo "Building image..."
  docker build --platform linux/amd64 -t "${IMAGE_URL}" "${SHARED_DIR}/container"
  docker push "${IMAGE_URL}"
  echo "Image pushed to ${IMAGE_URL}"
fi

# ============================================================
# Step 3: Create VPC (apigee-vpc)
# ============================================================
echo ""
echo "--- Step 3: Create VPC (apigee-vpc) ---"
if resource_exists gcloud compute networks describe "${APIGEE_NETWORK}" --project="${PROJECT_ID}"; then
  echo "VPC '${APIGEE_NETWORK}' already exists, skipping."
else
  gcloud compute networks create "${APIGEE_NETWORK}" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC '${APIGEE_NETWORK}' created."
fi

# ============================================================
# Step 4: Create subnet (compute-apigee)
# ============================================================
echo ""
echo "--- Step 4: Create subnet (compute-apigee) ---"
if resource_exists gcloud compute networks subnets describe "compute-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet 'compute-apigee' already exists, skipping."
else
  gcloud compute networks subnets create "compute-apigee" \
    --network="${APIGEE_NETWORK}" \
    --range="10.0.0.0/24" \
    --region="${REGION}" \
    --enable-private-ip-google-access \
    --project="${PROJECT_ID}"
  echo "Subnet 'compute-apigee' (10.0.0.0/24) created."
fi
# Ensure Private Google Access (idempotent)
gcloud compute networks subnets update "compute-apigee" \
  --region="${REGION}" --enable-private-ip-google-access \
  --project="${PROJECT_ID}" --quiet

# ============================================================
# Step 5: Create firewall rules (apigee-vpc)
# ============================================================
echo ""
echo "--- Step 5: Create firewall rules ---"

if resource_exists gcloud compute firewall-rules describe "allow-iap-ssh-apigee" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-iap-ssh-apigee' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-iap-ssh-apigee" \
    --network="${APIGEE_NETWORK}" \
    --allow=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-iap-ssh-apigee' created."
fi

if resource_exists gcloud compute firewall-rules describe "allow-internal-apigee" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-internal-apigee' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-internal-apigee" \
    --network="${APIGEE_NETWORK}" \
    --allow=tcp,udp,icmp \
    --source-ranges="10.0.0.0/8" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-internal-apigee' created."
fi

# ============================================================
# Step 6: Deploy Cloud Run service
# ============================================================
echo ""
echo "--- Step 6: Deploy Cloud Run service ---"
if resource_exists gcloud run services describe "cr-hello" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Service 'cr-hello' already exists, skipping."
else
  echo "Deploying 'cr-hello'..."
  gcloud run deploy "cr-hello" \
    --image="${IMAGE_URL}" \
    --region="${REGION}" \
    --ingress=internal \
    --max-instances=5 \
    --min-instances=0 \
    --cpu-throttling \
    --no-allow-unauthenticated \
    --project="${PROJECT_ID}" \
    --quiet
  echo "Service 'cr-hello' deployed."
fi

# ============================================================
# Step 7: Cloud NAT (internet access for VM)
# ============================================================
echo ""
echo "--- Step 7: Configure Cloud NAT ---"

if resource_exists gcloud compute routers describe "nat-router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router 'nat-router-apigee' already exists, skipping."
else
  gcloud compute routers create "nat-router-apigee" \
    --network="${APIGEE_NETWORK}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Cloud Router 'nat-router-apigee' created."
fi

if gcloud compute routers nats describe "public-nat-apigee" \
    --router="nat-router-apigee" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "NAT gateway 'public-nat-apigee' already exists, skipping."
else
  gcloud compute routers nats create "public-nat-apigee" \
    --router="nat-router-apigee" \
    --region="${REGION}" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --project="${PROJECT_ID}"
  echo "NAT gateway 'public-nat-apigee' created."
fi

# ============================================================
# Step 8: Create Compute VM (test client)
# ============================================================
echo ""
echo "--- Step 8: Create Compute VM ---"
if resource_exists gcloud compute instances describe "vm-test" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  echo "Instance 'vm-test' already exists, skipping."
else
  gcloud compute instances create "vm-test" \
    --zone="${ZONE}" \
    --machine-type=e2-micro \
    --network-interface=network="${APIGEE_NETWORK}",subnet=compute-apigee,no-address \
    --metadata=startup-script='#!/bin/bash
apt-get update -qq && apt-get install -yqq dnsutils >/dev/null 2>&1' \
    --project="${PROJECT_ID}"
  echo "Instance 'vm-test' created."
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Base infrastructure setup complete ==="
echo ""
echo "VPC: ${APIGEE_NETWORK}"
echo "  Subnet: compute-apigee (10.0.0.0/24)"
echo "VM: vm-test (${APIGEE_NETWORK}/compute-apigee)"
echo "Cloud Run: cr-hello"

SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || echo 'unknown')"
echo "Cloud Run URL: ${SERVICE_URL}"

echo ""
echo "Next steps:"
echo "  - Run ./scripts/shared/setup-slow.sh for Apigee provisioning (~60-90 min)"
echo "  - Run ./scripts/option{1,2,3,4}/setup.sh for option-specific resources"
