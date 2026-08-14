#!/usr/bin/env bash
#
# stack-down.sh — Orchestrate full-stack teardown (reverse dependency order)
#
# Reverse of stack-up.sh:
#
#   mock-apigee → auth → option2b → option2 → teardown-slow → teardown-base
#     → teardown-iam
#
# Ordering matters for two reasons:
#   - auth's flow hook must detach before option2b's/option2's plain-proxy
#     tests would ever pass again, so auth comes off before option2b/option2.
#   - teardown-base cannot run until teardown-slow removes the Apigee VPC
#     peering — running it first just wastes a step and prints warning noise.
#
# Every step below is one of this repo's existing idempotent teardown
# scripts — each already skips resources that don't exist, so it's safe to
# run stack-down.sh even for a partial stack (e.g. brought up with
# SKIP_MOCK=1). Individual step failures are reported but don't stop the
# teardown, EXCEPT teardown-slow.sh: if that fails, teardown-base.sh is
# skipped rather than run against a VPC still held by the Apigee peering.
#
# teardown-slow.sh's confirmation prompt is answered non-interactively here
# (this script IS the confirmation).
#
# Usage:
#   PROJECT_ID=<your-project> ./scripts/shared/stack-down.sh
#
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID must be set explicitly — env.sh has no default (PoC projects are ephemeral sandboxes). Set it once per shell: export PROJECT_ID=<your-project>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

STEP_FAILURES=()

step() {
  echo ""
  echo "############################################################"
  echo "# $*"
  echo "############################################################"
}

# run_step <label> <script> — best-effort: report and continue on failure.
run_step() {
  local label="$1" script="$2"
  step "${label}"
  if ! "${script}"; then
    echo ""
    echo "WARNING: ${label} reported a failure — continuing teardown."
    STEP_FAILURES+=("${label}")
  fi
}

echo "=== Full-stack teardown — project: ${PROJECT_ID} ==="

run_step "mock-apigee/teardown.sh" "${SCRIPTS_ROOT}/mock-apigee/teardown.sh"
run_step "auth/teardown.sh" "${SCRIPTS_ROOT}/auth/teardown.sh"
run_step "option2b/teardown.sh" "${SCRIPTS_ROOT}/option2b/teardown.sh"
run_step "option2/teardown.sh" "${SCRIPTS_ROOT}/option2/teardown.sh"

step "teardown-slow.sh (answering the confirmation prompt non-interactively)"
if printf 'y\n' | "${SCRIPT_DIR}/teardown-slow.sh"; then
  run_step "teardown-base.sh" "${SCRIPT_DIR}/teardown-base.sh"
  run_step "teardown-iam.sh" "${SCRIPT_DIR}/teardown-iam.sh"
else
  echo ""
  echo "ERROR: teardown-slow.sh failed — NOT running teardown-base.sh, since the"
  echo "       Apigee peering may still be holding the VPC (it would just fail"
  echo "       too). Investigate, then finish the teardown manually:"
  echo "         printf 'y\n' | ./scripts/shared/teardown-slow.sh"
  echo "         ./scripts/shared/teardown-base.sh"
  echo "         ./scripts/shared/teardown-iam.sh"
  exit 1
fi

step "Stack down complete"
if [[ "${#STEP_FAILURES[@]}" -gt 0 ]]; then
  echo "These steps reported failures — check the output above and re-run"
  echo "them directly once resolved:"
  for f in "${STEP_FAILURES[@]}"; do
    echo "  - ${f}"
  done
else
  echo "All teardown steps completed cleanly."
fi
echo ""
echo "Project ${PROJECT_ID}'s Apigee org is soft-deleted (billing stops now;"
echo "permanent deletion in ~24 hours)."
