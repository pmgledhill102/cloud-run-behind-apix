#!/usr/bin/env bash
#
# setup-dns.sh — Create private DNS zone for PGA restricted VIP (idempotent)
#
# Routes *.run.app to Google's restricted VIP range (199.36.153.4/30)
# instead of public IPs. Combined with Private Google Access on the subnet,
# this enables Cloud Run access without PSC or VPN.
#
# Run this AFTER setup-infra.sh has completed.
#
set -euo pipefail

# --- Configuration ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-workshop}"

REGION="europe-north2"

echo "=== Setup DNS for PGA — project: ${PROJECT_ID} ==="
echo "Region: ${REGION}"
echo "Restricted VIP: 199.36.153.4, 199.36.153.5, 199.36.153.6, 199.36.153.7"
echo ""

# --- Helper ---
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# ============================================================
# Step 1: Create private DNS zone for run.app
# ============================================================
echo "--- Step 1: Create private DNS zone for run.app ---"
if resource_exists gcloud dns managed-zones describe "run-app-pga" --project="${PROJECT_ID}"; then
  echo "DNS zone 'run-app-pga' already exists, skipping."
else
  gcloud dns managed-zones create "run-app-pga" \
    --dns-name="run.app." \
    --visibility=private \
    --networks=apigee-vpc \
    --description="Route run.app to restricted VIP for Private Google Access" \
    --project="${PROJECT_ID}"
  echo "DNS zone 'run-app-pga' created."
fi

# ============================================================
# Step 2: Create wildcard A record *.run.app → restricted VIP
# ============================================================
echo ""
echo "--- Step 2: Create DNS record *.run.app → restricted VIP ---"
if gcloud dns record-sets describe "*.run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  echo "DNS record '*.run.app' already exists, skipping."
else
  gcloud dns record-sets create "*.run.app." \
    --zone="run-app-pga" \
    --type=A \
    --ttl=300 \
    --rrdatas="199.36.153.4 199.36.153.5 199.36.153.6 199.36.153.7" \
    --project="${PROJECT_ID}"
  echo "DNS record '*.run.app → 199.36.153.4-7' created."
fi

# ============================================================
# Step 3: Create apex A record run.app → restricted VIP
# ============================================================
echo ""
echo "--- Step 3: Create DNS record run.app → restricted VIP ---"
if gcloud dns record-sets describe "run.app." \
    --zone="run-app-pga" --type=A --project="${PROJECT_ID}" &>/dev/null; then
  echo "DNS record 'run.app' already exists, skipping."
else
  gcloud dns record-sets create "run.app." \
    --zone="run-app-pga" \
    --type=A \
    --ttl=300 \
    --rrdatas="199.36.153.4 199.36.153.5 199.36.153.6 199.36.153.7" \
    --project="${PROJECT_ID}"
  echo "DNS record 'run.app → 199.36.153.4-7' created."
fi

# ============================================================
# Verification
# ============================================================
echo ""
echo "=== DNS setup complete ==="

echo ""
echo "--- DNS zone ---"
gcloud dns managed-zones describe "run-app-pga" \
  --project="${PROJECT_ID}" \
  --format="table(name,dnsName,visibility)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "--- DNS records ---"
gcloud dns record-sets list \
  --zone="run-app-pga" \
  --project="${PROJECT_ID}" \
  --format="table(name,type,ttl,rrdatas)" 2>/dev/null || echo "(not ready yet)"

echo ""
echo "=== Next steps ==="
echo ""
echo "Run ./test.sh to verify DNS resolution and connectivity through PGA."
