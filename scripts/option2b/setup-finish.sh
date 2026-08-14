#!/usr/bin/env bash
#
# option2b/setup-finish.sh — VPC-SC perimeter, post-Apigee phase (~1-2 min)
#
# The Apigee-dependent half of option2b: everything here touches the
# servicenetworking peering, the Apigee service agent, or peered DNS domains,
# none of which exist until Apigee provisioning (shared/setup-slow.sh) has
# created them. Run this after setup-slow completes; the perimeter itself was
# already created by setup-early.sh and has been propagating in the meantime.
# Idempotent — safe to re-run.
#
# Parallel workflow:
#   setup-base → (setup-slow ∥ option2b/setup-early) → option2/setup
#              → option2b/setup-finish → option2b/test
#
# Creates/configures:
#   1. VPC-SC enforcement on the Apigee servicenetworking peering
#      (required so Apigee tenant-project southbound traffic is treated as
#      inside the perimeter — see Apigee VPC-SC docs)
#   2. dns.peer grant to the Apigee service agent (tenant DNS-peers into this
#      VPC to resolve the private run.app zone)
#   3. Custom route export on the servicenetworking peering (tenant uses the
#      restricted-VIP route created by setup-early.sh)
#   4. Peered DNS domain 'run-app' (tenant resolves run.app via this VPC)
#   5. Apigee proxy target refresh (same update option2/setup.sh performs) —
#      covers the flow where option2 ran before Apigee existed and its proxy
#      update was skipped
#
# Prerequisites:
#   - option2b/setup-early.sh completed (perimeter + restricted-VIP route)
#   - shared/setup-slow.sh completed (Apigee org/instance — creates the
#     servicenetworking peering and the Apigee service agent)
#   - option2/setup.sh completed (run-app-pga DNS zone the tenant resolves via)
#
# Usage:
#   PROJECT_ID=<your-project> ./scripts/option2b/setup-finish.sh
#   PROJECT_ID=my-project ./scripts/option2b/setup-finish.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SHARED_DIR}/lib/apigee-proxy.sh"

echo "=== Option 2b (finish phase): Apigee tenant plumbing — project: ${PROJECT_ID} ==="
echo ""

PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" \
  --format='value(projectNumber)')"

# ============================================================
# Step 1: Enable VPC-SC on the Apigee servicenetworking peering
# ============================================================
echo "--- Step 1: Enable VPC-SC on servicenetworking peering ---"
# Makes Apigee tenant-project southbound traffic subject to (and admitted by)
# the perimeter. Idempotent; non-fatal so a transient failure doesn't block
# the perimeter demo — but Apigee E2E (test 4) may fail until this succeeds.
if gcloud services vpc-peerings enable-vpc-service-controls \
    --network="${APIGEE_NETWORK}" \
    --project="${PROJECT_ID}"; then
  echo "VPC-SC enabled on peering for '${APIGEE_NETWORK}'."
else
  echo "WARNING: could not enable VPC-SC on the servicenetworking peering."
  echo "         Apigee southbound traffic may be blocked by the perimeter."
  echo "         Retry manually:"
  echo "         gcloud services vpc-peerings enable-vpc-service-controls --network=${APIGEE_NETWORK} --project=${PROJECT_ID}"
fi

# ============================================================
# Step 2: Grant Apigee service agent dns.peer
# ============================================================
echo ""
echo "--- Step 2: Grant Apigee service agent roles/dns.peer ---"
# enable-vpc-service-controls removes the tenant project's default internet
# route and adds DNS zones + a restricted-VIP route for googleapis.com names —
# but NOT for run.app. Without visibility of this VPC's run-app-pga zone the
# tenant resolves run.app to public IPs it can no longer route to, and
# southbound calls fail with TARGET_CONNECT_TIMEOUT. dns.peer lets the Apigee
# tenant DNS-peer into this VPC and resolve the private run.app zone
# (per the Apigee VPC-SC docs).
APIGEE_AGENT_SA="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"
if gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${APIGEE_AGENT_SA}" \
    --role="roles/dns.peer" \
    --condition=None \
    --quiet >/dev/null 2>&1; then
  echo "Apigee service agent granted dns.peer."
