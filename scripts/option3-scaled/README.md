# Option C Scaled: PSC Endpoint for Google APIs (20 Services)

Proof-of-concept that demonstrates Option C's linear scaling: 20 Cloud Run services accessible through a single PSC endpoint with zero additional networking infrastructure.

> These scripts simulate the **Apigee VPC** (VPC Peering provisioning model). The VM acts as a stand-in for Apigee. See [Provisioning Decision](../../docs/apigee-provisioning-decision.md).

```
VM (10.0.0.x) [simulates Apigee in peered VPC]
  → DNS resolves *.run.app to 10.0.0.100 (PSC endpoint)
    → PSC forwarding rule
      → Google backbone
        → cr-svc-01, cr-svc-02, ... cr-svc-20
```

## Key finding

The PSC endpoint and DNS zone are identical to the single-service Option C. Only Cloud Run deployments change. Zero networking infrastructure changes needed.

## Scripts

| Script | Resources |
|---|---|
| `setup-iam.sh` | SA `apigee-psc-scaled-poc`, 8 IAM roles, 6 APIs enabled |
| `setup-infra.sh` | VPC `apigee-vpc`, subnet `compute-apigee` (10.0.0.0/24), VM `vm-test`, 20 Cloud Run services (`cr-svc-01`..`cr-svc-20`), Artifact Registry |
| `setup-psc.sh` | Global PSC endpoint `pscgoogleapis` (10.0.0.100) targeting `all-apis` bundle, private DNS zone `run-app-psc` with `*.run.app → 10.0.0.100` |
| `test.sh` | DNS resolution + HTTP connectivity verification for all 20 services from VM via IAP |
| `teardown.sh` | Reverse-order cleanup of all resources |

Run in order:

```bash
./setup-iam.sh
gcloud config set auth/impersonate_service_account apigee-psc-scaled-poc@PROJECT_ID.iam.gserviceaccount.com
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
| Cloud Run (20 services) | $0.00 | $0.00 | Scale to zero, no minimum instances |
| Artifact Registry | ~$0.00 | ~$0.00 | Pennies for one small image |
| **Total** | **~$0.03** | **~$0.61** | Same as single-service Option C |

No VPN tunnels or load balancers — cost is identical regardless of service count. Cloud Run services scale to zero.

> **Note**: Option C and Option C Scaled share networking resource names (`apigee-vpc`, `pscgoogleapis`, `run-app-psc`). Run `./teardown.sh` for one before setting up the other.

Run `./teardown.sh` when done to avoid ongoing costs.
