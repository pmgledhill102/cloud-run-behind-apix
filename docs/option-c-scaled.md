# Option C Scaled: PSC Endpoint for Google APIs (20+ Services)

## Overview

Option C scales linearly with zero infrastructure changes. The single PSC endpoint and wildcard DNS zone (`*.run.app → PSC IP`) cover all Cloud Run services regardless of count. This document validates that claim with a 20-service proof of concept.

## Architecture

See [architecture diagram](diagrams/option-c-scaled.drawio).

Traffic flow is identical to single-service Option C:
1. Apigee proxy sends request to `cr-svc-NN-abc-uc.a.run.app`
2. DNS resolves `*.run.app` to PSC endpoint IP (`10.0.0.100`)
3. PSC tunnels traffic through Google's backbone
4. Cloud Run receives the request

## What changes when adding services

| Component | Changes? | Notes |
|---|---|---|
| Cloud Run deployments | Yes | One `gcloud run deploy` per service |
| Apigee API proxy configs | Yes | One proxy per service (standard Apigee work) |
| PSC endpoint | No | Single endpoint covers all `*.run.app` |
| DNS zone / records | No | Wildcard `*.run.app` covers all services |
| Firewall rules | No | No VPC-level traffic to manage |
| VPN tunnels | N/A | Not used in Option C |

## What stays the same

The entire networking layer is unchanged:
- **PSC forwarding rule**: One global rule targeting `all-apis` bundle
- **DNS zone**: One private zone with `*.run.app` wildcard
- **No per-service NEGs, backend services, or forwarding rules**
- **No ILB, VPN, or Service Attachment changes**

This is the key advantage of Option C over Options A and D, which require per-service ILB backend configuration.

## PoC validation

The `scripts/option3/` directory supports a scaled variant via `SERVICE_COUNT` — it deploys 20 Cloud Run services (`cr-svc-01` through `cr-svc-20`) and verifies each is reachable through the single PSC endpoint.

```bash
# Shared setup (once):
./scripts/shared/setup-iam.sh
./scripts/shared/setup-base.sh

# Scaled option 3:
SERVICE_COUNT=20 ./scripts/option3/setup.sh    # deploys 20 Cloud Run services + PSC + DNS
SERVICE_COUNT=20 ./scripts/option3/test.sh     # tests all 20 services
SERVICE_COUNT=20 ./scripts/option3/teardown.sh # cleanup
```

## Cost

| Component | $/month | Notes |
|---|---|---|
| PSC forwarding rule | ~$18 | Fixed cost, independent of service count |
| DNS zone | ~$0.20 | Single zone, wildcard record |
| Cloud Run (20 services) | $0.00 (idle) | Scale to zero when not in use |
| **Total (idle)** | **~$18.20** | Same as single-service Option C |

## Limits

- **PSC**: 65,536 concurrent connections per endpoint (shared across all services)
- **Cloud Run**: 5,000 services per project per region (GCP quota, can be increased)
- **DNS**: No practical limit on wildcard resolution
