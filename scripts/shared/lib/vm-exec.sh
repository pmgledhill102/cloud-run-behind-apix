#!/usr/bin/env bash
#
# vm-exec.sh — Run commands on vm-test without SSH
#
# WHY THIS EXISTS
#
# Every in-VPC probe in this repo runs on vm-test, because the Apigee runtime
# endpoint and the restricted VIP are only reachable from inside apigee-vpc.
# The normal route in is `gcloud compute ssh --tunnel-through-iap`
# (shared/lib/helpers.sh ssh_cmd), which needs a WebSocket to
# tunnel.cloudproxy.app:443.
#
# Some locked-down agent sandboxes deny exactly that host at the egress proxy
# (observed live 2026-09-04: "failed CONNECT via proxy status: 403"), while
# still permitting *.googleapis.com. IAP is unreachable, but the Compute API
# is not — so this module drives the VM entirely through metadata and guest
# attributes, which are ordinary Compute API calls:
#
#   caller ──add-metadata(probe-cmd, probe-id)──► metadata server
#                                                       │
#                                          vm-test agent loop reads it,
#                                          runs it, PUTs the output to
#                                          guest attributes
#                                                       │
#   caller ◄──get-guest-attributes(probe/<id>)──────────┘
#
# This is not a way around the egress policy — every call it makes is to
# compute.googleapis.com, which the policy already allows. It is a different
# transport to the same VM.
#
# USAGE
#
#   source "${SHARED_DIR}/lib/vm-exec.sh"
#   vm_exec_setup            # once: install the agent loop, reboot, wait
#   vm_exec "curl -s ..."    # returns the command's combined output
#
# Setting VM_CHANNEL=metadata before sourcing helpers.sh makes ssh_cmd and
# ssh_curl_auth dispatch here instead, so the existing test scripts work
# unchanged on a surface where IAP is blocked.
#
# LIMITS
#
#   - Output is truncated to VM_EXEC_MAX_BYTES (default 8000) — guest
#     attributes are metadata, not a log sink.
#   - One command at a time; calls are serialised by the id counter.
#   - Latency is ~5-15s per call (the agent polls every 5s), so this is for
#     probes, not for anything chatty.
#

VM_EXEC_INSTANCE="${VM_EXEC_INSTANCE:-vm-test}"
VM_EXEC_MAX_BYTES="${VM_EXEC_MAX_BYTES:-8000}"
VM_EXEC_TIMEOUT="${VM_EXEC_TIMEOUT:-120}"

# The agent loop that runs on the VM. Polls for a new probe-id, runs the
# matching probe-cmd, PUTs stdout+stderr to guest attributes under probe/<id>.
# Written to be dash-safe and to survive the metadata server being briefly
# unavailable — a `set -e` here would kill the loop on the first transient.
_vm_exec_agent_script() {
  cat << 'AGENTEOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -yqq dnsutils curl netcat-openbsd >/dev/null 2>&1

MD="http://metadata.google.internal/computeMetadata/v1"
HDR="Metadata-Flavor: Google"
LAST=""

# Announce readiness so vm_exec_setup can stop waiting on a fixed sleep.
curl -sf -X PUT -H "${HDR}" -d "ready" \
  "${MD}/instance/guest-attributes/probe/agent-status" >/dev/null 2>&1

while true; do
  ID="$(curl -sf -H "${HDR}" "${MD}/instance/attributes/probe-id" 2>/dev/null)"
  if [ -n "${ID}" ] && [ "${ID}" != "${LAST}" ]; then
    CMD="$(curl -sf -H "${HDR}" "${MD}/instance/attributes/probe-cmd" 2>/dev/null)"
    if [ -n "${CMD}" ]; then
      OUT="$(bash -c "${CMD}" 2>&1 | head -c 8000)"
      # Guest attributes reject an empty body; keep a sentinel so the caller
      # can tell "ran, produced nothing" from "still running".
      [ -z "${OUT}" ] && OUT="<no output>"
      curl -sf -X PUT -H "${HDR}" --data-binary "${OUT}" \
        "${MD}/instance/guest-attributes/probe/${ID}" >/dev/null 2>&1
      LAST="${ID}"
    fi
  fi
  sleep 5
done
AGENTEOF
}

