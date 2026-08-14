#!/usr/bin/env bash
#
# mock-apigee/setup.sh — Mock-Apigee quick stack (~2-3 min, issue #51)
#
# A "fake Apigee tenant": a second VPC peered to apigee-vpc with an Envoy
# gateway VM standing in for the Apigee runtime instance. Replicates the
# request path hop-for-hop (internal-IP TLS northbound, peering hop, JWT at
# the edge, combined-header target auth, PGA/restricted-VIP southbound) so
# header/grant/routing experiments iterate in minutes at ~£6/month instead of
# ~75-90 min and ~£0.50/hr for the real thing.
#
# Deliberately dropped for speed: VPC-SC perimeter (option2b covers that),
# Apigee org/servicenetworking mechanics. NO step here waits on >5 min
# propagation. Mock = inner loop; real Apigee = confirmation gate.
#
# Creates:
#   1. Mock tenant VPC + subnet (10.3.0.0/24) + firewalls (IAP SSH, :443)
#   2. Bidirectional VPC peering with apigee-vpc (stands in for
#      servicenetworking; free, instant)
#   3. Private run.app zone bound to the mock VPC + restricted-VIP route
#      (hand-replicates peered-DNS-domain + custom route export)
#   4. Cloud NAT for the mock VPC (COS image pull)
#   5. Gateway image (Cloud Build) + COS VM at 10.3.0.10 running it
#
# Prerequisites:
#   - shared/setup-base.sh (apigee-vpc, vm-test, cr-hello, AR repo)
#   - auth/setup.sh at least through its keypair + cr-auth-echo steps
#     (the gateway validates the same client JWTs and targets cr-auth-echo)
#   - setup-slow.sh / option2b NOT required — that's the point
#
# Usage:
#   PROJECT_ID=<your-project> ./scripts/mock-apigee/setup.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/../auth/env-auth.sh"
source "${SCRIPT_DIR}/env-mock.sh"

echo "=== Mock-Apigee quick stack setup — project: ${PROJECT_ID} ==="
echo "Gateway: ${MOCK_GW_VM} at ${MOCK_GW_IP}:${MOCK_GW_PORT} in ${MOCK_VPC}"
echo ""

# ============================================================
# Step 0: Prerequisite checks (fail fast, no cloud mutations yet)
# ============================================================
echo "--- Step 0: Prerequisite checks ---"
if ! resource_exists gcloud compute networks describe "${APIGEE_NETWORK}" --project="${PROJECT_ID}"; then
  echo "ERROR: VPC '${APIGEE_NETWORK}' not found — run ./scripts/shared/setup-base.sh first."
  exit 1
fi
if [[ ! -f "${AUTH_PRIVATE_KEY}" ]]; then
  echo "ERROR: no mock-issuer keypair at ${AUTH_PRIVATE_KEY} — run ./scripts/auth/setup.sh first."
  exit 1
fi
HELLO_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
AUTH_ECHO_URL="$(gcloud run services describe "${AUTH_ECHO_SERVICE}" \
  --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)' 2>/dev/null || true)"
if [[ -z "${HELLO_URL}" || -z "${AUTH_ECHO_URL}" ]]; then
  echo "ERROR: cr-hello and/or ${AUTH_ECHO_SERVICE} not deployed."
  echo "       Run ./scripts/shared/setup-base.sh and ./scripts/auth/setup.sh first."
  exit 1
fi
HELLO_HOST="${HELLO_URL#https://}"
AUTH_ECHO_HOST="${AUTH_ECHO_URL#https://}"
echo "Targets: /hello → ${HELLO_HOST}"
echo "         /auth-echo → ${AUTH_ECHO_HOST}"

# ============================================================
# Step 1: Mock tenant VPC + subnet + firewalls
# ============================================================
echo ""
echo "--- Step 1: Mock tenant VPC ---"
if resource_exists gcloud compute networks describe "${MOCK_VPC}" --project="${PROJECT_ID}"; then
  echo "VPC '${MOCK_VPC}' already exists, skipping."
else
  gcloud compute networks create "${MOCK_VPC}" \
    --subnet-mode=custom \
    --project="${PROJECT_ID}"
  echo "VPC '${MOCK_VPC}' created."
fi

if resource_exists gcloud compute networks subnets describe "${MOCK_SUBNET}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Subnet '${MOCK_SUBNET}' already exists, skipping."
else
  gcloud compute networks subnets create "${MOCK_SUBNET}" \
    --network="${MOCK_VPC}" \
    --range="${MOCK_SUBNET_CIDR}" \
    --region="${REGION}" \
    --enable-private-ip-google-access \
    --project="${PROJECT_ID}"
  echo "Subnet '${MOCK_SUBNET}' (${MOCK_SUBNET_CIDR}) created."
fi

