#!/usr/bin/env bash
#
# setup-psc.sh — Create ILB, Service Attachment, and PSC endpoint (idempotent)
#
# Producer side: Regional internal HTTPS load balancer in workloads-vpc
# with Service Attachment.
# Consumer side: PSC endpoint in apigee-vpc pointing to the Service Attachment.
#
# Run this AFTER setup-infra.sh has completed.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"

echo "=== Setup PSC Service Attachment — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Producer (workloads-vpc)
# ============================================================

# ============================================================
# Step 1: Reserve ILB IP
# ============================================================
echo "--- Step 1: Reserve ILB IP ---"
if resource_exists gcloud compute addresses describe "ilb-ip-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Address 'ilb-ip-workloads' already exists, skipping."
else
  gcloud compute addresses create "ilb-ip-workloads" \
    --region="${REGION}" \
    --subnet=compute-workloads \
    --addresses=10.100.0.10 \
    --project="${PROJECT_ID}"
  echo "Address 'ilb-ip-workloads' (10.100.0.10) reserved."
fi

# ============================================================
# Step 2: Create Serverless NEG
# ============================================================
echo ""
echo "--- Step 2: Create Serverless NEG ---"
if resource_exists gcloud compute network-endpoint-groups describe "neg-cr-hello" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "NEG 'neg-cr-hello' already exists, skipping."
else
  gcloud compute network-endpoint-groups create "neg-cr-hello" \
    --region="${REGION}" \
    --network-endpoint-type=serverless \
    --cloud-run-service=cr-hello \
    --project="${PROJECT_ID}"
  echo "NEG 'neg-cr-hello' created."
fi

# ============================================================
# Step 3: Create backend service
# ============================================================
echo ""
echo "--- Step 3: Create backend service ---"
if resource_exists gcloud compute backend-services describe "backend-cr-hello" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Backend service 'backend-cr-hello' already exists, skipping."
else
  gcloud compute backend-services create "backend-cr-hello" \
    --region="${REGION}" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --protocol=HTTPS \
    --project="${PROJECT_ID}"
  gcloud compute backend-services add-backend "backend-cr-hello" \
    --region="${REGION}" \
    --network-endpoint-group=neg-cr-hello \
    --network-endpoint-group-region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Backend service 'backend-cr-hello' created with NEG backend."
fi

# ============================================================
# Step 4: URL map
# ============================================================
echo ""
echo "--- Step 4: Create URL map ---"
if resource_exists gcloud compute url-maps describe "urlmap-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "URL map 'urlmap-workloads' already exists, skipping."
else
  gcloud compute url-maps create "urlmap-workloads" \
    --region="${REGION}" \
    --default-service=backend-cr-hello \
    --project="${PROJECT_ID}"
  echo "URL map 'urlmap-workloads' created."
fi

# ============================================================
# Step 5: Self-signed SSL certificate
# ============================================================
echo ""
echo "--- Step 5: Create self-signed SSL certificate ---"
if resource_exists gcloud compute ssl-certificates describe "cert-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "SSL certificate 'cert-workloads' already exists, skipping."
else
  CERT_DIR="$(mktemp -d)"
  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "${CERT_DIR}/key.pem" \
    -out "${CERT_DIR}/cert.pem" \
    -subj "/CN=api.internal.example.com" 2>/dev/null
  gcloud compute ssl-certificates create "cert-workloads" \
    --region="${REGION}" \
    --certificate="${CERT_DIR}/cert.pem" \
    --private-key="${CERT_DIR}/key.pem" \
    --project="${PROJECT_ID}"
  rm -rf "${CERT_DIR}"
  echo "SSL certificate 'cert-workloads' created."
fi

# ============================================================
# Step 6: Target HTTPS proxy
# ============================================================
echo ""
echo "--- Step 6: Create target HTTPS proxy ---"
if resource_exists gcloud compute target-https-proxies describe "proxy-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Target HTTPS proxy 'proxy-workloads' already exists, skipping."
else
  gcloud compute target-https-proxies create "proxy-workloads" \
    --region="${REGION}" \
    --url-map=urlmap-workloads \
    --ssl-certificates=cert-workloads \
    --project="${PROJECT_ID}"
  echo "Target HTTPS proxy 'proxy-workloads' created."
fi

