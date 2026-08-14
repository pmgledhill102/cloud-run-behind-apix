#!/usr/bin/env bash
#
# option2b/setup-early.sh — VPC-SC perimeter, pre-Apigee phase (~1-2 min)
#
# Everything option2b needs that does NOT depend on Apigee being provisioned:
# nothing here touches the servicenetworking peering, the Apigee service
# agent, or peered DNS domains — so it can run right after shared/setup-base.sh,
# IN PARALLEL with shared/setup-slow.sh. The point: perimeter enforcement takes
# a highly variable ~1-35 min to propagate (measured ~35 min on the 2026-08-03
# run — see docs/option-b-vpcsc-field-notes.md §5), and creating the perimeter
# here starts that clock inside the ~60-90 min Apigee provisioning window
# instead of after it.
#
# Parallel workflow:
#   setup-base → (setup-slow ∥ option2b/setup-early) → option2/setup
#              → option2b/setup-finish → option2b/test
#
# Creates:
#   1. Access Context Manager API enablement
#   2. Scoped access policy (org-level resource, scoped to this project)
#   3. Restricted-VIP static route in apigee-vpc (199.36.153.4/30 →
#      default-internet-gateway; the custom-route EXPORT of it to the Apigee
#      tenant lives on the servicenetworking peering, so it happens in
#      setup-finish.sh)
#   4. Enforced service perimeter around the project:
#        - restricted services: run.googleapis.com, storage.googleapis.com
#          (run = the service under test; storage = used by test.sh negative test)
#        - ingress rule allowing the caller's identity from any source, so
#          gcloud/laptop admin access and the other PoC scripts keep working
#        - egress allow-list admitting Cloud Run in ONE named external project
#          (ALLOWED_EGRESS_PROJECT_NUMBER) — proven by test-external.sh
#
# Early enforcement is safe for the parallel setup-slow run: only run and
# storage are restricted — the Apigee provisioning APIs (apigee,
# servicenetworking, KMS) are unaffected, and Cloud Build image builds succeed
# under the enforced perimeter (ingress rule admits the caller + build SA).
#
# Prerequisites:
#   - shared/setup-base.sh completed (apigee-vpc must exist for the route).
#     Apigee/option2 NOT required.
#   - Caller needs org-level roles/accesscontextmanager.policyAdmin to create
#     the access policy. If you already have a policy, skip creation with:
#       PROJECT_ID=<your-project> ACCESS_POLICY_ID=1234567890 ./scripts/option2b/setup-early.sh
#
# Usage:
#   PROJECT_ID=<your-project> ./scripts/option2b/setup-early.sh
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
# ALLOWED_EGRESS_PROJECT_NUMBER (the ONE external Cloud Run project admitted
# by the egress allow-list) comes from shared/env.sh, alongside the
# BLOCKED/ALLOWED_RUN_URL pair used by setup-external.sh + test-external.sh.

echo "=== Option 2b (early phase): VPC-SC perimeter — project: ${PROJECT_ID} ==="
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

  # A policy found by title may be stale: scoped access policies survive
  # deletion of the sandbox project they were scoped to (org-level resource).
  # Observed live: setup "succeeded" against a stale policy whose perimeter
  # enclosed the old project number — nothing was enforced on this project.
  if [[ -n "${POLICY_ID}" ]]; then
    POLICY_SCOPES="$(gcloud access-context-manager policies describe "${POLICY_ID}" \
      --billing-project="${PROJECT_ID}" --format='value(scopes)' 2>/dev/null || true)"
    if echo "${POLICY_SCOPES}" | grep -q "projects/${PROJECT_NUMBER}"; then
      echo "Access policy '${POLICY_TITLE}' already exists (${POLICY_ID}), scope OK."
    else
      echo "Access policy '${POLICY_TITLE}' (${POLICY_ID}) is scoped to"
      echo "'${POLICY_SCOPES:-<none>}', not projects/${PROJECT_NUMBER} — stale from an"
      echo "earlier sandbox. Deleting stale perimeter + policy and recreating..."
      if resource_exists gcloud access-context-manager perimeters describe \
          "${PERIMETER_NAME}" --policy="${POLICY_ID}" --billing-project="${PROJECT_ID}"; then
        gcloud access-context-manager perimeters delete "${PERIMETER_NAME}" \
          --policy="${POLICY_ID}" \
          --billing-project="${PROJECT_ID}" \
          --quiet
        echo "Stale perimeter deleted."
      fi
      gcloud access-context-manager policies delete "${POLICY_ID}" \
        --billing-project="${PROJECT_ID}" \
        --quiet
      echo "Stale policy deleted."
      POLICY_ID=""
    fi
  fi

  if [[ -n "${POLICY_ID}" ]]; then
    : # policy exists and is correctly scoped
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
      echo "  PROJECT_ID=${PROJECT_ID} ACCESS_POLICY_ID=<id> ./scripts/option2b/setup-early.sh"
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
# Step 4: Restricted-VIP static route
# ============================================================
echo ""
echo "--- Step 4: Restricted-VIP static route ---"
# Per the Apigee VPC-SC docs: a static route for the restricted VIP with
# next-hop default-internet-gateway (traffic stays on Google's backbone).
# Needs only apigee-vpc (setup-base). Exporting it to the Apigee tenant is a
# custom-route export on the servicenetworking peering, which doesn't exist
# until Apigee provisioning creates it — setup-finish.sh does the export.
if resource_exists gcloud compute routes describe "restricted-vip" --project="${PROJECT_ID}"; then
  echo "Route 'restricted-vip' already exists, skipping."