if resource_exists gcloud compute firewall-rules describe "${FW_MOCK_IAP_SSH}" --project="${PROJECT_ID}"; then
  echo "Firewall rule '${FW_MOCK_IAP_SSH}' already exists, skipping."
else
  gcloud compute firewall-rules create "${FW_MOCK_IAP_SSH}" \
    --network="${MOCK_VPC}" \
    --allow=tcp:22 \
    --source-ranges="35.235.240.0/20" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule '${FW_MOCK_IAP_SSH}' created."
fi

if resource_exists gcloud compute firewall-rules describe "${FW_MOCK_INGRESS}" --project="${PROJECT_ID}"; then
  echo "Firewall rule '${FW_MOCK_INGRESS}' already exists, skipping."
else
  gcloud compute firewall-rules create "${FW_MOCK_INGRESS}" \
    --network="${MOCK_VPC}" \
    --allow="tcp:${MOCK_GW_PORT}" \
    --source-ranges="10.0.0.0/8" \
    --direction=INGRESS \
    --project="${PROJECT_ID}"
  echo "Firewall rule '${FW_MOCK_INGRESS}' created."
fi

# ============================================================
# Step 2: VPC peering both ways (the "servicenetworking" hop)
# ============================================================
echo ""
echo "--- Step 2: VPC peering apigee-vpc ↔ ${MOCK_VPC} ---"
# peering_exists <network> <peering-name>
# (peerings list --format='value(name)' prints the NETWORK name — describe
#  the network and read peerings[].name instead)
peering_exists() {
  gcloud compute networks describe "$1" --project="${PROJECT_ID}" \
    --format='value(peerings[].name)' 2>/dev/null | tr ';' '\n' | grep -qx "$2"
}
if peering_exists "${APIGEE_NETWORK}" "${PEERING_APIGEE_TO_MOCK}"; then
  echo "Peering '${PEERING_APIGEE_TO_MOCK}' already exists, skipping."
else
  gcloud compute networks peerings create "${PEERING_APIGEE_TO_MOCK}" \
    --network="${APIGEE_NETWORK}" \
    --peer-network="${MOCK_VPC}" \
    --project="${PROJECT_ID}"
  echo "Peering '${PEERING_APIGEE_TO_MOCK}' created."
fi
if peering_exists "${MOCK_VPC}" "${PEERING_MOCK_TO_APIGEE}"; then
  echo "Peering '${PEERING_MOCK_TO_APIGEE}' already exists, skipping."
else
  gcloud compute networks peerings create "${PEERING_MOCK_TO_APIGEE}" \
    --network="${MOCK_VPC}" \
    --peer-network="${APIGEE_NETWORK}" \
    --project="${PROJECT_ID}"
  echo "Peering '${PEERING_MOCK_TO_APIGEE}' created."
fi

# ============================================================
# Step 3: Southbound DNS + route (peered-DNS-domain stand-in)
# ============================================================
echo ""
echo "--- Step 3: run.app zone + restricted-VIP route in ${MOCK_VPC} ---"
# Own zone on the mock VPC only — deliberately NOT touching option2's
# run-app-pga zone, so this stack never mutates shared state.
if resource_exists gcloud dns managed-zones describe "${MOCK_DNS_ZONE}" --project="${PROJECT_ID}"; then
  echo "DNS zone '${MOCK_DNS_ZONE}' already exists, skipping."
else
  gcloud dns managed-zones create "${MOCK_DNS_ZONE}" \
    --dns-name="run.app." \
    --description="Mock-Apigee: run.app → restricted VIP for ${MOCK_VPC}" \
    --visibility=private \
    --networks="${MOCK_VPC}" \
    --project="${PROJECT_ID}"
  echo "DNS zone '${MOCK_DNS_ZONE}' created."
fi
for record in "*.run.app." "run.app."; do
  if gcloud dns record-sets describe "${record}" --type=A \
      --zone="${MOCK_DNS_ZONE}" --project="${PROJECT_ID}" &>/dev/null; then
    echo "DNS record '${record}' already exists, skipping."
  else
    gcloud dns record-sets create "${record}" \
      --type=A --ttl=300 \
      --rrdatas="${RESTRICTED_VIP_IPS}" \
      --zone="${MOCK_DNS_ZONE}" \
      --project="${PROJECT_ID}"
    echo "DNS record '${record} → restricted VIP' created."
  fi
done

if resource_exists gcloud compute routes describe "${MOCK_ROUTE}" --project="${PROJECT_ID}"; then
  echo "Route '${MOCK_ROUTE}' already exists, skipping."
else
  gcloud compute routes create "${MOCK_ROUTE}" \
    --network="${MOCK_VPC}" \
    --destination-range="${RESTRICTED_VIP_CIDR}" \
    --next-hop-gateway=default-internet-gateway \
    --project="${PROJECT_ID}"
  echo "Route '${MOCK_ROUTE}' created."
fi

