#!/usr/bin/env bash
#
# env-mock.sh — Mock-Apigee quick stack configuration (issue #51)
#
# Source AFTER shared/env.sh + helpers.sh + auth/env-auth.sh:
#   source "${SCRIPT_DIR}/env-mock.sh"
#

# --- Mock tenant network (stands in for the Apigee tenant project's VPC) ---
MOCK_VPC="apigee-tenant-mock"
MOCK_SUBNET="mock-runtime"
# Clear of compute-apigee (10.0.0.0/24), Apigee peering (10.1.0.0/20) and
# instance (10.2.0.0/22) ranges, so the mock can coexist with the real thing.
MOCK_SUBNET_CIDR="10.3.0.0/24"

# --- Gateway VM (stands in for the Apigee runtime instance at 10.2.0.2) ---
MOCK_GW_VM="mock-apigee-gw"
MOCK_GW_IP="10.3.0.10"
MOCK_GW_PORT="443"
GW_IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/mock-apigee-gw:latest"

# --- Peering (standard VPC peering stands in for servicenetworking) ---
PEERING_APIGEE_TO_MOCK="apigee-to-mock"
PEERING_MOCK_TO_APIGEE="mock-to-apigee"

# --- Southbound plumbing (hand-replicates peered-DNS-domain + route export) ---
MOCK_DNS_ZONE="run-app-mock"       # private run.app. zone bound to MOCK_VPC only
MOCK_ROUTE="restricted-vip-mock"   # 199.36.153.4/30 → default-internet-gateway
MOCK_ROUTER="nat-router-mock"      # NAT so the COS VM can pull the image
MOCK_NAT="public-nat-mock"
RESTRICTED_VIP_CIDR="199.36.153.4/30"
RESTRICTED_VIP_IPS="199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7"

# --- Firewalls in MOCK_VPC ---
FW_MOCK_IAP_SSH="allow-iap-ssh-mock"
FW_MOCK_INGRESS="allow-gateway-ingress-mock"
