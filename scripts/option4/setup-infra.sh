#!/usr/bin/env bash
#
# setup-infra.sh — Create base infrastructure (idempotent)
#
# Creates two VPCs (apigee-vpc and workloads-vpc), subnets, firewall rules,
# Artifact Registry, container image, Cloud Run service, Cloud NAT, and VM.
#
# Run this as the service account created by setup-iam.sh:
#   gcloud config set auth/impersonate_service_account apigee-psc-sa-poc@PROJECT.iam.gserviceaccount.com
#
# After this, run setup-psc.sh for ILB, Service Attachment, and PSC endpoint.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"
ZONE="${REGION}-a"
REPO_NAME="apigee-psc-sa-poc"
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
# Step 1: Artifact Registry + build container
# ============================================================
echo "--- Step 1: Artifact Registry ---"
if resource_exists gcloud artifacts repositories describe "${REPO_NAME}" \
    --location="${REGION}" --project="${PROJECT_ID}"; then
  echo "Repository '${REPO_NAME}' already exists, skipping."
else
  gcloud artifacts repositories create "${REPO_NAME}" \
    --repository-format=docker \
    --location="${REGION}" \
    --description="Apigee PSC Service Attachment PoC container images" \
    --project="${PROJECT_ID}"
  echo "Repository '${REPO_NAME}' created."
fi

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
# Step 2: Create VPC apigee-vpc
# ============================================================
echo ""
echo "--- Step 2: Create VPC apigee-vpc ---"
if resource_exists gcloud compute networks describe "apigee-vpc" --project="${PROJECT_ID}"; then
  echo "VPC 'apigee-vpc' already exists, skipping."
else
  gcloud compute networks create "apigee-vpc" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC 'apigee-vpc' created."
fi

# ============================================================
# Step 3: Create subnet compute-apigee
# ============================================================
echo ""
echo "--- Step 3: Create subnet compute-apigee ---"
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

# ============================================================
# Step 4: Create VPC workloads-vpc
# ============================================================
echo ""
echo "--- Step 4: Create VPC workloads-vpc ---"
if resource_exists gcloud compute networks describe "workloads-vpc" --project="${PROJECT_ID}"; then
  echo "VPC 'workloads-vpc' already exists, skipping."
else
  gcloud compute networks create "workloads-vpc" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC 'workloads-vpc' created."
fi

# ============================================================
# Step 5: Create subnet compute-workloads
# ============================================================
echo ""
echo "--- Step 5: Create subnet compute-workloads ---"
if resource_exists gcloud compute networks subnets describe "compute-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet 'compute-workloads' already exists, skipping."
else
  gcloud compute networks subnets create "compute-workloads" \
    --network=workloads-vpc \
    --range="10.100.0.0/24" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Subnet 'compute-workloads' (10.100.0.0/24) created."
fi

# ============================================================
# Step 6: Create proxy-only subnet
# ============================================================
echo ""
echo "--- Step 6: Create subnet proxy-only-workloads ---"
if resource_exists gcloud compute networks subnets describe "proxy-only-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet 'proxy-only-workloads' already exists, skipping."
else
  gcloud compute networks subnets create "proxy-only-workloads" \
    --network=workloads-vpc \
    --range="10.100.64.0/24" \
    --region="${REGION}" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --project="${PROJECT_ID}"
  echo "Subnet 'proxy-only-workloads' (10.100.64.0/24) created."
fi

# ============================================================
# Step 7: Create PSC NAT subnet
# ============================================================
echo ""
echo "--- Step 7: Create subnet psc-nat-workloads ---"
if resource_exists gcloud compute networks subnets describe "psc-nat-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet 'psc-nat-workloads' already exists, skipping."
else
  gcloud compute networks subnets create "psc-nat-workloads" \
    --network=workloads-vpc \
    --range="10.100.2.0/24" \
    --region="${REGION}" \
    --purpose=PRIVATE_SERVICE_CONNECT \
    --project="${PROJECT_ID}"
  echo "Subnet 'psc-nat-workloads' (10.100.2.0/24) created."
fi

# ============================================================
# Step 8: Firewall rules
# ============================================================
echo ""
echo "--- Step 8: Create firewall rules ---"

# Allow IAP SSH (apigee-vpc)
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

# Allow internal traffic (apigee-vpc)
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

# Allow health checks (workloads-vpc)
if resource_exists gcloud compute firewall-rules describe "allow-health-check-workloads" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-health-check-workloads' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-health-check-workloads" \
    --network=workloads-vpc \
    --allow=tcp \
    --source-ranges="130.211.0.0/22,35.191.0.0/16" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-health-check-workloads' created."
fi

# Allow proxy-only subnet to backends (workloads-vpc)
if resource_exists gcloud compute firewall-rules describe "allow-proxy-to-backend-workloads" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-proxy-to-backend-workloads' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-proxy-to-backend-workloads" \
    --network=workloads-vpc \
    --allow=tcp \
    --source-ranges="10.100.64.0/24" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-proxy-to-backend-workloads' created."
fi

# Allow PSC NAT to ILB (workloads-vpc)
if resource_exists gcloud compute firewall-rules describe "allow-psc-nat-to-ilb-workloads" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-psc-nat-to-ilb-workloads' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-psc-nat-to-ilb-workloads" \
    --network=workloads-vpc \
    --allow=tcp \
    --source-ranges="10.100.2.0/24" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-psc-nat-to-ilb-workloads' created."
fi

# ============================================================
# Step 9: Deploy Cloud Run service
# ============================================================
echo ""
echo "--- Step 9: Deploy Cloud Run service ---"
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
# Step 10: Cloud NAT (internet access for VM)
# ============================================================
echo ""
echo "--- Step 10: Configure Cloud NAT ---"

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
# Step 11: Create Compute VM (test client)
# ============================================================
echo ""
echo "--- Step 11: Create Compute VM ---"
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
echo "  Subnet: compute-apigee (10.0.0.0/24)"
echo ""
echo "VPC: workloads-vpc"
echo "  Subnet: compute-workloads (10.100.0.0/24)"
echo "  Subnet: proxy-only-workloads (10.100.64.0/24, REGIONAL_MANAGED_PROXY)"
echo "  Subnet: psc-nat-workloads (10.100.2.0/24, PRIVATE_SERVICE_CONNECT)"
echo ""
echo "VM: vm-test (apigee-vpc/compute-apigee)"
echo "Cloud Run: cr-hello"

SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || echo 'unknown')"
echo "Cloud Run URL: ${SERVICE_URL}"

echo ""
echo "Next: run ./setup-psc.sh to create ILB, Service Attachment, and PSC endpoint."