# ============================================================
# Step 4: Cloud NAT (COS pulls the gateway image from AR)
# ============================================================
echo ""
echo "--- Step 4: Cloud NAT for ${MOCK_VPC} ---"
if resource_exists gcloud compute routers describe "${MOCK_ROUTER}" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Cloud Router '${MOCK_ROUTER}' already exists, skipping."
else
  gcloud compute routers create "${MOCK_ROUTER}" \
    --network="${MOCK_VPC}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Cloud Router '${MOCK_ROUTER}' created."
fi
if gcloud compute routers nats describe "${MOCK_NAT}" \
    --router="${MOCK_ROUTER}" --region="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "NAT gateway '${MOCK_NAT}' already exists, skipping."
else
  gcloud compute routers nats create "${MOCK_NAT}" \
    --router="${MOCK_ROUTER}" \
    --region="${REGION}" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges \
    --project="${PROJECT_ID}"
  echo "NAT gateway '${MOCK_NAT}' created."
fi

# ============================================================
# Step 5: Build gateway image + create the gateway VM
# ============================================================
echo ""
echo "--- Step 5: Gateway image + VM ---"
if gcloud artifacts docker images describe "${GW_IMAGE_URL}" --project="${PROJECT_ID}" &>/dev/null; then
  echo "Image '${GW_IMAGE_URL}' already exists, skipping build."
else
  echo "Building mock-apigee-gw via Cloud Build (region: ${BUILD_REGION})..."
  # regional-user-owned-bucket: keep build staging/logs in-project (safe under
  # a VPC-SC perimeter if option2b happens to be up — see setup-base.sh)
  gcloud builds submit \
    --region="${BUILD_REGION}" \
    --gcs-source-staging-dir="gs://${CLOUDBUILD_BUCKET}/source" \
    --default-buckets-behavior=regional-user-owned-bucket \
    --tag "${GW_IMAGE_URL}" \
    "${SCRIPT_DIR}/gateway" \
    --project="${PROJECT_ID}"
  echo "Image pushed to ${GW_IMAGE_URL}"
fi

if resource_exists gcloud compute instances describe "${MOCK_GW_VM}" \
    --zone="${ZONE}" --project="${PROJECT_ID}"; then
  echo "Instance '${MOCK_GW_VM}' already exists, skipping."
else
  # Container env via file: JWKS_JSON contains commas/quotes that the
  # comma-separated --container-env flag would mangle.
  JWKS_JSON="$(build_jwks_json)"
  ENV_FILE="$(mktemp)"
  {
    echo "GW_PORT=${MOCK_GW_PORT}"
    echo "JWT_ISSUER=${JWT_ISSUER}"
    echo "JWT_AUDIENCE=${JWT_AUDIENCE}"
    echo "JWKS_JSON=${JWKS_JSON}"
    echo "HELLO_HOST=${HELLO_HOST}"
    echo "AUTH_ECHO_HOST=${AUTH_ECHO_HOST}"
    echo "HELLO_AUDIENCE=${HELLO_URL}"
    echo "AUTH_ECHO_AUDIENCE=${GOOGLE_CUSTOM_AUDIENCE}"
  } > "${ENV_FILE}"
  # COS + konlet runs the container on the host network, so Envoy's :443
  # binds the VM's ${MOCK_GW_IP} directly (image sets USER root for <1024).
  # No external IP: image pull goes via the mock VPC's NAT. The default
  # compute SA mints the southbound ID tokens (it already holds run.invoker
  # from setup-iam.sh).
  gcloud compute instances create-with-container "${MOCK_GW_VM}" \
    --zone="${ZONE}" \
    --machine-type="${VM_MACHINE_TYPE}" \
    --network="${MOCK_VPC}" \
    --subnet="${MOCK_SUBNET}" \
    --private-network-ip="${MOCK_GW_IP}" \
    --no-address \
    --scopes=cloud-platform \
    --container-image="${GW_IMAGE_URL}" \
    --container-env-file="${ENV_FILE}" \
    --project="${PROJECT_ID}"
  rm -f "${ENV_FILE}"
  echo "Instance '${MOCK_GW_VM}' created at ${MOCK_GW_IP}."
fi

echo ""
echo "=== Mock-Apigee setup complete ==="
echo ""
echo "Gateway (stands in for the Apigee runtime at 10.2.0.2):"
echo "  https://${MOCK_GW_IP}/hello      → ${HELLO_HOST}"
echo "  https://${MOCK_GW_IP}/auth-echo  → ${AUTH_ECHO_HOST}"
echo ""
echo "Every route needs a valid client JWT (jwt_authn = the flow hook);"
echo "southbound adds a Google ID token in X-Serverless-Authorization"
echo "(gcp_authn = GoogleIDToken target auth) via the restricted VIP."
echo ""
echo "First boot pulls the image — allow ~1-2 min before testing."
echo "Run ./scripts/mock-apigee/test.sh to verify."
