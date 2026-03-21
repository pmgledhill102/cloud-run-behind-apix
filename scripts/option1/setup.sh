#!/usr/bin/env bash
#
# option1/setup.sh — Option A: Internal ALB + Serverless NEG via VPN (~2 min)
#
# Creates: workloads-vpc, HA VPN with BGP, ILB stack, DNS zone
#
# Prerequisites: shared/setup-base.sh completed.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SHARED_DIR}/lib/workloads-vpc.sh"
source "${SHARED_DIR}/lib/ilb-stack.sh"
source "${SHARED_DIR}/lib/apigee-proxy.sh"

echo "=== Option 1: ILB via VPN — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# ============================================================
# Step 1: Create workloads-vpc + subnets + firewall
# ============================================================
echo ""
echo "--- Step 1: workloads-vpc ---"
create_workloads_vpc

# VPN-specific firewall: allow VPN traffic from apigee subnet to ILB
if resource_exists gcloud compute firewall-rules describe "allow-vpn-to-ilb-workloads" --project="${PROJECT_ID}"; then
  echo "Firewall rule 'allow-vpn-to-ilb-workloads' already exists, skipping."
else
  gcloud compute firewall-rules create "allow-vpn-to-ilb-workloads" \
    --network=workloads-vpc \
    --allow=tcp \
    --source-ranges="10.0.0.0/24" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule 'allow-vpn-to-ilb-workloads' created."
fi

# ============================================================
# Step 2: Create HA VPN
# ============================================================
echo ""
echo "--- Step 2: HA VPN with BGP ---"

# Cloud Routers
if resource_exists gcloud compute routers describe "router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router 'router-apigee' already exists, skipping."
else
  gcloud compute routers create "router-apigee" \
    --network="${APIGEE_NETWORK}" \
    --region="${REGION}" \
    --asn=64512 \
    --project="${PROJECT_ID}"
  echo "Cloud Router 'router-apigee' (ASN 64512) created."
fi

if resource_exists gcloud compute routers describe "router-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router 'router-workloads' already exists, skipping."
else
  gcloud compute routers create "router-workloads" \
    --network=workloads-vpc \
    --region="${REGION}" \
    --asn=64513 \
    --project="${PROJECT_ID}"
  echo "Cloud Router 'router-workloads' (ASN 64513) created."
fi

# Custom route advertisement
gcloud compute routers update "router-workloads" \
  --region="${REGION}" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-groups=ALL_SUBNETS \
  --set-advertisement-ranges=10.100.0.0/24 \
  --project="${PROJECT_ID}"
echo "Custom route advertisement configured."

# VPN Gateways
if resource_exists gcloud compute vpn-gateways describe "vpn-gw-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "VPN gateway 'vpn-gw-apigee' already exists, skipping."
else
  gcloud compute vpn-gateways create "vpn-gw-apigee" \
    --network="${APIGEE_NETWORK}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "VPN gateway 'vpn-gw-apigee' created."
fi

if resource_exists gcloud compute vpn-gateways describe "vpn-gw-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "VPN gateway 'vpn-gw-workloads' already exists, skipping."
else
  gcloud compute vpn-gateways create "vpn-gw-workloads" \
    --network=workloads-vpc \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "VPN gateway 'vpn-gw-workloads' created."
fi

# VPN Tunnels
SHARED_SECRET="$(openssl rand -base64 24)"

for dir_gw_peer_iface in \
  "apigee:vpn-gw-apigee:vpn-gw-workloads:router-apigee:0" \
  "apigee:vpn-gw-apigee:vpn-gw-workloads:router-apigee:1" \
  "workloads:vpn-gw-workloads:vpn-gw-apigee:router-workloads:0" \
  "workloads:vpn-gw-workloads:vpn-gw-apigee:router-workloads:1"; do
  IFS=: read -r dir gw peer router iface <<< "${dir_gw_peer_iface}"
  tunnel="vpn-tunnel-${dir}-if${iface}"
  if resource_exists gcloud compute vpn-tunnels describe "${tunnel}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "VPN tunnel '${tunnel}' already exists, skipping."
  else
    gcloud compute vpn-tunnels create "${tunnel}" \
      --region="${REGION}" \
      --vpn-gateway="${gw}" \
      --peer-gcp-gateway="${peer}" \
      --shared-secret="${SHARED_SECRET}" \
      --router="${router}" \
      --ike-version=2 \
      --interface="${iface}" \
      --project="${PROJECT_ID}"
    echo "VPN tunnel '${tunnel}' created."
  fi
done