# ============================================================
# Step 7: Forwarding rule (ILB)
# ============================================================
echo ""
echo "--- Step 7: Create forwarding rule (ILB) ---"
if resource_exists gcloud compute forwarding-rules describe "fwd-rule-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Forwarding rule 'fwd-rule-workloads' already exists, skipping."
else
  gcloud compute forwarding-rules create "fwd-rule-workloads" \
    --region="${REGION}" \
    --load-balancing-scheme=INTERNAL_MANAGED \
    --network=workloads-vpc \
    --subnet=compute-workloads \
    --address=ilb-ip-workloads \
    --ports=443 \
    --target-https-proxy=proxy-workloads \
    --target-https-proxy-region="${REGION}" \
    --project="${PROJECT_ID}"
  echo "Forwarding rule 'fwd-rule-workloads' created."
fi

# ============================================================
# Step 8: Service Attachment
# ============================================================
echo ""
echo "--- Step 8: Create Service Attachment ---"
if resource_exists gcloud compute service-attachments describe "sa-workloads" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Service Attachment 'sa-workloads' already exists, skipping."
else
  gcloud compute service-attachments create "sa-workloads" \
    --region="${REGION}" \
    --producer-forwarding-rule=fwd-rule-workloads \
    --connection-preference=ACCEPT_AUTOMATIC \
    --nat-subnets=psc-nat-workloads \
    --project="${PROJECT_ID}"
  echo "Service Attachment 'sa-workloads' created."
fi

# ============================================================
# Consumer (apigee-vpc)
# ============================================================

# ============================================================
# Step 9: Get Service Attachment URI
# ============================================================
echo ""
echo "--- Step 9: Get Service Attachment URI ---"
SA_URI="$(gcloud compute service-attachments describe "sa-workloads" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(selfLink)')"
echo "Service Attachment URI: ${SA_URI}"

# ============================================================
# Step 10: Reserve PSC consumer IP
# ============================================================
echo ""
echo "--- Step 10: Reserve PSC consumer IP ---"
if resource_exists gcloud compute addresses describe "psc-consumer-ip" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "Address 'psc-consumer-ip' already exists, skipping."
else
  gcloud compute addresses create "psc-consumer-ip" \
    --region="${REGION}" \
    --subnet=compute-apigee \
    --addresses=10.0.0.50 \
    --project="${PROJECT_ID}"
  echo "Address 'psc-consumer-ip' (10.0.0.50) reserved."
fi

# ============================================================
# Step 11: Create PSC endpoint
# ============================================================
echo ""
echo "--- Step 11: Create PSC endpoint ---"
if resource_exists gcloud compute forwarding-rules describe "psc-endpoint-apigee" \
    --region="${REGION}" --project="${PROJECT_ID}"; then
  echo "PSC endpoint 'psc-endpoint-apigee' already exists, skipping."
else
  gcloud compute forwarding-rules create "psc-endpoint-apigee" \
    --region="${REGION}" \
    --network=apigee-vpc \
    --subnet=compute-apigee \
    --address=psc-consumer-ip \
    --target-service-attachment="${SA_URI}" \
    --project="${PROJECT_ID}"
  echo "PSC endpoint 'psc-endpoint-apigee' created."
fi

# ============================================================
# Step 12: DNS zone + A record
# ============================================================
echo ""
echo "--- Step 12: Create DNS zone and A record ---"

if resource_exists gcloud dns managed-zones describe "api-internal-zone" --project="${PROJECT_ID}"; then
  echo "DNS zone 'api-internal-zone' already exists, skipping."
else
  gcloud dns managed-zones create "api-internal-zone" \
    --dns-name="api.internal.example.com." \
    --visibility=private \
    --networks=apigee-vpc \
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
    --rrdatas="10.0.0.50" \
    --project="${PROJECT_ID}"
  echo "DNS record 'api.internal.example.com -> 10.0.0.50' created."
fi

# ============================================================
# Verification
# ============================================================
echo ""
echo "=== PSC setup complete ==="

echo ""
echo "--- Service Attachment ---"
gcloud compute service-attachments describe "sa-workloads" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="table(name,connectionPreference,natSubnets)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- PSC endpoint ---"
gcloud compute forwarding-rules describe "psc-endpoint-apigee" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format="table(name,IPAddress,pscConnectionStatus)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- DNS zone ---"
gcloud dns managed-zones describe "api-internal-zone" \
  --project="${PROJECT_ID}" \
  --format="table(name,dnsName,visibility)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- DNS records ---"
gcloud dns record-sets list \
  --zone="api-internal-zone" \
  --project="${PROJECT_ID}" \
  --format="table(name,type,ttl,rrdatas)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "=== Next steps ==="
echo ""
echo "Run ./test.sh to verify PSC connectivity from the VM."