else
  gcloud compute routes create "restricted-vip" \
    --network="${APIGEE_NETWORK}" \
    --destination-range="199.36.153.4/30" \
    --next-hop-gateway="default-internet-gateway" \
    --project="${PROJECT_ID}"
  echo "Route 'restricted-vip' (199.36.153.4/30 → default-internet-gateway) created."
fi

# ============================================================
# Step 5: Create enforced service perimeter (+ egress allow-list)
# ============================================================
echo ""
echo "--- Step 5: Create service perimeter ---"

# Egress allow-list: the perimeter denies out-of-perimeter Cloud Run by
# default; this admits ONE named external project — proving the perimeter is
# governable (deny by default, admit by explicit policy). test-external.sh
# asserts both: the allow-listed service succeeds, everything else stays
# blocked.
#
# NOTE: method: '*' — although VPC-SC denials log run.routes.invoke in
# targetResourcePermissions, that permission name is NOT accepted as an
# egress methodSelector for run.googleapis.com (INVALID_ARGUMENT, found
# live). Scoping is by target project instead.
EGRESS_FILE="$(mktemp)"
cat > "${EGRESS_FILE}" << YAMLEOF
- egressFrom:
    identityType: ANY_IDENTITY
  egressTo:
    operations:
    - serviceName: run.googleapis.com
      methodSelectors:
      - method: '*'
    resources:
    - projects/${ALLOWED_EGRESS_PROJECT_NUMBER}
YAMLEOF

# Ingress: the caller (laptop gcloud, admin continuity) plus the project's
# build SA — Cloud Build's shared workers run OUTSIDE the perimeter, so with
# storage restricted the worker's access to the in-project regional logs
# bucket needs an explicit ingress allowance (found live: build FAILURE,
# "Failure setting up GCS logging ... prohibited by organization's policy").
# The production-grade alternative is a private worker pool inside the
# perimeter.
CALLER_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
INGRESS_FILE="$(mktemp)"
cat > "${INGRESS_FILE}" << YAMLEOF
- ingressFrom:
    identities:
    - user:${CALLER_ACCOUNT}
    - serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: '*'
    resources:
    - '*'
YAMLEOF

if resource_exists gcloud access-context-manager perimeters describe \
    "${PERIMETER_NAME}" --policy="${POLICY_ID}" --billing-project="${PROJECT_ID}"; then
  echo "Perimeter '${PERIMETER_NAME}' already exists — ensuring project + egress allow-list..."
  # Belt and braces: an existing perimeter may predate this project (stale
  # reuse) — make sure this project is actually inside it.
  PERIM_RESOURCES="$(gcloud access-context-manager perimeters describe \
    "${PERIMETER_NAME}" --policy="${POLICY_ID}" --billing-project="${PROJECT_ID}" \
    --format='value(status.resources)' 2>/dev/null || true)"
  if ! echo "${PERIM_RESOURCES}" | grep -q "projects/${PROJECT_NUMBER}"; then
    gcloud access-context-manager perimeters update "${PERIMETER_NAME}" \
      --policy="${POLICY_ID}" \
      --add-resources="projects/${PROJECT_NUMBER}" \
      --billing-project="${PROJECT_ID}"
    echo "Added projects/${PROJECT_NUMBER} to perimeter resources."
  fi
  gcloud access-context-manager perimeters update "${PERIMETER_NAME}" \
    --policy="${POLICY_ID}" \
    --set-ingress-policies="${INGRESS_FILE}" \
    --set-egress-policies="${EGRESS_FILE}" \
    --billing-project="${PROJECT_ID}"
  echo "Ingress (caller + build SA) and egress allow-list applied."
else
  echo "Creating perimeter '${PERIMETER_NAME}'..."
  echo "  Resources:  projects/${PROJECT_NUMBER}"
  echo "  Restricted: ${RESTRICTED_SERVICES}"
  echo "  Ingress:    ${CALLER_ACCOUNT} + build SA allowed from any source"
  echo "  Egress:     projects/${ALLOWED_EGRESS_PROJECT_NUMBER} allowed (run.routes.invoke)"

  gcloud access-context-manager perimeters create "${PERIMETER_NAME}" \
    --policy="${POLICY_ID}" \
    --title="${PERIMETER_NAME}" \
    --resources="projects/${PROJECT_NUMBER}" \
    --restricted-services="${RESTRICTED_SERVICES}" \
    --ingress-policies="${INGRESS_FILE}" \
    --egress-policies="${EGRESS_FILE}" \
    --billing-project="${PROJECT_ID}"

  echo "Perimeter '${PERIMETER_NAME}' created (ENFORCED, with ingress + egress allow-lists)."
fi
rm -f "${EGRESS_FILE}" "${INGRESS_FILE}"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Option 2b early phase complete ==="
echo ""
echo "Perimeter '${PERIMETER_NAME}' now encloses project ${PROJECT_ID}:"
echo "  - run.googleapis.com and storage.googleapis.com are restricted"
echo "  - egress allow-list admits Cloud Run in projects/${ALLOWED_EGRESS_PROJECT_NUMBER} ONLY"
echo "  - only ${PROJECT_ID}'s own network (and the caller identity) may"
echo "    access them; cross-perimeter access is denied"
echo ""
echo "NOTE: enforcement can take a few minutes (up to ~30) to propagate —"
echo "the clock is now running; it overlaps setup-slow.sh if that's in flight."
echo ""
echo "Next: once shared/setup-slow.sh has finished, run option2/setup.sh"
echo "(if not already done) then ./scripts/option2b/setup-finish.sh."
