# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Documentation and architecture exploration for connecting Apigee X to Cloud Run services. Covers four connectivity patterns with different trade-offs for cost, scalability, DNS complexity, and load balancer requirements.

The key constraint: Apigee runs in its own VPC connected to the Workloads VPC via HA VPN (not direct VPC peering between Apigee and Workloads).

The repository assumes the **VPC Peering** provisioning model (Apigee peers to a customer "Apigee VPC", connected to Workloads VPC via VPN). The PSC non-peering alternative is documented for reference. See `docs/apigee-provisioning-decision.md` for rationale.

## Architecture Options

- **Option A**: Internal ALB + Serverless NEG (traffic via VPN) — `docs/option-a-ilb-via-vpn.md`
- **Option B**: Private Google Access (traffic bypasses VPN) — `docs/option-b-pga.md`
- **Option C**: PSC Endpoint for Google APIs (traffic bypasses VPN) — `docs/option-c-psc-google-apis.md`
- **Option D**: PSC Published Service / Service Attachment (traffic via PSC) — `docs/option-d-psc-service-attachment.md`

## Documentation Structure

Each option doc follows the same structure:
1. Overview (assumes VPC Peering)
2. Architecture diagram reference
3. VPC Peering model details (primary)
4. PSC non-peering alternative (for reference)
5. Traffic flow walkthrough
6. Components required
7. DNS configuration
8. Firewall rules
9. Cost estimate
10. Scaling characteristics
11. Testing requirements

Cross-cutting docs:
- `docs/dns-guide.md` — DNS reference across all options
- `docs/scaling-analysis.md` — Scale to 1000s of services analysis
- `docs/option-c-scaled.md` — 20-service PoC validating Option C linear scaling

## PoC Scripts

Scripts are structured in three tiers for fast iteration:

### Shared infrastructure (`scripts/shared/`)
- `env.sh` — All config vars (PROJECT_ID, REGION, etc.)
- `lib/helpers.sh` — `resource_exists()`, `ssh_cmd()`, `delete_subnet_with_retry()`
- `lib/workloads-vpc.sh` — Create/delete workloads-vpc (used by options 1 & 4)
- `lib/ilb-stack.sh` — Create/delete ILB stack (used by options 1 & 4)
- `lib/apigee-proxy.sh` — `update_apigee_proxy_target()` (skips if no Apigee)
- `container/` — Single copy of Dockerfile + main.go
- `setup-iam.sh` — One SA (`apigee-poc`) with superset of all roles
- `setup-base.sh` — apigee-vpc, subnet, firewall, NAT, VM, AR, image, Cloud Run (~5 min)
- `setup-slow.sh` — Apigee org + instance + env + proxy (~60-90 min)
- `teardown-base.sh`, `teardown-slow.sh`, `teardown-iam.sh` — Reverse order

### Option-specific scripts (`scripts/option{1,2,3,4}/`)
- `setup.sh` — Option-specific resources only (~1-2 min each)
- `teardown.sh` — Reverse of setup.sh
- `test.sh` — Verification tests

### Workflow
```bash
# Once at start:
./scripts/shared/setup-iam.sh
./scripts/shared/setup-base.sh      # ~5 min
./scripts/shared/setup-slow.sh      # ~60-90 min (can run in parallel)

# Per option — fast and repeatable:
./scripts/option3/setup.sh           # ~1 min
./scripts/option3/test.sh
./scripts/option3/teardown.sh

# Scaled variant (option 3 only):
SERVICE_COUNT=20 ./scripts/option3/setup.sh

# Full teardown:
./scripts/shared/teardown-slow.sh
./scripts/shared/teardown-base.sh
./scripts/shared/teardown-iam.sh
```

### Options
- `scripts/option1/` — Option A: ILB via VPN (workloads-vpc + VPN + ILB + DNS)
- `scripts/option2/` — Option B: PGA (DNS zone only — simplest)
- `scripts/option3/` — Option C: PSC Google APIs (PSC endpoint + DNS; `SERVICE_COUNT=20` for scaled)
- `scripts/option4/` — Option D: PSC Service Attachment (workloads-vpc + ILB + SA + PSC + Apigee EA)

**Note:** Options 1 & 4 both use workloads-vpc — don't run both simultaneously.

## Diagrams

All `.drawio` files in `docs/diagrams/` use:
- `mxgraph.gcp2.*` shapes
- Google Material color palette
- 1600x900 canvas
- Container grouping for VPCs and subnets
- Traffic flow arrows with numbered steps

The `.github/workflows/drawio-export.yml` workflow auto-exports `.drawio` → `.svg` on push to main.

## Issue Tracking

Uses Beads (`bd` CLI). See AGENTS.md.

## Session Close Protocol

Work is NOT complete until `git push` succeeds. See AGENTS.md for full checklist.
