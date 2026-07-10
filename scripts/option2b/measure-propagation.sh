#!/usr/bin/env bash
#
# option2b/measure-propagation.sh — Measure VPC-SC perimeter propagation time
#
# Probes the perimeter's NEGATIVE test (VM → out-of-perimeter public GCS
# bucket) on an interval and reports how long the enforcement state takes to
# flip. Direction-agnostic:
#   - run immediately after option2b/setup.sh    → measures open → BLOCKED
#   - run immediately after option2b/teardown.sh → measures blocked → OPEN
#
# The state must hold for CONFIRM consecutive probes before it counts —
# enforcement can flap mid-propagation.
#
# Usage:
#   ./scripts/option2b/measure-propagation.sh
#   INTERVAL=30 MAX_MINUTES=90 ./scripts/option2b/measure-propagation.sh
#
# Output is timestamped per probe, so a scroll-back after an unattended run
# still yields the number.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../shared/env.sh"
source "${SHARED_DIR}/lib/helpers.sh"

INTERVAL="${INTERVAL:-60}"        # seconds between probes
MAX_MINUTES="${MAX_MINUTES:-60}"  # give up after this long
CONFIRM="${CONFIRM:-3}"           # consecutive probes to confirm a new state
EXTERNAL_BUCKET="gcp-public-data-landsat"
NEGATIVE_URL="https://storage.googleapis.com/storage/v1/b/${EXTERNAL_BUCKET}"

probe() {
  # Prints the HTTP status of the negative probe from the VM ("000" on error)
  ssh_cmd "curl -s --max-time 15 -o /dev/null -w '%{http_code}' '${NEGATIVE_URL}'" 2>/dev/null || echo "000"
}

state_of() {
  case "$1" in
    403) echo "BLOCKED" ;;
    200) echo "OPEN" ;;
    *)   echo "ERROR($1)" ;;
  esac
}

echo "=== VPC-SC propagation measurement ==="
echo "Project:  ${PROJECT_ID}"
echo "Probe:    VM → ${NEGATIVE_URL}"
echo "Interval: ${INTERVAL}s, max ${MAX_MINUTES}m, confirm x${CONFIRM}"
echo "Started:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""

START_EPOCH="$(date +%s)"

CODE="$(probe)"
INITIAL_STATE="$(state_of "${CODE}")"
if [[ "${INITIAL_STATE}" == ERROR* ]]; then
  echo "ERROR: initial probe failed (HTTP ${CODE}). Is vm-test up and IAP SSH working?"
  exit 1
fi
echo "[$(date '+%H:%M:%S') +0m0s] HTTP ${CODE} — initial state: ${INITIAL_STATE}"
echo "Watching for the state to flip away from ${INITIAL_STATE}..."
echo ""

STREAK=0
NEW_STATE=""
FLIP_ELAPSED=""

while true; do
  sleep "${INTERVAL}"
  ELAPSED=$(( $(date +%s) - START_EPOCH ))
  ELAPSED_FMT="$((ELAPSED / 60))m$((ELAPSED % 60))s"

  if (( ELAPSED > MAX_MINUTES * 60 )); then
    echo ""
    echo "=== No confirmed state change after ${MAX_MINUTES} minutes ==="
    echo "State is still ${INITIAL_STATE}. Either propagation is unusually slow"
    echo "or nothing changed the perimeter — check setup/teardown actually ran."
    exit 1
  fi

  CODE="$(probe)"
  STATE="$(state_of "${CODE}")"

  if [[ "${STATE}" == "${INITIAL_STATE}" || "${STATE}" == ERROR* ]]; then
    if [[ -n "${NEW_STATE}" ]]; then
      echo "[$(date '+%H:%M:%S') +${ELAPSED_FMT}] HTTP ${CODE} — ${STATE} (flapped back — resetting confirmation)"
    else
      echo "[$(date '+%H:%M:%S') +${ELAPSED_FMT}] HTTP ${CODE} — ${STATE}"
    fi
    STREAK=0
    NEW_STATE=""
    FLIP_ELAPSED=""
    continue
  fi

  # A state different from the initial one
  if [[ "${STATE}" == "${NEW_STATE}" ]]; then
    STREAK=$((STREAK + 1))
  else
    NEW_STATE="${STATE}"
    STREAK=1
    FLIP_ELAPSED="${ELAPSED_FMT}"
  fi
  echo "[$(date '+%H:%M:%S') +${ELAPSED_FMT}] HTTP ${CODE} — ${STATE} (confirmation ${STREAK}/${CONFIRM})"

  if (( STREAK >= CONFIRM )); then
    echo ""
    echo "=== Propagation measured ==="
    echo "State change:   ${INITIAL_STATE} → ${NEW_STATE}"
    echo "First observed: ${FLIP_ELAPSED} after start"
    echo "Confirmed:      ${ELAPSED_FMT} after start (${CONFIRM} consecutive probes)"
    echo ""
    echo "NOTE: the clock starts when THIS script starts. For a true"
    echo "creation-to-enforcement number, start it immediately after"
    echo "setup.sh/teardown.sh finishes and add the gap manually."
    exit 0
  fi
done
