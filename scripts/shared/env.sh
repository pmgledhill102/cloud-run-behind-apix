#!/usr/bin/env bash
#
# env.sh — Shared configuration for all PoC scripts
#
# Source this file at the top of every script:
#   source "$(dirname "${BASH_SOURCE[0]}")/../shared/env.sh"   (from option scripts)
#   source "$(dirname "${BASH_SOURCE[0]}")/env.sh"             (from shared scripts)
#

# --- Project ---
PROJECT_ID="${PROJECT_ID:-sb-paul-g-apigee}"
REGION="europe-north2"
# Overridable: small VM types can stock out in a single zone (e.g. e2-micro in
# europe-north2-a) — switch zone or size without editing this file:
#   ZONE=europe-north2-b ./scripts/shared/setup-base.sh
ZONE="${ZONE:-${REGION}-a}"
VM_MACHINE_TYPE="${VM_MACHINE_TYPE:-e2-micro}"

# --- Service account ---
SA_NAME="apigee-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# --- Artifact Registry + container image ---
REPO_NAME="apigee-poc"
IMAGE_NAME="http-server"
IMAGE_TAG="latest"
IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"

# --- Cloud Build ---
# The image is built remotely with `gcloud builds submit` (no local Docker
# required). BUILD_REGION must be an allowed location if the project enforces
# constraints/gcp.resourceLocations — the default US Cloud Build pool/bucket is
# rejected in EU-only orgs. CLOUDBUILD_BUCKET is a regional staging bucket in
# BUILD_REGION (the default US multi-region bucket is likewise disallowed).
BUILD_REGION="${BUILD_REGION:-europe-west1}"
CLOUDBUILD_BUCKET="${CLOUDBUILD_BUCKET:-${PROJECT_ID}-cloudbuild}"

# --- Networking ---
APIGEE_NETWORK="apigee-vpc"

# --- Apigee ---
APIGEE_API="${APIGEE_API:-https://eu-apigee.googleapis.com/v1}"
APIGEE_ENV="${APIGEE_ENV:-test}"
APIGEE_ENV_GROUP="test-group"
APIGEE_ENV_GROUP_HOSTNAME="api.internal.example.com"
ANALYTICS_REGION="europe-west1"
CONSUMER_DATA_REGION="europe-west1"
APIGEE_PEERING_RANGE_NAME="apigee-peering-range"
APIGEE_PEERING_CIDR="10.1.0.0/20"
APIGEE_INSTANCE_RANGE_NAME="apigee-instance-range"
APIGEE_INSTANCE_CIDR="10.2.0.0/22"
INSTANCE_NAME="instance-${REGION}"
PROXY_NAME="cr-hello-passthrough"

# --- Option 2b: VPC-SC perimeter governance test ---
# External Cloud Run services used by option2b's governance test:
#   BLOCKED_RUN_URL — public service in a project with NO egress rule; the
#                     perimeter must deny it (EXTERNAL_RUN_URL honoured as a
#                     legacy alias).
#   ALLOWED_RUN_URL — public service in the project admitted by the perimeter
#                     egress allow-list (option2b/setup.sh Step 5).
#                     /health.json keeps probe payloads small in test logs.
# ALLOWED_EGRESS_PROJECT_NUMBER must match ALLOWED_RUN_URL's project.
BLOCKED_RUN_URL="${BLOCKED_RUN_URL:-${EXTERNAL_RUN_URL:-https://sandbox-manager-255182376214.europe-west2.run.app/health}}"
ALLOWED_RUN_URL="${ALLOWED_RUN_URL:-https://neukin-barn-433004719812.europe-west1.run.app/health.json}"
ALLOWED_EGRESS_PROJECT_NUMBER="${ALLOWED_EGRESS_PROJECT_NUMBER:-433004719812}"

# --- Paths ---
SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