else
  echo "WARNING: could not grant dns.peer to '${APIGEE_AGENT_SA}'."
fi

# ============================================================
# Step 3: Custom route export on the servicenetworking peering
# ============================================================
echo ""
echo "--- Step 3: Custom route export on servicenetworking peering ---"
# Per the Apigee VPC-SC docs: export custom routes on the peering so the
# tenant project can use the restricted-VIP static route that setup-early.sh
# created in this VPC.
#
# `peerings list` returns network rows with a nested peerings[] list —
# value(name) yields the VPC's own name and a network~ filter never matches
# (observed live: export-custom-routes silently skipped). Flatten to address
# the peering itself.
PEERING_NAME="$(gcloud compute networks peerings list \
  --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
  --flatten="peerings[]" --format='value(peerings.name)' \
  --filter='peerings.network~servicenetworking' 2>/dev/null || true)"
if [[ -n "${PEERING_NAME}" ]]; then
  gcloud compute networks peerings update "${PEERING_NAME}" \
    --network="${APIGEE_NETWORK}" \
    --export-custom-routes \
    --project="${PROJECT_ID}"
  echo "Custom route export enabled on peering '${PEERING_NAME}'."
else
  echo "WARNING: servicenetworking peering not found — is Apigee provisioned?"
fi

# ============================================================
# Step 4: Peered DNS domain — run.app resolves via this VPC
# ============================================================
echo ""
echo "--- Step 4: Peered DNS domain (run.app) ---"
# The organizations.dnsZones API is only supported for PSC (non-peering) orgs
# — a VPC-peered org returns FAILED_PRECONDITION. For peered orgs the
# equivalent is a servicenetworking peered DNS domain: tenant-project queries
# for the suffix are forwarded to this VPC's resolution order, which includes
# the private run-app-pga zone (restricted VIP). Without this, the tenant
# resolves run.app to public IPs it can no longer route to (VPC-SC enablement
# removed its default internet route) → TARGET_CONNECT_TIMEOUT.
if gcloud services peered-dns-domains list \
    --network="${APIGEE_NETWORK}" --project="${PROJECT_ID}" \
    --format='value(name)' 2>/dev/null | grep -qx "run-app"; then
  echo "Peered DNS domain 'run-app' already exists, skipping."
else
  gcloud services peered-dns-domains create "run-app" \
    --network="${APIGEE_NETWORK}" \
    --dns-suffix="run.app." \
    --project="${PROJECT_ID}"
  echo "Peered DNS domain 'run-app' (run.app.) created."
fi

# ============================================================
# Step 5: Refresh Apigee proxy target (optional)
# ============================================================
echo ""
echo "--- Step 5: Refresh Apigee proxy target ---"
# Same update option2/setup.sh performs. In the parallel workflow option2 may
# have run before setup-slow finished — update_apigee_proxy_target skips
# gracefully when Apigee is absent, leaving the passthrough proxy on its
# placeholder target. Re-running it here (it skips if already correct) makes
# the end state independent of that ordering.
SERVICE_URL="$(gcloud run services describe "cr-hello" \
  --region="${REGION}" --project="${PROJECT_ID}" \
  --format='value(status.url)' 2>/dev/null || true)"
if [[ -n "${SERVICE_URL}" ]]; then
  update_apigee_proxy_target "${SERVICE_URL}/" --audience="${SERVICE_URL}"
else
  echo "Cloud Run service 'cr-hello' not found, skipping proxy update."
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Option 2b finish phase complete ==="
echo ""
echo "Apigee tenant plumbing in place: peering VPC-SC, dns.peer, custom route"
echo "export, peered DNS domain, proxy target."
echo ""
echo "NOTE: perimeter enforcement (created by setup-early.sh) can take a few"
echo "minutes (up to ~30) from ITS creation to propagate — if setup-early ran"
echo "in parallel with setup-slow, it has likely already landed."
echo ""
echo "Run ./scripts/option2b/test.sh to verify (positive + negative tests)."
