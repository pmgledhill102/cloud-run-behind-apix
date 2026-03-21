#!/usr/bin/env bash
#
# option1/teardown.sh — Tear down Option 1 resources (idempotent)
#
# Deletes: DNS, ILB stack, VPN (BGP, tunnels, gateways, routers),
# VPN firewall rule, workloads-vpc.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SHARED_DIR}/lib/workloads-vpc.sh"
source "${SHARED_DIR}/lib/ilb-stack.sh"

echo "=== Option 1 Teardown — project: ${PROJECT_ID} ==="
echo ""

FAILED_RESOURCES=()

# ============================================================
# Step 1: Delete DNS
# ============================================================
echo "--- Step 1: Delete DNS ---"

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
# Step 2: Delete ILB stack
# ============================================================
echo ""
echo "--- Step 2: Delete ILB stack ---"
delete_ilb_stack

# ============================================================
# Step 3: Delete BGP peers + interfaces
# ============================================================
echo ""
echo "--- Step 3: Delete BGP peers + interfaces ---"

for peer in bgp-peer-workloads-0 bgp-peer-workloads-1; do
  gcloud compute routers remove-bgp-peer "router-apigee" \
    --region="${REGION}" --peer-name="${peer}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
  echo "  ${peer} removed (or did not exist)."
done
for iface in bgp-if0 bgp-if1; do
  gcloud compute routers remove-interface "router-apigee" \
    --region="${REGION}" --interface-name="${iface}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
  echo "  router-apigee ${iface} removed (or did not exist)."
done

for peer in bgp-peer-apigee-0 bgp-peer-apigee-1; do
  gcloud compute routers remove-bgp-peer "router-workloads" \
    --region="${REGION}" --peer-name="${peer}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
  echo "  ${peer} removed (or did not exist)."
done
for iface in bgp-if0 bgp-if1; do
  gcloud compute routers remove-interface "router-workloads" \
    --region="${REGION}" --interface-name="${iface}" --project="${PROJECT_ID}" --quiet 2>/dev/null || true
  echo "  router-workloads ${iface} removed (or did not exist)."
done

# ============================================================
# Step 4: Delete VPN tunnels
# ============================================================
echo ""
echo "--- Step 4: Delete VPN tunnels ---"
for tunnel in vpn-tunnel-apigee-if0 vpn-tunnel-apigee-if1 vpn-tunnel-workloads-if0 vpn-tunnel-workloads-if1; do
  if resource_exists gcloud compute vpn-tunnels describe "${tunnel}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute vpn-tunnels delete "${tunnel}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "VPN tunnel '${tunnel}' deleted."
  else
    echo "VPN tunnel '${tunnel}' does not exist, skipping."
  fi
done

# ============================================================
# Step 5: Delete VPN gateways
# ============================================================
echo ""
echo "--- Step 5: Delete VPN gateways ---"
for gw in vpn-gw-apigee vpn-gw-workloads; do
  if resource_exists gcloud compute vpn-gateways describe "${gw}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute vpn-gateways delete "${gw}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "VPN gateway '${gw}' deleted."
  else
    echo "VPN gateway '${gw}' does not exist, skipping."
  fi
done

# ============================================================
# Step 6: Delete Cloud Routers (VPN-specific)
# ============================================================
echo ""
echo "--- Step 6: Delete VPN Cloud Routers ---"
for router in router-apigee router-workloads; do
  if resource_exists gcloud compute routers describe "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud compute routers delete "${router}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Cloud Router '${router}' deleted."
  else
    echo "Cloud Router '${router}' does not exist, skipping."
  fi
done

# ============================================================
# Step 7: Delete VPN-specific firewall rule
# ============================================================
echo ""
echo "--- Step 7: Delete VPN firewall rule ---"
if resource_exists gcloud compute firewall-rules describe "allow-vpn-to-ilb-workloads" --project="${PROJECT_ID}"; then
  gcloud compute firewall-rules delete "allow-vpn-to-ilb-workloads" --project="${PROJECT_ID}" --quiet
  echo "Firewall rule 'allow-vpn-to-ilb-workloads' deleted."
else
  echo "Firewall rule 'allow-vpn-to-ilb-workloads' does not exist, skipping."
fi

# ============================================================
# Step 8: Delete workloads-vpc
# ============================================================
echo ""
echo "--- Step 8: Delete workloads-vpc ---"
delete_workloads_vpc

echo ""
if [[ ${#FAILED_RESOURCES[@]} -gt 0 ]]; then
  echo "=== Option 1 teardown complete (with warnings) ==="
  echo ""
  for res in "${FAILED_RESOURCES[@]}"; do
    echo "  - ${res}"
  done
else
  echo "=== Option 1 teardown complete ==="
fi
