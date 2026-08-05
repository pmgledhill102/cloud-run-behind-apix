#!/usr/bin/env bash
#
# stack-up.sh — Orchestrate full-stack bring-up (parallel #52 path)
#
# Encodes the multi-step bring-up dance that was run by hand three times on
# 2026-08-03 (see docs/option-b-vpcsc-field-notes.md and
# docs/auth/auth-poc-field-notes.md):
#
#   setup-iam → setup-base → (setup-slow ∥ option2b/setup-early)
#     → option2/setup → option2b/setup-finish → option2b/test
#     → auth/setup → auth/test → mock-apigee/setup → mock-apigee/test
#
# setup-slow.sh (Apigee org + instance, ~60-90 min) runs in the background
# while option2b/setup-early.sh (perimeter creation + its ~1-35 min
# propagation) runs in the foreground — both finish inside the Apigee
# provisioning window instead of stacking serially end to end.
#
# Setup steps are fatal on failure (each depends on the one before it). Test
# scripts are best-effort: a failure is reported and the stack continues,
# since option2b's perimeter propagation and Apigee's flow-hook activation
# are known to leave a short window where a re-run (not a fix) is the right
# call — see the WARNING printed after any failing test step.
#
# Per-tier skip flags (set to 1 to skip):
#   SKIP_VPCSC=1   skip option2b (VPC-SC perimeter) setup-early/setup-finish/test
#   SKIP_AUTH=1    skip the auth PoC (also skips mock-apigee — it depends on
#                  auth's keypair + cr-auth-echo)
#   SKIP_MOCK=1    skip the mock-apigee quick stack only
#
# Usage:
#   PROJECT_ID=sb-paul-g-apixN ./scripts/shared/stack-up.sh
#   SKIP_MOCK=1 PROJECT_ID=sb-paul-g-apixN ./scripts/shared/stack-up.sh
#
set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID must be set explicitly — env.sh has no live default (sandboxes are ephemeral by design). Usage: PROJECT_ID=<your-project> ./scripts/shared/stack-up.sh}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="$(mktemp -d)"

TEST_FAILURES=()

step() {
  echo ""
  echo "############################################################"
  echo "# $*"
  echo "############################################################"
}

# run_test <label> <script> — best-effort: report and continue on failure.
run_test() {
  local label="$1" script="$2"
  step "${label}"
  if ! "${script}"; then
    echo ""
    echo "WARNING: ${label} reported a failure."
    echo "         This can be transient (perimeter/flow-hook propagation) —"
    echo "         re-run it directly once things have settled: ${script}"
    TEST_FAILURES+=("${label}")
  fi
}

echo "=== Full-stack bring-up — project: ${PROJECT_ID} ==="
echo "Skip flags: SKIP_VPCSC=${SKIP_VPCSC:-0} SKIP_AUTH=${SKIP_AUTH:-0} SKIP_MOCK=${SKIP_MOCK:-0}"
echo "Logs:       ${LOG_DIR}"

step "setup-iam.sh"
"${SCRIPT_DIR}/setup-iam.sh"

step "setup-base.sh"
"${SCRIPT_DIR}/setup-base.sh"

SLOW_LOG="${LOG_DIR}/setup-slow.log"
step "setup-slow.sh (background, ~60-90 min — log: ${SLOW_LOG})"
"${SCRIPT_DIR}/setup-slow.sh" >"${SLOW_LOG}" 2>&1 &
SLOW_PID=$!

if [[ "${SKIP_VPCSC:-}" == "1" ]]; then
  echo "SKIP_VPCSC=1 — skipping option2b/setup-early.sh"
else
  step "option2b/setup-early.sh (runs in parallel with setup-slow.sh)"
  "${SCRIPTS_ROOT}/option2b/setup-early.sh"
fi

step "Waiting for setup-slow.sh to finish..."
while kill -0 "${SLOW_PID}" 2>/dev/null; do
  sleep 60
  tail -n 1 "${SLOW_LOG}" 2>/dev/null | sed 's/^/  [setup-slow] /' || true
done
if ! wait "${SLOW_PID}"; then
  echo ""
  echo "ERROR: setup-slow.sh failed. Full log:"
  cat "${SLOW_LOG}"
  exit 1
fi
echo "setup-slow.sh complete."

step "option2/setup.sh"
"${SCRIPTS_ROOT}/option2/setup.sh"

if [[ "${SKIP_VPCSC:-}" == "1" ]]; then
  echo "SKIP_VPCSC=1 — skipping option2b/setup-finish.sh and option2b/test.sh"
else
  step "option2b/setup-finish.sh"
  "${SCRIPTS_ROOT}/option2b/setup-finish.sh"

  run_test "option2b/test.sh" "${SCRIPTS_ROOT}/option2b/test.sh"
fi

if [[ "${SKIP_AUTH:-}" == "1" ]]; then
  echo ""
  echo "SKIP_AUTH=1 — skipping auth PoC (and mock-apigee, which depends on it)"
else
  step "auth/setup.sh"
  "${SCRIPTS_ROOT}/auth/setup.sh"

  run_test "auth/test.sh" "${SCRIPTS_ROOT}/auth/test.sh"

  if [[ "${SKIP_MOCK:-}" == "1" ]]; then
    echo ""
    echo "SKIP_MOCK=1 — skipping mock-apigee stack"
  else
    step "mock-apigee/setup.sh"
    "${SCRIPTS_ROOT}/mock-apigee/setup.sh"

    run_test "mock-apigee/test.sh" "${SCRIPTS_ROOT}/mock-apigee/test.sh"
  fi
fi

step "Stack up complete"
echo "Project: ${PROJECT_ID}"
if [[ "${#TEST_FAILURES[@]}" -gt 0 ]]; then
  echo ""
  echo "Setup steps all succeeded. These test steps reported failures — re-run"
  echo "them directly once things have settled (see WARNING above each):"
  for f in "${TEST_FAILURES[@]}"; do
    echo "  - ${f}"
  done
else
  echo "All setup and test steps passed."
fi
echo ""
echo "Remember: Apigee PAYG billing (~\$0.50/hr) is running until you tear the"
echo "stack down — ./scripts/shared/stack-down.sh when you're done."
