#!/usr/bin/env bash
#
# path-routing/setup.sh — §9 items 1–3 PoC start state (~2-3 min, issue #62)
#
# Builds the docs/path-routing-at-scale.md worked example on the live org:
#   - 3 Cloud Run clones of the cr-hello image (payments / cards / issuing)
#   - proxy pr-payments        BasePath /payments        → cr-route-payments
#   - proxy pr-payments-cards  BasePath /payments/cards  → cr-route-cards,
#     with /issuing/** served via a conditional route INSIDE this proxy
#     (the §3 pre-carve-out state)
#
# Every proxy answers with X-Served-By: <proxy-name> so test.sh can prove
# WHICH proxy handled a request, not just which service.
#
# Prerequisites: shared/setup-base.sh + shared/setup-slow.sh (live Apigee).
# NOTE: if the auth PoC flow hook is attached (auth/setup.sh), every request
# through these proxies needs a valid client JWT — test.sh mints them.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-routing.sh"
source "${SCRIPT_DIR}/lib-proxy.sh"

echo "=== Path-routing PoC setup — project: ${PROJECT_ID} ==="
echo ""

APIGEE_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $(apigee_token)" \
  "${APIGEE_API}/organizations/${PROJECT_ID}")"
if [[ "${APIGEE_HTTP}" != "200" ]]; then
  echo "ERROR: Apigee not provisioned (HTTP ${APIGEE_HTTP}) — this PoC needs the live org."
  exit 1
fi

# ============================================================
# Step 1: Cloud Run clones (no builds — reuse the cr-hello image)
# ============================================================
echo "--- Step 1: Cloud Run clones ---"
for svc in "${SVC_PAYMENTS}" "${SVC_CARDS}" "${SVC_ISSUING}"; do
  if resource_exists gcloud run services describe "${svc}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    echo "Service '${svc}' already exists, skipping."
  else
    gcloud run deploy "${svc}" \
      --image="${IMAGE_URL}" \
      --region="${REGION}" \
      --ingress=internal \
      --max-instances=3 \
      --min-instances=0 \
      --cpu-throttling \
      --no-allow-unauthenticated \
      --project="${PROJECT_ID}" \
      --quiet
    echo "Service '${svc}' deployed."
  fi
done
PAYMENTS_URL="$(gcloud run services describe "${SVC_PAYMENTS}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
CARDS_URL="$(gcloud run services describe "${SVC_CARDS}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"
ISSUING_URL="$(gcloud run services describe "${SVC_ISSUING}" --region="${REGION}" --project="${PROJECT_ID}" --format='value(status.url)')"

# ============================================================
# Step 2: Proxies — /payments and /payments/cards (pre-carve-out)
# ============================================================
echo ""
echo "--- Step 2: Proxies ---"

BUNDLE_DIR="$(mktemp -d)"
build_single_bundle "${BUNDLE_DIR}" "${PROXY_PAYMENTS}" "/payments" "${PAYMENTS_URL}"
echo "Importing '${PROXY_PAYMENTS}' (/payments)..."
REV="$(import_proxy "${PROXY_PAYMENTS}" "${BUNDLE_DIR}")"
deploy_proxy "${PROXY_PAYMENTS}" "${REV}" > /dev/null
wait_deployment_ready "${PROXY_PAYMENTS}" "${REV}"
rm -rf "${BUNDLE_DIR}"

BUNDLE_DIR="$(mktemp -d)"
build_cards_bundle "${BUNDLE_DIR}" "true" "${CARDS_URL}" "${ISSUING_URL}"
echo "Importing '${PROXY_CARDS}' (/payments/cards, issuing via conditional route)..."
REV="$(import_proxy "${PROXY_CARDS}" "${BUNDLE_DIR}")"
deploy_proxy "${PROXY_CARDS}" "${REV}" > /dev/null
wait_deployment_ready "${PROXY_CARDS}" "${REV}"
rm -rf "${BUNDLE_DIR}"

echo ""
echo "=== Path-routing PoC setup complete ==="
echo ""
echo "  /payments/**               → pr-payments        → ${SVC_PAYMENTS}"
echo "  /payments/cards/**         → pr-payments-cards  → ${SVC_CARDS}"
echo "  /payments/cards/issuing/** → pr-payments-cards  → ${SVC_ISSUING} (conditional route)"
echo ""
echo "Run ./scripts/path-routing/test.sh — NOTE: it mutates proxy state as it"
echo "goes (conflict probe, live carve-out, fallback delete); run teardown.sh"
echo "then setup.sh to restore the start state."
