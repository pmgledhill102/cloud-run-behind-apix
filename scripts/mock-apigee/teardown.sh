#!/usr/bin/env bash
#
# mock-apigee/teardown.sh — Full reverse of mock-apigee/setup.sh (~1-2 min)
#
# Removes: gateway VM, gateway image, NAT + router, restricted-VIP route,
# run-app-mock DNS zone (records first), both peerings, firewalls, subnet,
# mock VPC. Idempotent — every step skips what's already gone.
#
# Usage:
#   PROJECT_ID=<your-project> ./scripts/mock-apigee/teardown.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/../auth/env-auth.sh"
source "${SCRIPT_DIR}/env-mock.sh"

FAILED_RESOURCES=()

echo "=== Mock-Apigee teardown — project: ${PROJECT_ID} ==="
echo ""

echo "--- Step 1: Delete gateway VM ---"
if resource_exists gcloud compute instances describe "${MOCK_GW_VM}" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  gcloud compute instances delete "${MOCK_GW_VM}" \
    --zone="${ZONE}" --project="${PROJECT_ID}" --quiet
  echo "Instance '${MOCK_GW_VM}' deleted."
else
  echo "Instance '${MOCK_GW_VM}' not found, skipping."
fi

echo ""
echo "--- Step 2: Delete gateway image ---"
if gcloud artifacts docker images describe "${GW_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud artifacts docker images delete "${GW_IMAGE_URL}" \
    --delete-tags --project="${PROJECT_ID}" --quiet
  echo "Image '${GW_IMAGE_URL}' deleted."
else
  echo "Image '${GW_IMAGE_URL}' not found, skipping."
fi

echo ""
echo "--- Step 3: Delete Cloud NAT + router ---"
if gcloud compute routers nats describe "${MOCK_NAT}" \
    --router="${MOCK_ROUTER}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  gcloud compute routers nats delete "${MOCK_NAT}" \
    --router="${MOCK_ROUTER}" --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "NAT '${MOCK_NAT}' deleted."
else
  echo "NAT '${MOCK_NAT}' not found, skipping."
fi
if resource_exists gcloud compute routers describe "${MOCK_ROUTER}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  gcloud compute routers delete "${MOCK_ROUTER}" \
    --region="${REGION}" --project="${PROJECT_ID}" --quiet
  echo "Router '${MOCK_ROUTER}' deleted."
else
  echo "Router '${MOCK_ROUTER}' not found, skipping."
fi

echo ""
echo "--- Step 4: Delete restricted-VIP route ---"
if resource_exists gcloud compute routes describe "${MOCK_ROUTE}" --project="${PROJECT_ID}"; then
  gcloud compute routes delete "${MOCK_ROUTE}" --project="${PROJECT_ID}" --quiet
  echo "Route '${MOCK_ROUTE}' deleted."
else
  echo "Route '${MOCK_ROUTE}' not found, skipping."
fi

echo ""
echo "--- Step 5: Delete DNS zone (records first) ---"
if resource_exists gcloud dns managed-zones describe "${MOCK_DNS_ZONE}" --project="${PROJECT_ID}"; then
  for record in "*.run.app." "run.app."; do
    if gcloud dns record-sets describe "${record}" --type=A \
        --zone="${MOCK_DNS_ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
      gcloud dns record-sets delete "${record}" --type=A \
        --zone="${MOCK_DNS_ZONE}" --project="${PROJECT_ID}"
      echo "DNS record '${record}' deleted."
    fi
  done
  gcloud dns managed-zones delete "${MOCK_DNS_ZONE}" --project="${PROJECT_ID}"
  echo "DNS zone '${MOCK_DNS_ZONE}' deleted."
else
  echo "DNS zone '${MOCK_DNS_ZONE}' not found, skipping."
fi

echo ""
echo "--- Step 6: Delete peerings ---"
# peering_exists <network> <peering-name>
# (peerings list --format='value(name)' prints the NETWORK name — describe
#  the network and read peerings[].name instead. Deleting a VPC silently
#  removes its own peerings but leaves a dangling entry on the peer network,
#  so this step must run BEFORE the VPC delete and catch strays on re-runs.)
peering_exists() {
  gcloud compute networks describe "$1" --project="${PROJECT_ID}" \
    --format='value(peerings[].name)' 2>/dev/null | tr ';' '\n' | grep -qx "$2"
}
if peering_exists "${APIGEE_NETWORK}" "${PEERING_APIGEE_TO_MOCK}"; then
  gcloud compute networks peerings delete "${PEERING_APIGEE_TO_MOCK}" \
    --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}"
  echo "Peering '${PEERING_APIGEE_TO_MOCK}' deleted."
else
  echo "Peering '${PEERING_APIGEE_TO_MOCK}' not found, skipping."
fi
if peering_exists "${MOCK_VPC}" "${PEERING_MOCK_TO_APIGEE}"; then
  gcloud compute networks peerings delete "${PEERING_MOCK_TO_APIGEE}" \
    --network="${MOCK_VPC}" --project="${PROJECT_ID}"
  echo "Peering '${PEERING_MOCK_TO_APIGEE}' deleted."
else
  echo "Peering '${PEERING_MOCK_TO_APIGEE}' not found, skipping."
fi

echo ""
echo "--- Step 7: Delete firewalls ---"
for fw in "${FW_MOCK_IAP_SSH}" "${FW_MOCK_INGRESS}"; do
  if resource_exists gcloud compute firewall-rules describe "${fw}" --project="${PROJECT_ID}"; then
    gcloud compute firewall-rules delete "${fw}" --project="${PROJECT_ID}" --quiet
    echo "Firewall rule '${fw}' deleted."
  else
    echo "Firewall rule '${fw}' not found, skipping."
  fi
done

echo ""
echo "--- Step 8: Delete subnet + VPC ---"
if resource_exists gcloud compute networks subnets describe "${MOCK_SUBNET}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  delete_subnet_with_retry "${MOCK_SUBNET}"
else
  echo "Subnet '${MOCK_SUBNET}' not found, skipping."
fi
if resource_exists gcloud compute networks describe "${MOCK_VPC}" --project="${PROJECT_ID}"; then
  gcloud compute networks delete "${MOCK_VPC}" --project="${PROJECT_ID}" --quiet
  echo "VPC '${MOCK_VPC}' deleted."
else
  echo "VPC '${MOCK_VPC}' not found, skipping."
fi

echo ""
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo "=== Mock-Apigee teardown finished with warnings: ${FAILED_RESOURCES[*]} ==="
else
  echo "=== Mock-Apigee teardown complete ==="
fi
