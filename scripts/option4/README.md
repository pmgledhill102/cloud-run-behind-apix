# Option D: PSC Service Attachment

Proof-of-concept scripts for connecting Apigee X to Cloud Run via Private Service Connect with a published Service Attachment. Two VPCs connected via PSC (not VPN).

> These scripts simulate the **Apigee VPC** and **Workloads VPC** (VPC Peering provisioning model). The VM acts as a stand-in for Apigee. See [Provisioning Decision](../../docs/apigee-provisioning-decision.md).

```
VM (10.0.0.x) [simulates Apigee in peered VPC]
  → DNS resolves api.internal.example.com to 10.0.0.50 (PSC endpoint)
    → PSC Service Attachment
      → Internal HTTPS Load Balancer (10.100.0.10)
        → Serverless NEG → Cloud Run service
```

## Scripts

| Script | Resources |
|---|---|
| `setup.sh` | workloads-vpc, PSC NAT subnet, ILB stack, Service Attachment `sa-workloads`, PSC endpoint (10.0.0.50), DNS zone `api-internal-zone`, Apigee Endpoint Attachment |
| `test.sh` | Service Attachment status, PSC connection status, DNS resolution, HTTP connectivity, Apigee end-to-end |
| `teardown.sh` | Reverse-order cleanup of option-specific resources |

## Prerequisites

Run shared setup first (once across all options):

```bash
./scripts/shared/setup-iam.sh
./scripts/shared/setup-base.sh        # ~5 min
./scripts/shared/setup-slow.sh        # ~60-90 min (Apigee — optional, can run in parallel)
```

## Run instructions

```bash
./scripts/option4/setup.sh            # ~2 min
./scripts/option4/test.sh
# when done:
./scripts/option4/teardown.sh
```

## Cost while running

| Component | $/hr | $/day | Notes |
|---|---|---|---|
| ILB forwarding rule | ~$0.025 | ~$0.60 | Regional HTTPS LB |
| PSC Service Attachment | ~$0.01 | ~$0.24 | Per-connection-hour |
| PSC endpoint | ~$0.01 | ~$0.24 | Consumer endpoint |
| Cloud DNS | ~$0.0003 | ~$0.007 | Private zone |
| VM e2-micro | $0.00 | $0.00 | Free tier |
| Cloud Run | $0.00 | $0.00 | Scale to zero |
| Artifact Registry | ~$0.00 | ~$0.00 | Pennies |
| **Total** | **~$0.05** | **~$1.09** | Two VPCs, ILB, PSC |

No VPN tunnels, but ILB + PSC make this more expensive than Options B and C.

Run `./scripts/option4/teardown.sh` when done, then `./scripts/shared/teardown-base.sh` to avoid ongoing costs.
