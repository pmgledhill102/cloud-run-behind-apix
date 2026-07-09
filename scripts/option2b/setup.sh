#!/usr/bin/env bash
#
# option2b/setup.sh — Option B + VPC Service Controls perimeter (~2-5 min)
#
# Builds on option2 (PGA via restricted VIP) by enforcing a REAL VPC-SC service
# perimeter around the project. Option2 routes traffic through the restricted
# VIP (199.36.153.4/30) — the VPC-SC-enforcing endpoint — but creates no
# perimeter, so nothing is actually enforced. This option adds the perimeter
# and proves enforcement both ways (see test.sh).
#
# Creates:
#   1. Access Context Manager API enablement
#   2. Scoped access policy (org-level resource, scoped to this project)
#   3. VPC-SC enforcement on the Apigee servicenetworking peering
#      (required so Apigee tenant-project southbound traffic is treated as
#      inside the perimeter — see Apigee VPC-SC docs)
#   4. Enforced service perimeter around the project:
#        - restricted services: run.googleapis.com, storage.googleapis.com
#          (run = the service under test; storage = used by test.sh negative test)
#        - ingress rule allowing the caller's identity from any source, so
#          gcloud/laptop admin access and the other PoC scripts keep working
#
# Prerequisites:
#   - shared/setup-base.sh and option2/setup.sh completed
#   - Caller needs org-level roles/accesscontextmanager.policyAdmin to create
#     the access policy. If you already have a policy, skip creation with:
#       ACCESS_POLICY_ID=1234567890 ./scripts/option2b/setup.sh
#
# NOTE: perimeter changes can take a few minutes (up to ~30) to propagate.
# All ACM commands pass --billing-project explicitly because ACM is an
# org-level API and gcloud otherwise uses the configured quota project, which
# may be stale or unrelated.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

# Perimeter short names allow only [A-Za-z0-9_] — no hyphens
PERIMETER_NAME="apigee_poc_perimeter"
POLICY_TITLE="apigee-poc-policy"
RESTRICTED_SERVICES="run.googleapis.com,storage.googleapis.com"

echo "=== Option 2b: PGA + VPC-SC perimeter — project: ${PROJECT_ID} ==="
echo "Perimeter:           ${PERIMETER_NAME}"
echo "Restricted services: ${RESTRICTED_SERVICES}"
echo ""

# ============================================================
# Step 1: Enable Access Context Manager API
# ============================================================
echo "--- Step 1: Enable Access Context Manager API ---"
gcloud services enable accesscontextmanager.googleapis.com \
  --project="${PROJECT_ID}"
echo "API enabled."

# ============================================================
# Step 2: Discover organisation and project number
# ============================================================
echo ""
echo "--- Step 2: Discover organisation ---"
PROJECT_NUMBER="$(gcloud projects describe "${PROJECT_ID}" \
  --format='value(projectNumber)')"
ORG_ID="$(gcloud projects get-ancestors "${PROJECT_ID}" \
  --format='csv[no-heading](id,type)' | awk -F, '$2=="organization"{print $1}')"

if [[ -z "${ORG_ID}" ]]; then
  echo "ERROR: could not determine organization ID for ${PROJECT_ID}."
  echo "VPC-SC requires the project to belong to an organization."
  exit 1
fi
echo "Organization: ${ORG_ID}"
echo "Project number: ${PROJECT_NUMBER}"

# ============================================================
# Step 3: Find or create access policy (scoped to this project)
# ============================================================
echo ""
echo "--- Step 3: Access policy ---"

if [[ -n "${ACCESS_POLICY_ID:-}" ]]; then
  POLICY_ID="${ACCESS_POLICY_ID}"
  echo "Using ACCESS_POLICY_ID from environment: ${POLICY_ID}"
