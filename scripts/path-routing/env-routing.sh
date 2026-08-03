#!/usr/bin/env bash
#
# env-routing.sh — Path-routing PoC configuration (issue #62)
#
# Source AFTER shared/env.sh + helpers.sh:
#   source "${SCRIPT_DIR}/env-routing.sh"
#
# Names mirror docs/path-routing-at-scale.md §1's worked example
# (/payments/cards/issuing) so the doc and the PoC read as one.
#

# --- Cloud Run clones (all from the shared cr-hello image, no builds) ---
SVC_PAYMENTS="cr-route-payments"
SVC_CARDS="cr-route-cards"
SVC_ISSUING="cr-route-issuing"

# --- Proxies (pr- prefix; BasePath in comment) ---
PROXY_PAYMENTS="pr-payments"                        # /payments
PROXY_CARDS="pr-payments-cards"                     # /payments/cards
PROXY_ISSUING="pr-payments-cards-issuing"           # /payments/cards/issuing (carve-out)
PROXY_DUP="pr-payments-cards-dup"                   # /payments/cards (conflict probe)

# --- Carve-out probe ---
PROBE_SECONDS="${PROBE_SECONDS:-300}"   # 1s-resolution probe window (test phase 3)
