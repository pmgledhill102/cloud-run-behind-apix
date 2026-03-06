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
| `setup-iam.sh` | SA `apigee-ilb-poc`, 9 IAM roles, 6 APIs enabled |
| `setup-infra.sh` | VPCs (`apigee-vpc`, `workloads-vpc`), subnets, firewall rules, Cloud Run `cr-hello`, NAT, VM `vm-test` |
| `setup-vpn.sh` | HA VPN gateways, 4 tunnels (IKEv2), Cloud Routers with BGP (ASN 64512/64513) |
| `setup-ilb.sh` | Reserved IP `10.100.0.10`, Serverless NEG, backend service, URL map, self-signed cert, target HTTPS proxy, forwarding rule, DNS zone `api-internal-zone` |
| `test.sh` | BGP route verification, DNS resolution, HTTPS connectivity through VPN to ILB to Cloud Run |
| `teardown.sh` | Reverse-order cleanup of all resources |

Run in order:

```bash
./setup-iam.sh
gcloud config set auth/impersonate_service_account apigee-ilb-poc@PROJECT_ID.iam.gserviceaccount.com
./setup-infra.sh
./setup-vpn.sh
./setup-ilb.sh
./test.sh
# when done:
./teardown.sh
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

Run `./teardown.sh` when done to avoid ongoing costs.
