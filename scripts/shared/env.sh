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
ZONE="${REGION}-a"

# --- Service account ---
SA_NAME="apigee-poc"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# --- Artifact Registry + container image ---
REPO_NAME="apigee-poc"
IMAGE_NAME="http-server"
IMAGE_TAG="latest"
IMAGE_URL="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${IMAGE_NAME}:${IMAGE_TAG}"

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

# --- Paths ---
SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
