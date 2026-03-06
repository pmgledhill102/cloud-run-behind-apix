#!/usr/bin/env bash
#
# setup-infra.sh — Create base infrastructure (idempotent)
#
# Creates VPC, subnet, firewall rules, Artifact Registry,
# container image, VM, and Cloud Run service.
#
# Run this as the service account created by setup-iam.sh:
#   gcloud config set auth/impersonate_service_account apigee-pga-poc@PROJECT.iam.gserviceaccount.com
#
# After this, run setup-dns.sh for PGA DNS configuration.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="apigee-pga-poc"
IMAGE_NAME="http-server"
IMAGE_TAG="latest"
IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Setup Infrastructure for project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

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
    --description="Apigee PGA PoC container images" \
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
  docker build --platform linux/amd64 -t "${IMAGE_URL}" "${SCRIPT_DIR}/container"
  docker push "${IMAGE_URL}"
  echo "Image pushed to ${IMAGE_URL}"
fi

# ============================================================
# Step 3: Create VPC network
# ============================================================
echo ""
echo "--- Step 3: Create VPC network ---"
if resource_exists gcloud compute networks describe "apigee-vpc" --project="${PROJECT_ID}"; then
  echo "VPC 'apigee-vpc' already exists, skipping."
else
  gcloud compute networks create "apigee-vpc" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC 'apigee-vpc' created."
fi

# ============================================================
# Step 4: Create subnet
# ============================================================
echo ""
echo "--- Step 4: Create subnet ---"
if resource_exists gcloud compute networks subnets describe "compute-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet 'compute-apigee' already exists, skipping."
else
  gcloud compute networks subnets create "compute-apigee" \
    --network=apigee-vpc \
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
# Step 5: Firewall rules
# ============================================================
echo ""
echo "--- Step 5: Create firewall rules ---"

# Allow IAP SSH
if resource_exists gcloud compute firewall-rules describe "allow-iap-ssh-apigee" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-iap-ssh-apigee' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-iap-ssh-apigee" \
    --network=apigee-vpc \
    --allow=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-iap-ssh-apigee' created."
fi

# Allow internal traffic
if resource_exists gcloud compute firewall-rules describe "allow-internal-apigee" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-internal-apigee' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-internal-apigee" \
    --network=apigee-vpc \
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
    --allow-unauthenticated \
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
    --network=apigee-vpc \
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
    --network-interface=network=apigee-vpc,subnet=compute-apigee,no-address \
    --metadata=startup-script='#!/bin/bash
apt-get update -qq && apt-get install -yqq dnsutils >/dev/null 2>&1' \
    --project="${PROJECT_ID}"
  echo "Instance 'vm-test' created."
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Infrastructure setup complete ==="
echo ""
echo "VPC: apigee-vpc"
echo "Subnet: compute-apigee (10.0.0.0/24)"
echo "VM: vm-test (apigee-vpc/compute-apigee)"
echo "Cloud Run: cr-hello"

SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || echo 'unknown')"
echo "Cloud Run URL: ${SERVICE_URL}"

echo ""
echo "Next: run ./setup-dns.sh to create the DNS zone for PGA."
