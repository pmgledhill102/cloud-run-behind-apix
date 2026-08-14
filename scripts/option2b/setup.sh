#!/usr/bin/env bash
#
# option2b/setup.sh — Option B + VPC Service Controls perimeter (~2-5 min)
#
# Builds on option2 (PGA via restricted VIP) by enforcing a REAL VPC-SC service
# perimeter around the project. Option2 routes traffic through the restricted
# VIP (199.36.153.4/30) — the VPC-SC-enforcing endpoint — but creates no
# perimeter, so nothing is actually enforced. This option adds the perimeter
# and proves enforcement both ways (see test.sh).
#
# Thin serial wrapper over the two phases (see each script's header for the
# full resource list):
#   setup-early.sh  — ACM API, access policy, restricted-VIP route, ENFORCED
#                     perimeter (needs only setup-base; no Apigee)
#   setup-finish.sh — Apigee tenant plumbing: peering VPC-SC, dns.peer,
#                     custom route export, peered DNS domain, proxy target
#
# Run this for the simple serial flow. To hide the ~1-35 min perimeter
# propagation inside the ~60-90 min Apigee provisioning window, run the
# phases separately instead:
#   setup-base → (setup-slow ∥ option2b/setup-early) → option2/setup
#              → option2b/setup-finish → option2b/test
#
# Prerequisites:
#   - shared/setup-base.sh and option2/setup.sh completed
#   - Caller needs org-level roles/accesscontextmanager.policyAdmin to create
#     the access policy. If you already have a policy, skip creation with:
#       PROJECT_ID=<your-project> ACCESS_POLICY_ID=1234567890 ./scripts/option2b/setup.sh
#
# NOTE: perimeter changes can take a few minutes (up to ~30) to propagate.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/setup-early.sh"
echo ""
"${SCRIPT_DIR}/setup-finish.sh"