else
  POLICY_ID="$(gcloud access-context-manager policies list \
    --organization="${ORG_ID}" \
    --billing-project="${PROJECT_ID}" \
    --format='value(name)' \
    --filter="title=${POLICY_TITLE}" 2>/dev/null | head -1 || true)"
  POLICY_ID="${POLICY_ID##*/}"

  if [[ -n "${POLICY_ID}" ]]; then
    echo "Access policy '${POLICY_TITLE}' already exists (${POLICY_ID}), skipping."
  else
    echo "Creating scoped access policy '${POLICY_TITLE}'..."
    # Scoped (not org-default) so it cannot collide with, or affect, any
    # org-wide policy that may exist. Requires org-level
    # roles/accesscontextmanager.policyAdmin.
    if ! gcloud access-context-manager policies create \
        --organization="${ORG_ID}" \
        --scopes="projects/${PROJECT_NUMBER}" \
        --title="${POLICY_TITLE}" \
        --billing-project="${PROJECT_ID}"; then
      echo ""
      echo "ERROR: could not create access policy."
      echo "You need org-level roles/accesscontextmanager.policyAdmin, or"
      echo "reuse an existing policy:"
      echo "  gcloud access-context-manager policies list --organization=${ORG_ID} --billing-project=${PROJECT_ID}"
      echo "  ACCESS_POLICY_ID=<id> ./scripts/option2b/setup.sh"
      exit 1
    fi

    # Creation is async — poll until it appears
    for _ in 1 2 3 4 5 6; do
      POLICY_ID="$(gcloud access-context-manager policies list \
        --organization="${ORG_ID}" \
        --billing-project="${PROJECT_ID}" \
        --format='value(name)' \
        --filter="title=${POLICY_TITLE}" 2>/dev/null | head -1 || true)"
      POLICY_ID="${POLICY_ID##*/}"
      [[ -n "${POLICY_ID}" ]] && break
      echo "  Waiting for policy to appear..."
      sleep 10
    done
    if [[ -z "${POLICY_ID}" ]]; then
      echo "ERROR: policy '${POLICY_TITLE}' did not appear after creation."
      exit 1
    fi
    echo "Access policy created: ${POLICY_ID}"
  fi
fi

# ============================================================
# Step 4: Enable VPC-SC on the Apigee servicenetworking peering
# ============================================================
echo ""
echo "--- Step 4: Enable VPC-SC on servicenetworking peering ---"
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
# Step 5: Create enforced service perimeter
# ============================================================
echo ""
echo "--- Step 5: Create service perimeter ---"

if resource_exists gcloud access-context-manager perimeters describe \
    "${PERIMETER_NAME}" --policy="${POLICY_ID}" --billing-project="${PROJECT_ID}"; then
  echo "Perimeter '${PERIMETER_NAME}' already exists, skipping."
else
  CALLER_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
  echo "Creating perimeter '${PERIMETER_NAME}'..."
  echo "  Resources:  projects/${PROJECT_NUMBER}"
  echo "  Restricted: ${RESTRICTED_SERVICES}"
  echo "  Ingress:    ${CALLER_ACCOUNT} allowed from any source (admin continuity)"

  INGRESS_FILE="$(mktemp)"
  cat > "${INGRESS_FILE}" << YAMLEOF
- ingressFrom:
    identities:
    - user:${CALLER_ACCOUNT}
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: '*'
    resources:
    - '*'
YAMLEOF

  gcloud access-context-manager perimeters create "${PERIMETER_NAME}" \
    --policy="${POLICY_ID}" \
    --title="${PERIMETER_NAME}" \
    --resources="projects/${PROJECT_NUMBER}" \
    --restricted-services="${RESTRICTED_SERVICES}" \
    --ingress-policies="${INGRESS_FILE}" \
    --billing-project="${PROJECT_ID}"

  rm -f "${INGRESS_FILE}"
  echo "Perimeter '${PERIMETER_NAME}' created (ENFORCED)."
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Option 2b setup complete ==="
echo ""
echo "Perimeter '${PERIMETER_NAME}' now encloses project ${PROJECT_ID}:"
echo "  - run.googleapis.com and storage.googleapis.com are restricted"
echo "  - only ${PROJECT_ID}'s own network (and the caller identity) may"
echo "    access them; cross-perimeter access is denied"
echo ""
echo "NOTE: enforcement can take a few minutes (up to ~30) to propagate."
echo ""
echo "Run ./scripts/option2b/test.sh to verify (positive + negative tests)."
