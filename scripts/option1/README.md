# Option A: Internal ALB via VPN

Proof-of-concept scripts for connecting Apigee X to Cloud Run via an internal HTTPS load balancer, with traffic routed through HA VPN tunnels between two VPCs.

> These scripts simulate the **Apigee VPC** and **Workloads VPC** (VPC Peering provisioning model). The VM acts as a stand-in for Apigee. See [Provisioning Decision](../../docs/apigee-provisioning-decision.md).

```
VM (10.0.0.x) [simulates Apigee in peered VPC]
  -> DNS resolves api.internal.example.com to 10.100.0.10 (ILB)
    -> HA VPN tunnel (BGP-learned route)
      -> Internal HTTPS Load Balancer
        -> Serverless NEG -> Cloud Run service
```

## Scripts

| Script | Resources |
|---|---|
| `setup.sh` | workloads-vpc, VPN firewall, HA VPN (gateways, 4 tunnels, BGP), ILB stack (NEG, backend, cert, proxy, fwd rule), DNS zone `api-internal-zone`, Apigee proxy target update |
| `test.sh` | BGP route verification, DNS resolution, HTTPS connectivity through VPN to ILB to Cloud Run |
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
./scripts/option1/setup.sh            # ~2 min
./scripts/option1/test.sh
# when done:
./scripts/option1/teardown.sh
```

## Cost while running

| Component | $/hr | $/day | Notes |
|---|---|---|---|
| HA VPN (4 tunnels) | ~$0.10 | ~$2.40 | $0.025/tunnel/hr |
| ILB forwarding rule | ~$0.025 | ~$0.60 | Regional HTTPS LB |
| Cloud Router (2x) | $0.00 | $0.00 | No charge |
| Cloud DNS | ~$0.0003 | ~$0.007 | Private zone |
| VM e2-micro | $0.00 | $0.00 | Free tier |
| Cloud Run | $0.00 | $0.00 | Scale to zero |
| Artifact Registry | ~$0.00 | ~$0.00 | Pennies |
| **Total** | **~$0.13** | **~$3.01** | Most expensive option (VPN tunnels) |

Run `./scripts/option1/teardown.sh` when done, then `./scripts/shared/teardown-base.sh` to avoid ongoing costs.
