#!/usr/bin/env bash
#
# option4/teardown.sh — Tear down Option 4 resources (idempotent)
#
# Deletes: Apigee endpoint attachment, DNS, PSC endpoint, Service Attachment,
# ILB stack, PSC NAT firewall/subnet, workloads-vpc.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SHARED_DIR}/lib/workloads-vpc.sh"
source "${SHARED_DIR}/lib/ilb-stack.sh"

ENDPOINT_ATTACHMENT_ID="ea-cr-hello"

echo "=== Option 4 Teardown — project: ${PROJECT_ID} ==="
echo ""

FAILED_RESOURCES=()

# ============================================================
# Step 1: Delete Apigee endpoint attachment (if present)
# ============================================================
echo "--- Step 1: Delete Apigee endpoint attachment ---"
TOKEN="$(gcloud auth print-access-token)"
APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${TOKEN}" \
  "${APIGEE_API}/organizations/${PROJECT_ID}/endpointAttachments/${ENDPOINT_ATTACHMENT_ID}")"

if [[ "${APIGEE_HTTP}" == "200" ]]; then
  echo "Deleting endpoint attachment '${ENDPOINT_ATTACHMENT_ID}'..."
  curl -s -X DELETE \
    -H "Authorization: Bearer ${TOKEN}" \
    "${APIGEE_API}/organizations/${PROJECT_ID}/endpointAttachments/${ENDPOINT_ATTACHMENT_ID}" \
    >/dev/null 2>&1 || true

  # Wait for deletion
  TIMEOUT=300
  INTERVAL=15
  ELAPSED=0
  while (( ELAPSED < TIMEOUT )); do
    TOKEN="$(gcloud auth print-access-token)"
    CHECK_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      "${APIGEE_API}/organizations/${PROJECT_ID}/endpointAttachments/${ENDPOINT_ATTACHMENT_ID}")"
    if [[ "${CHECK_HTTP}" == "404" ]]; then
      break
    fi
    echo "  Still deleting (${ELAPSED}s elapsed)..."
    sleep "${INTERVAL}"
    ELAPSED=$((ELAPSED + INTERVAL))
  done
  echo "Endpoint attachment deleted."
else
  echo "Endpoint attachment does not exist, skipping."
fi

# ============================================================
# Step 2: Delete DNS
# ============================================================
echo ""
echo "--- Step 2: Delete DNS ---"

if gcloud dns record-sets describe "api.internal.example.com." \
    --zone="api-internal-zone" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  gcloud dns record-sets delete "api.internal.example.com." \
    --zone="api-internal-zone" --type=A --project="${PROJECT_ID}" --quiet
  echo "DNS record 'api.internal.example.com' deleted."
else
  echo "DNS record 'api.internal.example.com' does not exist, skipping."
fi

if resource_exists gcloud dns managed-zones describe "api-internal-zone" --project="${PROJECT_ID}"; then
  gcloud dns managed-zones delete "api-internal-zone" --project="${PROJECT_ID}" --quiet
  echo "DNS zone 'api-internal-zone' deleted."
else
  echo "DNS zone 'api-internal-zone' does not exist, skipping."
fi

# ============================================================
# Step 3: Delete PSC endpoint
# ============================================================
echo ""
echo "--- Step 3: Delete PSC endpoint ---"

if resource_exists gcloud compute forwarding-rules describe "psc-endpoint-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute forwarding-rules delete "psc-endpoint-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "PSC endpoint 'psc-endpoint-apigee' deleted."
else
  echo "PSC endpoint 'psc-endpoint-apigee' does not exist, skipping."
fi

if resource_exists gcloud compute addresses describe "psc-consumer-ip" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute addresses delete "psc-consumer-ip" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Address 'psc-consumer-ip' deleted."
else
  echo "Address 'psc-consumer-ip' does not exist, skipping."
fi

# ============================================================
# Step 4: Delete Service Attachment
# ============================================================
echo ""
echo "--- Step 4: Delete Service Attachment ---"
if resource_exists gcloud compute service-attachments describe "sa-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute service-attachments delete "sa-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Service Attachment 'sa-workloads' deleted."
else
  echo "Service Attachment 'sa-workloads' does not exist, skipping."
fi

# ============================================================
# Step 5: Delete ILB stack
# ============================================================
echo ""
echo "--- Step 5: Delete ILB stack ---"
delete_ilb_stack

# ============================================================
# Step 6: Delete PSC NAT resources
# ============================================================
echo ""
echo "--- Step 6: Delete PSC NAT resources ---"

if resource_exists gcloud compute firewall-rules describe "allow-psc-nat-to-ilb-workloads" --project="${PROJECT_ID}"; then
  gcloud compute firewall-rules delete "allow-psc-nat-to-ilb-workloads" --project="${PROJECT_ID}" --quiet
  echo "Firewall rule 'allow-psc-nat-to-ilb-workloads' deleted."
else
  echo "Firewall rule 'allow-psc-nat-to-ilb-workloads' does not exist, skipping."
fi

if resource_exists gcloud compute networks subnets describe "psc-nat-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  delete_subnet_with_retry "psc-nat-workloads"
else
  echo "Subnet 'psc-nat-workloads' does not exist, skipping."
fi

# ============================================================
# Step 7: Delete workloads-vpc
# ============================================================
echo ""
echo "--- Step 7: Delete workloads-vpc ---"
delete_workloads_vpc

echo ""
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo "=== Option 4 teardown complete (with warnings) ==="
  echo ""
  for res in "${FAILED_RESOURCES[@]}"; do
    echo "  - ${res}"
  done
else
  echo "=== Option 4 teardown complete ==="
fi
