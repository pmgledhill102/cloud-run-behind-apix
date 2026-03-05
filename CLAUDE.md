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
