#!/usr/bin/env bash
#
# path-routing/teardown.sh — Full reverse of the §9 PoC (issue #62)
#
# Removes all four possible proxies (whatever state test.sh left) and the
# three Cloud Run clones. Idempotent.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"
source "${SCRIPT_DIR}/env-routing.sh"
source "${SCRIPT_DIR}/lib-proxy.sh"

echo "=== Path-routing PoC teardown — project: ${PROJECT_ID} ==="
echo ""

echo "--- Step 1: Proxies ---"
for proxy in "${PROXY_ISSUING}" "${PROXY_DUP}" "${PROXY_CARDS}" "${PROXY_PAYMENTS}"; do
  undeploy_and_delete_proxy "${proxy}"
done

echo ""
echo "--- Step 2: Cloud Run clones ---"
for svc in "${SVC_PAYMENTS}" "${SVC_CARDS}" "${SVC_ISSUING}"; do
  if resource_exists gcloud run services describe "${svc}" \
      --region="${REGION}" --project="${PROJECT_ID}"; then
    gcloud run services delete "${svc}" \
      --region="${REGION}" --project="${PROJECT_ID}" --quiet
    echo "Service '${svc}' deleted."
  else
    echo "Service '${svc}' not found, skipping."
  fi
done

echo ""
echo "=== Path-routing PoC teardown complete ==="
