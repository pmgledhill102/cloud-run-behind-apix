#!/usr/bin/env bash
#
# setup-vpn.sh — Create HA VPN tunnels with BGP between apigee-vpc and workloads-vpc (idempotent)
#
# This enables routing between the two VPCs so the VM in apigee-vpc
# can reach the ILB in workloads-vpc.
#
# Run this AFTER setup-infra.sh has completed.
# After this, run setup-ilb.sh for the internal HTTPS load balancer.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"

echo "=== Setup HA VPN — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Create Cloud Router (apigee-vpc, ASN 64512)
# ============================================================
echo "--- Step 1: Create Cloud Router (router-apigee) ---"
if resource_exists gcloud compute routers describe "router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router 'router-apigee' already exists, skipping."
else
  gcloud compute routers create "router-apigee" \
    --network=apigee-vpc \
    --region="${REGION}" \
    --asn=64512 \
    --project="${PROJECT_ID}"
  echo "Cloud Router 'router-apigee' (ASN 64512) created."
fi

# ============================================================
# Step 2: Create Cloud Router (workloads-vpc, ASN 64513)
# ============================================================
echo ""
echo "--- Step 2: Create Cloud Router (router-workloads) ---"
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

# Add custom route advertisement for the ILB subnet
echo "Configuring custom route advertisements on router-workloads..."
gcloud compute routers update "router-workloads" \
  --region="${REGION}" \
  --advertisement-mode=CUSTOM \
  --set-advertisement-groups=ALL_SUBNETS \
  --set-advertisement-ranges=10.100.0.0/24 \
  --project="${PROJECT_ID}"
echo "Custom route advertisement configured."

# ============================================================
# Step 3: Create HA VPN gateways
# ============================================================
echo ""
echo "--- Step 3: Create HA VPN gateways ---"

if resource_exists gcloud compute vpn-gateways describe "vpn-gw-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "VPN gateway 'vpn-gw-apigee' already exists, skipping."
else
  gcloud compute vpn-gateways create "vpn-gw-apigee" \
    --network=apigee-vpc \
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

# ============================================================
# Step 4: Generate shared secret
# ============================================================
echo ""
echo "--- Step 4: Generate shared secret ---"
SHARED_SECRET="$(openssl rand -base64 24)"
echo "Shared secret generated (not displayed for security)."

# ============================================================
# Step 5: Create VPN tunnels (4 tunnels for redundancy)
# ============================================================
echo ""
echo "--- Step 5: Create VPN tunnels ---"

# Apigee -> Workloads tunnels
if resource_exists gcloud compute vpn-tunnels describe "vpn-tunnel-apigee-if0" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "VPN tunnel 'vpn-tunnel-apigee-if0' already exists, skipping."
else
  gcloud compute vpn-tunnels create "vpn-tunnel-apigee-if0" \
    --region="${REGION}" \
    --vpn-gateway=vpn-gw-apigee \
    --peer-gcp-gateway=vpn-gw-workloads \
    --shared-secret="${SHARED_SECRET}" \
    --router=router-apigee \
    --ike-version=2 \
    --interface=0 \
    --project="${PROJECT_ID}"
  echo "VPN tunnel 'vpn-tunnel-apigee-if0' created."
fi

if resource_exists gcloud compute vpn-tunnels describe "vpn-tunnel-apigee-if1" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "VPN tunnel 'vpn-tunnel-apigee-if1' already exists, skipping."
else
  gcloud compute vpn-tunnels create "vpn-tunnel-apigee-if1" \
    --region="${REGION}" \
    --vpn-gateway=vpn-gw-apigee \
    --peer-gcp-gateway=vpn-gw-workloads \
    --shared-secret="${SHARED_SECRET}" \
    --router=router-apigee \
    --ike-version=2 \
    --interface=1 \
    --project="${PROJECT_ID}"
  echo "VPN tunnel 'vpn-tunnel-apigee-if1' created."
fi

