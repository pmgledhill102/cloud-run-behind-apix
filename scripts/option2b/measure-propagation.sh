#!/usr/bin/env bash
#
# option2b/measure-propagation.sh — Measure VPC-SC perimeter propagation time
#
# Probes the perimeter's NEGATIVE test (VM → out-of-perimeter public GCS
# bucket) on an interval and reports how long the enforcement state takes to
# reach the expected TARGET state:
#
#   ./scripts/option2b/setup.sh    && ./scripts/option2b/measure-propagation.sh blocked
#   ./scripts/option2b/teardown.sh && ./scripts/option2b/measure-propagation.sh open
#
# Passing the target matters: if propagation completes before the first probe
# (deletion has been observed to propagate near-instantly), an auto-detect
# script would anchor on the post-flip state and wait for a change that
# already happened. With a target, "already there at first probe" is a valid,
# fast result — reported as such.
#
# With no argument, falls back to watching for any state change away from the
# initial state (useful when you don't know the direction).
#
# The target state must hold for CONFIRM consecutive probes before it counts —
# enforcement can flap mid-propagation.
#
# Usage:
#   ./scripts/option2b/measure-propagation.sh [blocked|open]
#   INTERVAL=30 MAX_MINUTES=90 ./scripts/option2b/measure-propagation.sh blocked
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

TARGET_STATE=""
if [[ $# -ge 1 ]]; then
  case "$(echo "$1" | tr '[:lower:]' '[:upper:]')" in
    BLOCKED) TARGET_STATE="BLOCKED" ;;
    OPEN)    TARGET_STATE="OPEN" ;;
    *)
      echo "Usage: $0 [blocked|open]"
      echo "  blocked — expect enforcement to arrive (run after setup.sh)"
      echo "  open    — expect enforcement to lift (run after teardown.sh)"
      exit 2
      ;;
  esac
fi

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
echo "Target:   ${TARGET_STATE:-any state change}"
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

# --- Already at the target? Confirm quickly and report. ---
if [[ -n "${TARGET_STATE}" && "${INITIAL_STATE}" == "${TARGET_STATE}" ]]; then
  echo "Initial state already matches target — confirming..."
  STABLE=true
  for _ in $(seq 2 "${CONFIRM}"); do
    sleep 10
    CODE="$(probe)"
    STATE="$(state_of "${CODE}")"
    ELAPSED=$(( $(date +%s) - START_EPOCH ))
    echo "[$(date '+%H:%M:%S') +$((ELAPSED / 60))m$((ELAPSED % 60))s] HTTP ${CODE} — ${STATE}"
    [[ "${STATE}" == "${TARGET_STATE}" ]] || { STABLE=false; break; }
  done
  if [[ "${STABLE}" == "true" ]]; then
    echo ""
    echo "=== Already ${TARGET_STATE} at first probe ==="
    echo "Propagation completed before measurement started. If you chained this"
    echo "directly after setup.sh/teardown.sh, the flip took less time than the"
    echo "gap between the perimeter change and the first probe."
    exit 0
  fi
  echo "State flapped away from ${TARGET_STATE} — watching until it settles..."
  echo ""
fi

if [[ -n "${TARGET_STATE}" ]]; then
  echo "Watching for ${TARGET_STATE} (confirmed x${CONFIRM})..."
else
  echo "Watching for the state to flip away from ${INITIAL_STATE}..."
fi
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
    echo "=== Target not reached after ${MAX_MINUTES} minutes ==="
    if [[ -n "${TARGET_STATE}" ]]; then
      echo "Expected ${TARGET_STATE}; still not confirmed. Either propagation is"
      echo "unusually slow, or the perimeter change this was meant to measure"
      echo "didn't happen — check setup/teardown output."
    else
      echo "State is still ${INITIAL_STATE}. Either propagation is unusually slow"
      echo "or nothing changed the perimeter — check setup/teardown actually ran."
    fi
    exit 1
  fi

  CODE="$(probe)"
  STATE="$(state_of "${CODE}")"

  # Which state counts as "the one we're waiting for"?
  WANTED="${TARGET_STATE:-}"
  if [[ -z "${WANTED}" ]]; then
    # auto mode: anything that isn't the initial state (and isn't an error)
    if [[ "${STATE}" != "${INITIAL_STATE}" && "${STATE}" != ERROR* ]]; then
      WANTED="${STATE}"
    fi
  fi

  if [[ -z "${WANTED}" || "${STATE}" != "${WANTED}" ]]; then
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
