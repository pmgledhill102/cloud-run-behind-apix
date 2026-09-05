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

# Transport to vm-test. The default is IAP SSH; VM_CHANNEL=metadata swaps in
# the metadata/guest-attributes channel from lib/vm-exec.sh, for sandboxes
# whose egress policy denies tunnel.cloudproxy.app (IAP's WebSocket relay).
# Sourced at the END of this file so its ssh_cmd/ssh_curl_auth overrides win.

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

# Parse an RFC3339 timestamp to epoch seconds, GNU first and BSD second.
# gcloud emits fractional seconds and a Z ("2026-09-04T18:36:55.635518678Z");
# BSD date parses neither, so they are stripped for the fallback.
rfc3339_to_epoch() {
  local ts="$1"
  date -d "${ts}" +%s 2>/dev/null && return 0
  local trimmed="${ts%%.*}"
  trimmed="${trimmed%Z}"
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "${trimmed}" +%s 2>/dev/null && return 0
  return 1
}

# Format epoch seconds as UTC RFC3339, GNU first and BSD second.
epoch_to_utc() {
  local epoch="$1"
  date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && return 0
  date -u -r "${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null && return 0
  return 1
}

# Refuse to start if the Apigee org name is still inside its post-deletion
# reservation window.
#
# An Apigee X org name is global and must equal the project id, so it cannot be
# varied to work around a clash. Deleting an org (teardown-slow.sh uses
# retention=MINIMUM) soft-deletes it and holds the name for ~24h. Until that
# passes, CreateOrganization fails with:
#
#   ALREADY_EXISTS: already exists: org <id> already associated with another project
#
# which reads like a wrong-project misconfiguration rather than "you deleted
# this yesterday", on a project that visibly contains no Apigee org.
#
# No marker file is written at teardown: a sandbox is reclaimed between
# sessions, so anything on local disk is gone, and a marker only helps if every
# teardown path remembers to write it — a console deletion or an interrupted
# script leaves it absent or stale. The audit log already records the deletion,
# cannot be disabled for Admin Activity, and is retained far longer than the
# 24h window, so it is read instead of maintained.
#
# Returns 0 when provisioning may proceed. Prints the release time and returns
# 1 when it may not. A project whose logs are gone (recreated with the same id)
# has no signal either way — that falls through to the API error, which #89's
# read-back guard is the answer to.
apigee_org_lock_check() {
  local deleted_at deleted_epoch release_epoch now remaining

  deleted_at="$(gcloud logging read \
    'protoPayload.methodName="google.cloud.apigee.v1.OrganizationService.DeleteOrganization"' \
    --project="${PROJECT_ID}" --freshness=2d --limit=1 \
    --format='value(timestamp)' 2>/dev/null | head -1)"

  # No deletion on record (or no log access) — nothing to say.
  [[ -n "${deleted_at}" ]] || return 0

  deleted_epoch="$(rfc3339_to_epoch "${deleted_at}")" || {
    echo "  NOTE: could not parse deletion timestamp '${deleted_at}'; skipping lock check."
    return 0
  }

  release_epoch=$((deleted_epoch + 86400))
  now="$(date -u +%s)"

  if (( now >= release_epoch )); then
    return 0
  fi

  remaining=$(( (release_epoch - now + 59) / 60 ))
  local remaining_fmt
  if (( remaining >= 60 )); then
    remaining_fmt="$((remaining / 60))h $((remaining % 60))m"
  else
    remaining_fmt="${remaining}m"
  fi
  echo ""
  echo "=========================================================="
  echo "  REFUSING TO START — Apigee org name is locked"
  echo "=========================================================="
  echo "The Apigee org '${PROJECT_ID}' was deleted at ${deleted_at}."
  echo ""
  echo "An org name is global and must equal the project id, so it cannot be"
  echo "changed to work around this. The name stays reserved for ~24h after"
  echo "deletion; creating one now fails with ALREADY_EXISTS partway through"
  echo "provisioning, after APIs, VPC, ranges and peering have been set up."
  echo ""
  echo "  Name released at: $(epoch_to_utc "${release_epoch}") (~${remaining_fmt} away)"
  echo ""
  echo "Nothing shortens the wait. See issue #87."
  echo "=========================================================="
  return 1
}

# --- Alternative transport (must come last: it overrides the two above) ---
if [[ "${VM_CHANNEL:-}" == "metadata" ]]; then
  # shellcheck source=/dev/null
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/vm-exec.sh"
fi
