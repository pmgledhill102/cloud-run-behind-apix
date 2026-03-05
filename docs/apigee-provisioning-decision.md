# Apigee Provisioning Model: Decision Record

## Context

Apigee X supports two provisioning models for southbound connectivity (Apigee reaching backend services):

| | VPC Peering (legacy) | PSC Non-Peering (recommended for new) |
|---|---|---|
| **How it works** | Apigee peers to a customer-managed "Apigee VPC" | Apigee uses PSC endpoint attachments |
| **Customer VPC required** | Yes -- dedicated Apigee VPC | No intermediate VPC needed |
| **DNS resolution** | Inside the peered Apigee VPC | Via PSC plumbing into customer VPC |
| **Traffic routing** | Through peered VPC networking | Through PSC endpoint attachments |
| **VPN to Workloads VPC** | Via HA VPN from Apigee VPC | Not needed (PSC replaces it) |

## Decision

**We use the VPC Peering model.** This matches the existing production Apigee deployment at the organisation.

All architecture documentation and PoC scripts in this repository assume VPC Peering provisioning. The PSC non-peering model is noted for reference where relevant, but is not the primary focus.

## Apigee Billing: Pay-As-You-Go

Apigee X offers three billing options:

| Model | Cost | Commitment |
|---|---|---|
| **Subscription** | ~$10K+/year | Annual contract |
| **Pay-as-you-go** | $0.50/hour + usage | No commitment, billed per hour |
| **Eval (sandbox)** | Free Apigee license (60 days) | Underlying GCP resources still cost money |

### Pay-as-you-go for testing

The pay-as-you-go model at $0.50/hour makes testing feasible without a subscription commitment. For a 6-hour test session:

| Component | Rate | 6hr cost |
|---|---|---|
| Apigee runtime | $0.50/hr | $3.00 |
| HA VPN tunnels (x4, Option A only) | $0.05/hr each | $1.20 |
| Internal ALB forwarding rule (Options A/D) | ~$0.025/hr | $0.15 |
| PSC forwarding rule (Options C/D) | ~$0.025/hr | $0.15 |
| Cloud Routers | Free | $0.00 |
| DNS zones | Negligible | ~$0.01 |
| Cloud Run | Per-request | ~$0.01 |

**Total for 6 hours:** ~$3-5 depending on option tested. The Apigee runtime dominates.

### Eval sandbox alternative

The 60-day eval sandbox provides a free Apigee license but underlying GCP resources still cost ~$2-5/day. Eval orgs cannot be converted to paid orgs. See [apigee-eval-org-notes.md](apigee-eval-org-notes.md) for details.

### Impact on provisioning model

Both pay-as-you-go and eval support VPC Peering provisioning. The "Set up with defaults" button in the Apigee console creates a PSC non-peering instance; to test with VPC Peering, use "Customise your setup" and select VPC Peering.

## How VPC Peering Affects Each Option

With VPC peering, Apigee resolves DNS and routes traffic through the peered Apigee VPC. This determines where DNS zones, PSC endpoints, and PGA must be configured.

| Option | Where DNS zone lives | Where PSC/PGA is configured | VPN needed? |
|---|---|---|---|
| **A** (ILB via VPN) | Apigee VPC | N/A (traffic routes via VPN to ILB in Workloads VPC) | Yes |
| **B** (PGA) | Apigee VPC | PGA enabled on Apigee VPC subnet | No |
| **C** (PSC Google APIs) | Apigee VPC | PSC endpoint in Apigee VPC | No |
| **D** (PSC Service Attachment) | Apigee VPC | PSC endpoint in Apigee VPC | No |

## References

- [Apigee X provisioning overview](https://cloud.google.com/apigee/docs/api-platform/get-started/provisioning-intro)
- [Compare eval and paid organizations](https://cloud.google.com/apigee/docs/api-platform/get-started/compare-paid-eval)
- [Apigee pricing](https://cloud.google.com/apigee/pricing)
