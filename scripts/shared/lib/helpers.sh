#!/usr/bin/env bash
#
# helpers.sh — Shared helper functions
#
# Source this after env.sh:
#   source "${SHARED_DIR}/lib/helpers.sh"
#

# Check if a GCP resource exists (runs the command, suppresses output)
resource_exists() {
  "$@" &>/dev/null
  return $?
}

# Run a command on vm-test via IAP SSH (filters NumPy warning)
ssh_cmd() {
  gcloud compute ssh "vm-test" \
    --zone="${ZONE}" \
    --tunnel-through-iap \
    --project="${PROJECT_ID}" \
    --command="$1" 2> >(grep -v 'NumPy' >&2)
}

# Run an authenticated curl from vm-test (ID token via metadata server)
# Usage: ssh_curl_auth <audience> <curl-args...>
ssh_curl_auth() {
  local audience="$1"
  shift
  local curl_args="$*"
  ssh_cmd "ID_TOKEN=\$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${audience}') && curl -H \"Authorization: Bearer \$ID_TOKEN\" ${curl_args}"
}

# Delete a subnet with exponential backoff retry
# Cloud Run may hold VPC address reservations for a few minutes after deletion.
delete_subnet_with_retry() {
  local subnet="$1"
  local max_attempts=6
  local wait_secs=10

  for attempt in $(seq 1 "${max_attempts}"); do
    if gcloud compute networks subnets delete "${subnet}" \
        --region="${REGION}" --project="${PROJECT_ID}" --quiet 2>/dev/null; then
      echo "Subnet '${subnet}' deleted."
      return 0
    fi

    if [[ ${attempt} -lt ${max_attempts} ]]; then
      echo "  Subnet '${subnet}' still in use, retrying in ${wait_secs}s... (attempt ${attempt}/${max_attempts})"
      sleep "${wait_secs}"
      wait_secs=$((wait_secs * 2))
    else
      echo "  WARNING: Could not delete subnet '${subnet}' — still in use (Cloud Run may need more time to release)."
      FAILED_RESOURCES+=("subnet/${subnet}")
      return 0  # continue teardown
    fi
  done
}

# Call the Apigee REST API. Ignores 404s silently.
apigee_api() {
  local method="$1"
  local path="$2"
  local token
  token="$(gcloud auth print-access-token)"
  local response
  response="$(curl -s -w "\n%{http_code}" -X "${method}" \
    -H "Authorization: Bearer ${token}" \
    "${APIGEE_API}/${path}")"
  local http_code
  http_code="$(echo "${response}" | tail -1)"
  local body
  body="$(echo "${response}" | sed '$d')"

  if [[ "${http_code}" == "404" ]]; then
    echo "  (not found, skipping)"
    return 0
  elif [[ "${http_code}" =~ ^2 ]]; then
    echo "${body}"
    return 0
  else
    echo "  WARNING: HTTP ${http_code}"
    echo "${body}" | python3 -m json.tool 2>/dev/null || echo "${body}"
    return 0  # Don't fail teardown on errors
  fi
}
