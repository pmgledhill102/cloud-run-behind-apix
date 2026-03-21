#!/usr/bin/env bash
#
# workloads-vpc.sh — Create/delete workloads-vpc and subnets
#
# Used by options 1 (VPN) and 4 (PSC Service Attachment) which need a
# separate workloads-vpc for the ILB.
#
# Source this after env.sh + helpers.sh:
#   source "${SHARED_DIR}/lib/workloads-vpc.sh"
#

create_workloads_vpc() {
  echo "--- Create workloads-vpc ---"

  # VPC
  if resource_exists gcloud compute networks describe "workloads-vpc" --project="${PROJECT_ID}"; then
    echo "VPC 'workloads-vpc' already exists, skipping."
  else
    gcloud compute networks create "workloads-vpc" \
      --subnet-mode=custom \
      --project="${PROJECT_ID}"
    echo "VPC 'workloads-vpc' created."
  fi

  # Subnet: compute-workloads
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

  # Subnet: proxy-only-workloads (for ILB)
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

  # Firewall: health checks
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

  # Firewall: proxy-only to backend
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

  echo "workloads-vpc ready."
}

delete_workloads_vpc() {
  echo "--- Delete workloads-vpc ---"

  # Firewall rules
  for fw in allow-health-check-workloads allow-proxy-to-backend-workloads; do
    if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
      gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
      echo "Firewall rule '${fw}' deleted."
    else
      echo "Firewall rule '${fw}' does not exist, skipping."
    fi
  done

  # Subnets (reverse order)
  for subnet in proxy-only-workloads compute-workloads; do
    if resource_exists gcloud compute networks subnets describe "${subnet}" \
        --region="${REGION}" --project="${PROJECT_ID}"; then
      delete_subnet_with_retry "${subnet}"
    else
      echo "Subnet '${subnet}' does not exist, skipping."
    fi
  done

  # VPC
  if resource_exists gcloud compute networks describe "workloads-vpc" --project="${PROJECT_ID}"; then
    if gcloud compute networks delete "workloads-vpc" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
      echo "VPC 'workloads-vpc' deleted."
    else
      echo "  WARNING: Could not delete VPC 'workloads-vpc' — subnets may still be releasing."
      FAILED_RESOURCES+=("vpc/workloads-vpc")
    fi
  else
    echo "VPC 'workloads-vpc' does not exist, skipping."
  fi
}