# BGP peers on router-apigee
for idx_local_remote in "0:169.254.0.1:169.254.0.2" "1:169.254.1.1:169.254.1.2"; do
  IFS=: read -r idx local_ip remote_ip <<< "${idx_local_remote}"
  if_name="bgp-if${idx}"
  peer_name="bgp-peer-workloads-${idx}"

  if gcloud compute routers describe "router-apigee" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(interfaces[].name)" 2>/dev/null | grep -q "${if_name}"; then
    echo "Interface '${if_name}' already exists on router-apigee, skipping."
  else
    gcloud compute routers add-interface "router-apigee" \
      --region="${REGION}" \
      --interface-name="${if_name}" \
      --vpn-tunnel="vpn-tunnel-apigee-if${idx}" \
      --ip-address="${local_ip}" \
      --mask-length=30 \
      --project="${PROJECT_ID}"
    echo "Interface '${if_name}' added to router-apigee."
  fi

  if gcloud compute routers describe "router-apigee" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(bgpPeers[].name)" 2>/dev/null | grep -q "${peer_name}"; then
    echo "BGP peer '${peer_name}' already exists on router-apigee, skipping."
  else
    gcloud compute routers add-bgp-peer "router-apigee" \
      --region="${REGION}" \
      --peer-name="${peer_name}" \
      --interface="${if_name}" \
      --peer-ip-address="${remote_ip}" \
      --peer-asn=64513 \
      --project="${PROJECT_ID}"
    echo "BGP peer '${peer_name}' added to router-apigee."
  fi
done

# BGP peers on router-workloads
for idx_local_remote in "0:169.254.0.2:169.254.0.1" "1:169.254.1.2:169.254.1.1"; do
  IFS=: read -r idx local_ip remote_ip <<< "${idx_local_remote}"
  if_name="bgp-if${idx}"
  peer_name="bgp-peer-apigee-${idx}"

  if gcloud compute routers describe "router-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(interfaces[].name)" 2>/dev/null | grep -q "${if_name}"; then
    echo "Interface '${if_name}' already exists on router-workloads, skipping."
  else
    gcloud compute routers add-interface "router-workloads" \
      --region="${REGION}" \
      --interface-name="${if_name}" \
      --vpn-tunnel="vpn-tunnel-workloads-if${idx}" \
      --ip-address="${local_ip}" \
      --mask-length=30 \
      --project="${PROJECT_ID}"
    echo "Interface '${if_name}' added to router-workloads."
  fi

  if gcloud compute routers describe "router-workloads" \
      --region="${REGION}" --project="${PROJECT_ID}" \
      --format="value(bgpPeers[].name)" 2>/dev/null | grep -q "${peer_name}"; then
    echo "BGP peer '${peer_name}' already exists on router-workloads, skipping."
  else
    gcloud compute routers add-bgp-peer "router-workloads" \
      --region="${REGION}" \
      --peer-name="${peer_name}" \
      --interface="${if_name}" \
      --peer-ip-address="${remote_ip}" \
      --peer-asn=64512 \
      --project="${PROJECT_ID}"
    echo "BGP peer '${peer_name}' added to router-workloads."
  fi
done

# Wait for tunnels
echo ""
echo "Waiting for VPN tunnels to establish..."
for attempt in $(seq 1 12); do
  status0="$(gcloud compute vpn-tunnels describe vpn-tunnel-apigee-if0 \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format='value(status)' 2>/dev/null || echo 'UNKNOWN')"
  status1="$(gcloud compute vpn-tunnels describe vpn-tunnel-apigee-if1 \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format='value(status)' 2>/dev/null || echo 'UNKNOWN')"
  echo "  Tunnel 0: ${status0}, Tunnel 1: ${status1} (attempt ${attempt}/12)"
  if [[ "${status0}" == "ESTABLISHED" && "${status1}" == "ESTABLISHED" ]]; then
    echo "All tunnels ESTABLISHED."
    break
  fi
  if [[ ${attempt} -lt 12 ]]; then
    sleep 10
  else
    echo "WARNING: Tunnels not yet ESTABLISHED. BGP may need more time."
  fi
done

# ============================================================
# Step 3: Create ILB stack
# ============================================================
echo ""
echo "--- Step 3: ILB stack ---"
create_ilb_stack

# ============================================================
# Step 4: DNS zone + A record
# ============================================================
echo ""
echo "--- Step 4: DNS ---"

if resource_exists gcloud dns managed-zones describe "api-internal-zone" --project="${PROJECT_ID}"; then
  echo "DNS zone 'api-internal-zone' already exists, skipping."
else
  gcloud dns managed-zones create "api-internal-zone" \
    --dns-name="api.internal.example.com." \
    --visibility=private \
    --networks="${APIGEE_NETWORK}" \
    --description="Route api.internal.example.com to ILB in workloads-vpc" \
    --project="${PROJECT_ID}"
  echo "DNS zone 'api-internal-zone' created."
fi

if gcloud dns record-sets describe "api.internal.example.com." \
    --zone="api-internal-zone" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  echo "DNS record 'api.internal.example.com' already exists, skipping."
else
  gcloud dns record-sets create "api.internal.example.com." \
    --zone="api-internal-zone" \
    --type=A \
    --ttl=300 \
    --rrdatas="10.100.0.10" \
    --project="${PROJECT_ID}"
  echo "DNS record 'api.internal.example.com -> 10.100.0.10' created."
fi

# ============================================================
# Step 5: Update Apigee proxy target (optional)
# ============================================================
echo ""
SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"
update_apigee_proxy_target "https://api.internal.example.com/" --ssl-ignore --audience="${SERVICE_URL}"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Option 1 setup complete ==="
echo ""
echo "Traffic flow: VM → VPN → ILB (10.100.0.10:443) → Cloud Run"
echo ""
echo "Run ./scripts/option1/test.sh to verify."