# Workloads -> Apigee tunnels
if resource_exists gcloud compute vpn-tunnels describe "vpn-tunnel-workloads-if0" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "VPN tunnel 'vpn-tunnel-workloads-if0' already exists, skipping."
else
  gcloud compute vpn-tunnels create "vpn-tunnel-workloads-if0" \
    --region="${REGION}" \
    --vpn-gateway=vpn-gw-workloads \
    --peer-gcp-gateway=vpn-gw-apigee \
    --shared-secret="${SHARED_SECRET}" \
    --router=router-workloads \
    --ike-version=2 \
    --interface=0 \
    --project="${PROJECT_ID}"
  echo "VPN tunnel 'vpn-tunnel-workloads-if0' created."
fi

if resource_exists gcloud compute vpn-tunnels describe "vpn-tunnel-workloads-if1" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "VPN tunnel 'vpn-tunnel-workloads-if1' already exists, skipping."
else
  gcloud compute vpn-tunnels create "vpn-tunnel-workloads-if1" \
    --region="${REGION}" \
    --vpn-gateway=vpn-gw-workloads \
    --peer-gcp-gateway=vpn-gw-apigee \
    --shared-secret="${SHARED_SECRET}" \
    --router=router-workloads \
    --ike-version=2 \
    --interface=1 \
    --project="${PROJECT_ID}"
  echo "VPN tunnel 'vpn-tunnel-workloads-if1' created."
fi

# ============================================================
# Step 6: Configure BGP peers on router-apigee
# ============================================================
echo ""
echo "--- Step 6: Configure BGP peers on router-apigee ---"

# Interface 0
if gcloud compute routers describe "router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(interfaces[].name)" 2>/dev/null | grep -q "bgp-if0"; then
  echo "Interface 'bgp-if0' already exists on router-apigee, skipping."
else
  gcloud compute routers add-interface "router-apigee" \
    --region="${REGION}" \
    --interface-name=bgp-if0 \
    --vpn-tunnel=vpn-tunnel-apigee-if0 \
    --ip-address=169.254.0.1 \
    --mask-length=30 \
    --project="${PROJECT_ID}"
  echo "Interface 'bgp-if0' added to router-apigee."
fi

if gcloud compute routers describe "router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(bgpPeers[].name)" 2>/dev/null | grep -q "bgp-peer-workloads-0"; then
  echo "BGP peer 'bgp-peer-workloads-0' already exists on router-apigee, skipping."
else
  gcloud compute routers add-bgp-peer "router-apigee" \
    --region="${REGION}" \
    --peer-name=bgp-peer-workloads-0 \
    --interface=bgp-if0 \
    --peer-ip-address=169.254.0.2 \
    --peer-asn=64513 \
    --project="${PROJECT_ID}"
  echo "BGP peer 'bgp-peer-workloads-0' added to router-apigee."
fi

# Interface 1
if gcloud compute routers describe "router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(interfaces[].name)" 2>/dev/null | grep -q "bgp-if1"; then
  echo "Interface 'bgp-if1' already exists on router-apigee, skipping."
else
  gcloud compute routers add-interface "router-apigee" \
    --region="${REGION}" \
    --interface-name=bgp-if1 \
    --vpn-tunnel=vpn-tunnel-apigee-if1 \
    --ip-address=169.254.1.1 \
    --mask-length=30 \
    --project="${PROJECT_ID}"
  echo "Interface 'bgp-if1' added to router-apigee."
fi

if gcloud compute routers describe "router-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(bgpPeers[].name)" 2>/dev/null | grep -q "bgp-peer-workloads-1"; then
  echo "BGP peer 'bgp-peer-workloads-1' already exists on router-apigee, skipping."
else
  gcloud compute routers add-bgp-peer "router-apigee" \
    --region="${REGION}" \
    --peer-name=bgp-peer-workloads-1 \
    --interface=bgp-if1 \
    --peer-ip-address=169.254.1.2 \
    --peer-asn=64513 \
    --project="${PROJECT_ID}"
  echo "BGP peer 'bgp-peer-workloads-1' added to router-apigee."
