# Option C: PSC Endpoint for Google APIs

Proof-of-concept scripts for connecting Apigee X to Cloud Run via a Private Service Connect endpoint for Google APIs. Traffic flows over Google's backbone, bypassing VPN tunnels entirely.

> These scripts simulate the **Apigee VPC** (VPC Peering provisioning model). The VM acts as a stand-in for Apigee, validating the same network path Apigee would use when peered into this VPC. See [Provisioning Decision](../../docs/apigee-provisioning-decision.md).

```
VM (10.0.0.x) [simulates Apigee in peered VPC]
  → DNS resolves *.run.app to 10.0.0.100 (PSC endpoint)
    → PSC forwarding rule
      → Google backbone
        → Cloud Run service
```

## Scripts

| Script | Resources |
|---|---|
| `setup.sh` | Extra Cloud Run services (if SERVICE_COUNT>1), global PSC endpoint `pscgoogleapis` (10.0.1.100), private DNS zone `run-app-psc` with `*.run.app → 10.0.1.100` |
| `test.sh` | DNS resolution + HTTP connectivity verification (single or scaled mode) |
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
./scripts/option3/setup.sh            # ~1 min
./scripts/option3/test.sh
# when done:
./scripts/option3/teardown.sh

# Scaled variant (20 services):
SERVICE_COUNT=20 ./scripts/option3/setup.sh
SERVICE_COUNT=20 ./scripts/option3/test.sh
SERVICE_COUNT=20 ./scripts/option3/teardown.sh
```

## Cost while running

| Component | $/hr | $/day | Notes |
|---|---|---|---|
| PSC forwarding rule | ~$0.025 | ~$0.60 | Charged like a standard forwarding rule |
| PSC data processing | — | — | ~$0.01/GB (negligible for PoC) |
| Cloud DNS private zone | ~$0.0003 | ~$0.007 | ~$0.20/month |
| VM `e2-micro` | $0.00 | $0.00 | Free tier eligible |
| Cloud Run `cr-hello` | $0.00 | $0.00 | Scale to zero, no minimum instances |
| Artifact Registry | ~$0.00 | ~$0.00 | Pennies for one small image |
| **Total** | **~$0.03** | **~$0.61** | Safe to leave running for a few days |

No VPN tunnels or load balancers — this is the cheapest option after Option B (PGA).

Run `./scripts/option3/teardown.sh` when done, then `./scripts/shared/teardown-base.sh` to avoid ongoing costs.
