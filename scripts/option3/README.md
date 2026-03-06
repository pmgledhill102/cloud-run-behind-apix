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
| `setup-iam.sh` | SA `apigee-psc-poc`, 8 IAM roles, 6 APIs enabled |
| `setup-infra.sh` | VPC `apigee-vpc`, subnet `compute-apigee` (10.0.0.0/24), VM `vm-test`, Cloud Run `cr-hello`, Artifact Registry |
| `setup-psc.sh` | Global PSC endpoint `pscgoogleapis` (10.0.0.100) targeting `all-apis` bundle, private DNS zone `run-app-psc` with `*.run.app → 10.0.0.100` |
| `test.sh` | DNS resolution + HTTP connectivity verification from VM via IAP |
| `teardown.sh` | Reverse-order cleanup of all resources |

Run in order:

```bash
./setup-iam.sh
gcloud config set auth/impersonate_service_account apigee-psc-poc@PROJECT_ID.iam.gserviceaccount.com
./setup-infra.sh
./setup-psc.sh
./test.sh
# when done:
./teardown.sh
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

> **Note**: Option C and Option C Scaled share networking resource names (`apigee-vpc`, `pscgoogleapis`, `run-app-psc`). Run `./teardown.sh` for one before setting up the other.

Run `./teardown.sh` when done to avoid ongoing costs.