fi

# ============================================================
# Step 7: Configure BGP peers on router-workloads
# ============================================================
echo ""
echo "--- Step 7: Configure BGP peers on router-workloads ---"

# Interface 0
if gcloud compute routers describe "router-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(interfaces[].name)" 2>/dev/null | grep -q "bgp-if0"; then
  echo "Interface 'bgp-if0' already exists on router-workloads, skipping."
else
  gcloud compute routers add-interface "router-workloads" \
    --region="${REGION}" \
    --interface-name=bgp-if0 \
    --vpn-tunnel=vpn-tunnel-workloads-if0 \
    --ip-address=169.254.0.2 \
    --mask-length=30 \
    --project="${PROJECT_ID}"
  echo "Interface 'bgp-if0' added to router-workloads."
fi

if gcloud compute routers describe "router-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(bgpPeers[].name)" 2>/dev/null | grep -q "bgp-peer-apigee-0"; then
  echo "BGP peer 'bgp-peer-apigee-0' already exists on router-workloads, skipping."
else
  gcloud compute routers add-bgp-peer "router-workloads" \
    --region="${REGION}" \
    --peer-name=bgp-peer-apigee-0 \
    --interface=bgp-if0 \
    --peer-ip-address=169.254.0.1 \
    --peer-asn=64512 \
    --project="${PROJECT_ID}"
  echo "BGP peer 'bgp-peer-apigee-0' added to router-workloads."
fi

# Interface 1
if gcloud compute routers describe "router-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(interfaces[].name)" 2>/dev/null | grep -q "bgp-if1"; then
  echo "Interface 'bgp-if1' already exists on router-workloads, skipping."
else
  gcloud compute routers add-interface "router-workloads" \
    --region="${REGION}" \
    --interface-name=bgp-if1 \
    --vpn-tunnel=vpn-tunnel-workloads-if1 \
    --ip-address=169.254.1.2 \
    --mask-length=30 \
    --project="${PROJECT_ID}"
  echo "Interface 'bgp-if1' added to router-workloads."
fi

if gcloud compute routers describe "router-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}" \
    --format="value(bgpPeers[].name)" 2>/dev/null | grep -q "bgp-peer-apigee-1"; then
  echo "BGP peer 'bgp-peer-apigee-1' already exists on router-workloads, skipping."
else
  gcloud compute routers add-bgp-peer "router-workloads" \
    --region="${REGION}" \
    --peer-name=bgp-peer-apigee-1 \
    --interface=bgp-if1 \
    --peer-ip-address=169.254.1.1 \
    --peer-asn=64512 \
    --project="${PROJECT_ID}"
  echo "BGP peer 'bgp-peer-apigee-1' added to router-workloads."
fi

# ============================================================
# Step 8: Wait for tunnels to be ESTABLISHED
# ============================================================
echo ""
echo "--- Step 8: Wait for VPN tunnels ---"
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
# Summary
# ============================================================
echo ""
echo "=== VPN setup complete ==="
echo ""
echo "Cloud Routers:"
echo "  router-apigee (ASN 64512, apigee-vpc)"
echo "  router-workloads (ASN 64513, workloads-vpc)"
echo ""
echo "VPN Gateways:"
echo "  vpn-gw-apigee (apigee-vpc)"
echo "  vpn-gw-workloads (workloads-vpc)"
echo ""
echo "VPN Tunnels (4 total, IKEv2):"
echo "  vpn-tunnel-apigee-if0, vpn-tunnel-apigee-if1"
echo "  vpn-tunnel-workloads-if0, vpn-tunnel-workloads-if1"
echo ""
echo "BGP Peering:"
echo "  169.254.0.1/30 <-> 169.254.0.2/30 (interface 0)"
echo "  169.254.1.1/30 <-> 169.254.1.2/30 (interface 1)"
echo ""
echo "Next: run ./setup-ilb.sh to create the internal HTTPS load balancer."