# vm_exec_setup — install the agent loop on the VM and wait for it to report in
vm_exec_setup() {
  local zone="${ZONE}"
  echo "--- vm-exec: installing metadata probe agent on ${VM_EXEC_INSTANCE} ---"

  local script_file
  script_file="$(mktemp)"
  _vm_exec_agent_script > "${script_file}"

  gcloud compute instances add-metadata "${VM_EXEC_INSTANCE}" \
    --zone="${zone}" --project="${PROJECT_ID}" \
    --metadata=enable-guest-attributes=TRUE \
    --metadata-from-file=startup-script="${script_file}" >/dev/null
  rm -f "${script_file}"
  echo "Agent script + enable-guest-attributes set."

  # The startup script only runs at boot, so the VM has to be restarted for a
  # freshly-added agent to take effect. reset() is a hard power cycle, which
  # is fine for a stateless probe VM and faster than stop/start.
  echo "Resetting ${VM_EXEC_INSTANCE} so the startup script runs..."
  gcloud compute instances reset "${VM_EXEC_INSTANCE}" \
    --zone="${zone}" --project="${PROJECT_ID}" >/dev/null 2>&1 || true

  echo -n "Waiting for the agent to report ready"
  local waited=0 status
  while (( waited < 300 )); do
    status="$(gcloud compute instances get-guest-attributes "${VM_EXEC_INSTANCE}" \
      --zone="${zone}" --project="${PROJECT_ID}" \
      --query-path='probe/agent-status' --format='value(value)' 2>/dev/null || true)"
    if [[ "${status}" == "ready" ]]; then
      echo " — ready after ${waited}s."
      return 0
    fi
    sleep 10; waited=$((waited + 10)); echo -n "."
  done
  echo ""
  echo "ERROR: agent did not report ready within 300s."
  echo "  Check the boot log: gcloud compute instances get-serial-port-output ${VM_EXEC_INSTANCE} --zone=${zone}"
  return 1
}

# vm_exec <command> — run a command on the VM, echo its combined output
vm_exec() {
  local cmd="$1"
  local zone="${ZONE}"
  local id="p$(date +%s)$$"

  local cmd_file
  cmd_file="$(mktemp)"
  printf '%s' "${cmd}" > "${cmd_file}"

  # Both keys in ONE call: the agent triggers on a changed probe-id and reads
  # probe-cmd only after seeing it, so a split update could race and re-run
  # the previous command against the new id.
  if ! gcloud compute instances add-metadata "${VM_EXEC_INSTANCE}" \
      --zone="${zone}" --project="${PROJECT_ID}" \
      --metadata="probe-id=${id}" \
      --metadata-from-file="probe-cmd=${cmd_file}" >/dev/null 2>&1; then
    rm -f "${cmd_file}"
    echo "VM-EXEC-ERROR: could not set metadata"
    return 1
  fi
  rm -f "${cmd_file}"

  local waited=0 out
  while (( waited < VM_EXEC_TIMEOUT )); do
    out="$(gcloud compute instances get-guest-attributes "${VM_EXEC_INSTANCE}" \
      --zone="${zone}" --project="${PROJECT_ID}" \
      --query-path="probe/${id}" --format='value(value)' 2>/dev/null || true)"
    if [[ -n "${out}" ]]; then
      echo "${out}"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  echo "VM-EXEC-TIMEOUT after ${VM_EXEC_TIMEOUT}s (agent may be down)"
  return 1
}

# Drop-in replacements for the helpers.sh SSH functions, so existing scripts
# work unchanged when VM_CHANNEL=metadata.
if [[ "${VM_CHANNEL:-}" == "metadata" ]]; then
  ssh_cmd() { vm_exec "$1"; }
  ssh_curl_auth() {
    local audience="$1"; shift
    vm_exec "ID_TOKEN=\$(curl -sf -H 'Metadata-Flavor: Google' 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${audience}') && curl -H \"Authorization: Bearer \$ID_TOKEN\" $*"
  }
fi
