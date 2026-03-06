# Option B: Private Google Access (PGA)

Proof-of-concept scripts for connecting Apigee X to Cloud Run via Private Google Access. Traffic flows to Google's restricted VIP range, bypassing VPN tunnels entirely.

> These scripts simulate the **Apigee VPC** (VPC Peering provisioning model). The VM acts as a stand-in for Apigee, validating the same network path Apigee would use when peered into this VPC. See [Provisioning Decision](../../docs/apigee-provisioning-decision.md).

```
VM (10.0.0.x) [simulates Apigee in peered VPC]
  → DNS resolves *.run.app to 199.36.153.4-7 (restricted VIP)
    → Private Google Access
      → Google API frontend
        → Cloud Run service
```

## Scripts

| Script | Resources |
|---|---|
| `setup-iam.sh` | SA `apigee-pga-poc`, 8 IAM roles, 6 APIs enabled |
| `setup-infra.sh` | VPC `apigee-vpc`, subnet `compute-apigee` (10.0.0.0/24), VM `vm-test`, Cloud Run `cr-hello`, Artifact Registry |
| `setup-dns.sh` | Private DNS zone `run-app-pga` with `*.run.app → 199.36.153.4-7` (restricted VIP) and apex `run.app → 199.36.153.4-7` |
| `test.sh` | DNS resolution + HTTP connectivity verification from VM via IAP |
| `teardown.sh` | Reverse-order cleanup of all resources |

## Run instructions

```bash
./setup-iam.sh
gcloud config set auth/impersonate_service_account apigee-pga-poc@PROJECT_ID.iam.gserviceaccount.com
./setup-infra.sh
./setup-dns.sh
./test.sh
# when done:
./teardown.sh
```

## Cost while running

| Component | $/hr | $/day | Notes |
|---|---|---|---|
| Cloud DNS private zone | ~$0.0003 | ~$0.007 | ~$0.20/month |
| VM `e2-micro` | $0.00 | $0.00 | Free tier eligible |
| Cloud Run `cr-hello` | $0.00 | $0.00 | Scale to zero, no minimum instances |
| Artifact Registry | ~$0.00 | ~$0.00 | Pennies for one small image |
| **Total** | **~$0.00** | **~$0.01** | Cheapest option — leave running indefinitely |

No PSC forwarding rule, no VPN tunnels, no load balancers. This is the cheapest option.

Run `./teardown.sh` when done to avoid ongoing costs.
