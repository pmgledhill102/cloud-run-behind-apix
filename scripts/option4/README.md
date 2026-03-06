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
| `setup-iam.sh` | SA `apigee-psc-sa-poc`, 9 IAM roles, 6 APIs enabled |
| `setup-infra.sh` | VPCs `apigee-vpc` + `workloads-vpc`, subnets `compute-apigee` (10.0.0.0/24) + `compute-workloads` (10.100.0.0/24) + `proxy-only-workloads` (10.100.64.0/24) + `psc-nat-workloads` (10.100.2.0/24), 5 firewall rules, VM `vm-test`, Cloud Run `cr-hello`, Artifact Registry |
| `setup-psc.sh` | ILB stack (NEG, backend service, URL map, SSL cert, target proxy, forwarding rule), Service Attachment `sa-workloads`, PSC endpoint `psc-endpoint-apigee` (10.0.0.50), DNS zone `api-internal-zone` with `api.internal.example.com -> 10.0.0.50` |
| `test.sh` | Service Attachment status, PSC connection status, DNS resolution + HTTP connectivity verification from VM via IAP |
| `teardown.sh` | Reverse-order cleanup of all resources |

Run in order:

```bash
./setup-iam.sh
gcloud config set auth/impersonate_service_account apigee-psc-sa-poc@PROJECT_ID.iam.gserviceaccount.com
./setup-infra.sh
./setup-psc.sh
./test.sh
# when done:
./teardown.sh
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

Run `./teardown.sh` when done to avoid ongoing costs.
