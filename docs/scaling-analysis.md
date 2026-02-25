# Scaling Analysis

How each connectivity option behaves as the number of Cloud Run services grows from tens to thousands.

## Scale Tiers

| Tier | Services | Typical use case |
|---|---|---|
| Small | 1–10 | Single team, MVP |
| Medium | 10–100 | Multiple teams, departmental |
| Large | 100–1,000 | Enterprise platform |
| Very large | 1,000+ | Organization-wide API platform |

## Option A: ILB + Serverless NEG via VPN

### How it scales

Each Cloud Run service requires a serverless NEG. Multiple NEGs can share a single ILB via the URL map (path rules or host rules).

| Scale tier | ILBs needed | Configuration |
|---|---|---|
| Small (1–10) | 1 | Single URL map with path rules |
| Medium (10–100) | 1–2 | Host-based routing, one ILB per domain group |
| Large (100–1,000) | 5–10 | Multiple ILBs, grouped by domain or team |
| Very large (1,000+) | 10+ | ILBs per region per service group |

### Limits

| Resource | Default quota | Notes |
|---|---|---|
| URL map path rules | 2,000 per map | Can request increase |
| URL map host rules | 10,000 per map | Rarely the bottleneck |
| Backend services per project | 500 | Can request increase to 5,000+ |
| Serverless NEGs per project | 500 | Can request increase |
| Forwarding rules per project | 500 | Each ILB uses one |
| VPN tunnels | 8 per HA VPN pair | Fixed; add more gateway pairs |

### Scaling bottleneck

The primary bottleneck is management overhead, not hard limits. Each new Cloud Run service requires:
1. Create serverless NEG
2. Create backend service
3. Add URL map path/host rule
4. Update ILB configuration

At 1,000+ services, this becomes a significant Terraform/IaC maintenance burden.

### VPN bandwidth

HA VPN provides up to 3 Gbps per tunnel (4 tunnels = 12 Gbps per gateway pair). At very large scale, VPN bandwidth may become a concern. Monitor tunnel utilization.

---

## Option B: Private Google Access

### How it scales

No per-service infrastructure. Each Cloud Run service has a unique `*.run.app` URL. PGA routes all Google API traffic to the restricted/private VIP.

| Scale tier | Infrastructure changes | Configuration |
|---|---|---|
| Small (1–10) | None | Deploy Cloud Run, update Apigee proxy |
| Medium (10–100) | None | Deploy Cloud Run, update Apigee proxy |
| Large (100–1,000) | None | Deploy Cloud Run, update Apigee proxy |
| Very large (1,000+) | None | Deploy Cloud Run, update Apigee proxy |

### Limits

| Resource | Limit | Notes |
|---|---|---|
| DNS zones | 10,000 per project | Only need 1–2 zones total |
| PGA bandwidth | Google backbone | No practical limit |
| Cloud Run services per project | 5,000 | Can request increase |

### Scaling bottleneck

None for the connectivity layer. The bottleneck shifts to:
- Cloud Run service deployment and management
- Apigee proxy configuration (one proxy or target per Cloud Run service)
- IAM management (invoker permissions per service)

### Why it scales best

Zero per-service networking infrastructure. The DNS zone (`*.run.app → restricted VIP`) is a wildcard — it works for all Cloud Run services automatically.

---

## Option C: PSC Endpoint for Google APIs

### How it scales

Similar to PGA — a single PSC endpoint serves all Google APIs, including all Cloud Run services. No per-service infrastructure.

| Scale tier | Infrastructure changes | Configuration |
|---|---|---|
| Small (1–10) | None | Deploy Cloud Run, update Apigee proxy |
| Medium (10–100) | None | Deploy Cloud Run, update Apigee proxy |
| Large (100–1,000) | None | Deploy Cloud Run, update Apigee proxy |
| Very large (1,000+) | None | Deploy Cloud Run, update Apigee proxy |

### Limits

| Resource | Limit | Notes |
|---|---|---|
| PSC endpoints per VPC | 10 (default) | Can request increase; but only need 1 for Google APIs |
| Concurrent connections per endpoint | 65,536 | Per endpoint; increase by adding endpoints |
| Bandwidth per endpoint | 50 Gbps | Well beyond typical API traffic |
| DNS zones | 10,000 per project | Only need 1–2 zones total |

### Scaling bottleneck

Concurrent connections is the first limit to watch at very large scale. If a single PSC endpoint's 65K connection limit is approached, create additional PSC endpoints and distribute traffic via DNS.

### Comparison with Option B

Functionally identical scaling characteristics to PGA. The difference is operational: PSC provides an explicit internal IP for firewall rules and audit logging.

---

## Option D: PSC Service Attachment

### How it scales

The most infrastructure-intensive option at scale. Each service group needs an ILB + Service Attachment on the producer side, and a PSC endpoint on the consumer side.

| Scale tier | ILBs / SAs needed | PSC endpoints needed | Configuration |
|---|---|---|---|
| Small (1–10) | 1 | 1 | Single ILB URL map |
| Medium (10–100) | 2–5 | 2–5 | Group by domain |
| Large (100–1,000) | 10–20 | 10–20 | Group by team/domain |
| Very large (1,000+) | 20+ | 20+ | Complex grouping strategy |

### Limits

| Resource | Default quota | Notes |
|---|---|---|
| Service Attachments per project | 500 | Can request increase |
| PSC endpoints per VPC | 10 (default) | Must request increase for scale |
| PSC consumer connections per SA | 10 per list | Accept list limit |
| URL map path rules | 2,000 per map | Per ILB |
| Backend services per project | 500 | Can request increase |
| Forwarding rules per project | 500 | Each ILB + each PSC endpoint uses one |

### Scaling bottleneck

Multiple bottlenecks compound:
1. **PSC endpoint quota**: Default 10 per VPC, must request increase early
2. **Forwarding rules**: Each ILB (producer) and each PSC endpoint (consumer) consumes one
3. **Management overhead**: Each service group requires producer + consumer configuration
4. **Cost**: ~$36/mo per ILB+SA group (most expensive option at scale)

### Grouping strategy

At scale, minimize the number of ILB/SA pairs by grouping services:

```
ILB-1 (team-a.internal.example.com)
  ├── /service-1 → Cloud Run A
  ├── /service-2 → Cloud Run B
  └── /service-3 → Cloud Run C

ILB-2 (team-b.internal.example.com)
  ├── /service-4 → Cloud Run D
  └── /service-5 → Cloud Run E
```

Each ILB gets one Service Attachment and one PSC endpoint. Target: fewer than 50 ILB/SA pairs for 1,000 services.

---

## Recommendation by Scale Tier

| Scale | Recommended option | Why |
|---|---|---|
| **Small (1–10)** | Option B (PGA) or A (ILB) | PGA for simplicity, ILB if you need traffic control |
| **Medium (10–100)** | Option B (PGA) or C (PSC APIs) | No per-service infra; PSC if you need audit/firewall control |
| **Large (100–1,000)** | Option C (PSC APIs) | Enterprise-grade, no scaling concern, explicit IP for governance |
| **Very large (1,000+)** | Option B or C | Only options that don't require per-service infrastructure |

### When Option A or D makes sense at scale

- **Option A at scale**: When every service needs custom domain, path-based routing, or Cloud Armor. Accept the ILB management overhead as a trade-off for traffic control.
- **Option D at scale**: When services span multiple GCP organizations or projects with strict isolation requirements. The PSC approval model justifies the complexity.

## Cost at Scale

Monthly base infrastructure costs (excluding Cloud Run and data processing):

| Services | Option A | Option B | Option C | Option D |
|---|---|---|---|---|
| 10 | ~$91 | ~$0.20 | ~$18 | ~$36 |
| 100 | ~$163 (2 ILBs + VPN) | ~$0.20 | ~$18 | ~$180 (5 groups) |
| 1,000 | ~$253 (10 ILBs + VPN) | ~$0.20 | ~$18 | ~$720 (20 groups) |
| 5,000 | ~$523 (20 ILBs + VPN) | ~$0.20 | ~$18 | ~$1,800 (50 groups) |

Note: Option A includes VPN tunnel costs (~$73/mo). Options B, C, and D do not require VPN for the Cloud Run traffic path.
