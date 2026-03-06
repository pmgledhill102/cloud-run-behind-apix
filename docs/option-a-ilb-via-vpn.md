# Option A: Internal ALB + Serverless NEG (Traffic via VPN)

## 1. Overview

This option places a regional **Internal Application Load Balancer** (ILB) with a **Serverless NEG** in the Workloads VPC. The Apigee X proxy targets the ILB's internal IP address, and traffic traverses HA VPN tunnels between the Apigee VPC and the Workloads VPC to reach Cloud Run services.

> **Provisioning assumption:** This document assumes the **VPC Peering** provisioning model, which matches the organisation's existing Apigee X deployment. The PSC (non-peering) alternative is covered in Section 4 for reference.

**Choose this option when you need full traffic control:**

- Path-based and host-based routing across multiple Cloud Run services behind a single IP
- TLS termination at the load balancer with custom certificates
- Custom internal domains (e.g., `api.internal.example.com`) instead of `*.run.app` URLs
- Cloud Armor security policies on internal traffic
- Centralized logging and monitoring at the load balancer layer

**Trade-off:** Traffic flows through VPN tunnels, which adds a network hop, a VPN cost component, and a dependency on tunnel availability. If you do not need load balancer features, consider Option B (PGA) or Option C (PSC for Google APIs) which bypass VPN entirely.

---

## 2. Architecture Diagram

![Option A Architecture](diagrams/option-a-architecture.drawio.svg)

---

## 3. How It Works: VPC Peering Model

In the VPC Peering provisioning model, Apigee X peers its managed VPC to a customer-owned **Apigee VPC**. That Apigee VPC connects to the **Workloads VPC** via HA VPN tunnels. The ILB lives in the Workloads VPC.

```
Apigee X (managed)
  │
  ├── VPC peering ──► Apigee VPC (customer-owned)
  │                      │
  │                      ├── Cloud Router ◄──BGP──► Cloud Router
  │                      │       (Apigee VPC)           (Workloads VPC)
  │                      │                                   │
  │                      └── HA VPN tunnels ────────────────►│
  │                                                          │
  │                                              Internal ALB (10.100.0.10)
  │                                                          │
  │                                              Serverless NEG
  │                                                          │
  │                                                   Cloud Run
```

**Key details:**

- Apigee uses the peered VPC for all southbound (target) calls. It resolves DNS within the peered network and routes traffic through it.
- The ILB frontend IP (e.g., `10.100.0.10`) must reside in a subnet within the Workloads VPC that is **advertised via BGP** to the Apigee VPC Cloud Router.
- Custom route advertisements on the Workloads VPC Cloud Router must include the ILB subnet range so that the Apigee VPC learns the route.
- The Apigee VPC must have a corresponding route (learned via BGP) pointing to the VPN tunnels for the ILB subnet.

---

## 4. How It Works: PSC (Non-Peering) Model

> This section covers the PSC non-peering alternative. This repository assumes VPC Peering provisioning -- see [Provisioning Decision](apigee-provisioning-decision.md).

In the PSC provisioning model, Apigee does **not** peer to any customer VPC. Instead, it uses **PSC endpoint attachments** for southbound traffic.

There are two sub-approaches:

### 4a. PSC Service Attachment Pointing to the ILB

The customer creates a **PSC service attachment** in the Workloads VPC that exposes the ILB. Apigee connects to this service attachment via a PSC endpoint attachment configured in the Apigee instance.

```
Apigee X (managed, non-peered)
  │
  ├── PSC endpoint attachment ──► PSC Service Attachment (Workloads VPC)
  │                                         │
  │                                  Internal ALB (10.100.0.10)
  │                                         │
  │                                  Serverless NEG
  │                                         │
  │                                     Cloud Run
```

- The PSC service attachment is backed by the ILB forwarding rule in the Workloads VPC.
- No VPN tunnels are needed in this sub-approach (traffic flows over PSC).
- The ILB IP must be reachable from the NAT subnet associated with the PSC service attachment.

### 4b. Bridge VPC with VPN Forwarding to the ILB

If the ILB must remain in the Workloads VPC and you cannot create a PSC service attachment directly for it, you can use a **bridge VPC**:

```
Apigee X (managed, non-peered)
  │
  ├── PSC endpoint attachment ──► PSC Service Attachment (Bridge VPC)
  │                                         │
  │                              Cloud Router ◄──BGP──► Cloud Router
  │                                  (Bridge VPC)        (Workloads VPC)
  │                                         │
  │                              HA VPN tunnels ────────► Internal ALB (10.100.0.10)
  │                                                              │
  │                                                       Serverless NEG
  │                                                              │
  │                                                          Cloud Run
```

- The bridge VPC terminates the PSC endpoint and forwards traffic via VPN to the Workloads VPC.
- The ILB IP must be reachable from the bridge VPC via BGP-advertised routes.

---

## 5. Traffic Flow Walkthrough

### VPC Peering Model — Step by Step

| Step | Hop | Address / Detail |
|------|-----|------------------|
| 1 | Apigee proxy sends request | Target: `https://api.internal.example.com/orders` |
| 2 | DNS resolution in Apigee VPC | `api.internal.example.com` resolves to `10.100.0.10` (private DNS zone) |
| 3 | Apigee VPC routing | Route for `10.100.0.0/24` points to HA VPN tunnel (learned via BGP) |
| 4 | HA VPN tunnel | Packet traverses IPsec tunnel from Apigee VPC Cloud Router to Workloads VPC Cloud Router |
| 5 | Workloads VPC Cloud Router | Delivers packet to the ILB frontend IP `10.100.0.10` |
| 6 | ILB processing | Envoy proxy (in proxy-only subnet, e.g., `10.100.64.0/24`) terminates TLS, evaluates URL map |
| 7 | URL map routing | `/orders` matches backend service `orders-backend` |
| 8 | Serverless NEG | Backend service forwards to Serverless NEG targeting Cloud Run service `orders-service` |
| 9 | Cloud Run | Request reaches `orders-service-xxxxxxxxxx-uc.a.run.app`, response returns along the same path |

### PSC (Non-Peering) Model — Step by Step

| Step | Hop | Address / Detail |
|------|-----|------------------|
| 1 | Apigee proxy sends request | Target: endpoint attachment hostname or IP |
| 2 | PSC endpoint attachment | Apigee routes southbound traffic to the PSC endpoint |
| 3 | PSC service attachment | Traffic arrives at the service attachment in the Workloads VPC (or bridge VPC) |
| 4 | ILB frontend | Service attachment delivers to ILB at `10.100.0.10` |
| 5 | ILB processing | Envoy proxy terminates TLS, evaluates URL map |
| 6 | URL map routing | Path rule selects the appropriate backend service |
| 7 | Serverless NEG | Backend service forwards to Serverless NEG targeting the Cloud Run service |
| 8 | Cloud Run | Request reaches the Cloud Run service, response returns via PSC |

---

## 6. Components Required

### Internal Application Load Balancer Stack

| Resource | Purpose |
|----------|---------|
| **Forwarding rule** | ILB frontend IP and port (e.g., `10.100.0.10:443`) |
| **Target HTTPS proxy** | Terminates TLS, references SSL certificate and URL map |
| **SSL certificate** | Self-signed or Google-managed certificate for the internal domain |
| **URL map** | Path-based and host-based routing rules to backend services |
| **Backend service** | References one or more Serverless NEGs; health checks optional for serverless backends |
| **Serverless NEG** | Points to a specific Cloud Run service (one NEG per service) |
| **Proxy-only subnet** | Regional subnet for Envoy proxy instances (purpose: `REGIONAL_MANAGED_PROXY`) |

### Networking (VPN Path)

| Resource | Purpose |
|----------|---------|
| **HA VPN gateway** (Apigee VPC) | VPN endpoint in the Apigee VPC |
| **HA VPN gateway** (Workloads VPC) | VPN endpoint in the Workloads VPC |
| **VPN tunnels** (x4 for HA) | Two tunnels per gateway interface for full redundancy |
| **Cloud Router** (Apigee VPC) | BGP peering; learns routes to Workloads VPC subnets |
| **Cloud Router** (Workloads VPC) | BGP peering; advertises ILB subnet to Apigee VPC |

### Networking (PSC Path — if using non-peering model)

| Resource | Purpose |
|----------|---------|
| **PSC service attachment** | Exposes the ILB to Apigee via PSC |
| **PSC NAT subnet** | Subnet used for address translation in the service attachment |
| **PSC endpoint attachment** (on Apigee) | Connects Apigee instance to the service attachment |

### DNS

| Resource | Purpose |
|----------|---------|
| **Private DNS zone** | Hosts A records mapping custom domain to ILB IP |

### Example `gcloud` Commands

**Create the Serverless NEG:**

```bash
gcloud compute network-endpoint-groups create orders-neg \
  --region=us-central1 \
  --network-endpoint-type=serverless \
  --cloud-run-service=orders-service
```

**Create the backend service:**

```bash
gcloud compute backend-services create orders-backend \
  --region=us-central1 \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --protocol=HTTPS

gcloud compute backend-services add-backend orders-backend \
  --region=us-central1 \
  --network-endpoint-group=orders-neg \
  --network-endpoint-group-region=us-central1
```

**Create the URL map:**

```bash
gcloud compute url-maps create internal-api-url-map \
  --region=us-central1 \
  --default-service=orders-backend
```

**Add a path rule (for multiple services):**

```bash
gcloud compute url-maps add-path-matcher internal-api-url-map \
  --region=us-central1 \
  --path-matcher-name=api-paths \
  --default-service=orders-backend \
  --path-rules="/orders/*=orders-backend,/inventory/*=inventory-backend"
```

**Create the SSL certificate (self-signed example):**

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout internal.key -out internal.crt \
  -subj "/CN=api.internal.example.com"

gcloud compute ssl-certificates create internal-api-cert \
  --region=us-central1 \
  --certificate=internal.crt \
  --private-key=internal.key
```

**Create the target HTTPS proxy:**

```bash
gcloud compute target-https-proxies create internal-api-proxy \
  --region=us-central1 \
  --url-map=internal-api-url-map \
  --ssl-certificates=internal-api-cert
```

**Create the forwarding rule (ILB frontend):**

```bash
gcloud compute forwarding-rules create internal-api-fwd-rule \
  --region=us-central1 \
  --load-balancing-scheme=INTERNAL_MANAGED \
  --network=workloads-vpc \
  --subnet=ilb-subnet \
  --address=10.100.0.10 \
  --ports=443 \
  --target-https-proxy=internal-api-proxy \
  --target-https-proxy-region=us-central1
```

**Create the proxy-only subnet:**

```bash
gcloud compute networks subnets create proxy-only-subnet \
  --region=us-central1 \
  --network=workloads-vpc \
  --range=10.100.64.0/24 \
  --purpose=REGIONAL_MANAGED_PROXY \
  --role=ACTIVE
```

---

## 7. DNS Configuration

Apigee must resolve the custom domain (e.g., `api.internal.example.com`) to the ILB's internal IP. The DNS zone must be visible to the VPC where Apigee performs DNS resolution.

### VPC Peering Model

Create a private DNS zone in the **Apigee VPC** (the peered VPC), since Apigee resolves DNS within that network:

```bash
gcloud dns managed-zones create internal-api-zone \
  --dns-name="internal.example.com." \
  --visibility=private \
  --networks=apigee-vpc \
  --description="Private zone for internal API endpoints"
```

Add an A record pointing to the ILB:

```bash
gcloud dns record-sets create api.internal.example.com. \
  --zone=internal-api-zone \
  --type=A \
  --ttl=300 \
  --rrdatas="10.100.0.10"
```

### PSC (Non-Peering) Model

For PSC with a bridge VPC, create the DNS zone in the **bridge VPC** (or whichever VPC terminates the PSC endpoint):

```bash
gcloud dns managed-zones create internal-api-zone \
  --dns-name="internal.example.com." \
  --visibility=private \
  --networks=bridge-vpc \
  --description="Private zone for internal API endpoints"
```

For PSC direct (no bridge), Apigee uses the endpoint attachment hostname. Custom DNS may not be needed if you reference the PSC endpoint IP directly in the Apigee target.

### Key Considerations

| Concern | Detail |
|---------|--------|
| **BGP route advertisement** | The ILB subnet (e.g., `10.100.0.0/24`) must be included in the Cloud Router's custom route advertisements so Apigee VPC learns the route. |
| **DNS propagation** | Private DNS zones are authoritative within their associated VPC networks. Ensure the correct VPC is associated. |
| **Multiple ILBs** | If you have ILBs in multiple regions, create separate A records or use geo-routing via Cloud DNS response policies. |
| **Response policies (alternative)** | Cloud DNS response policies can override resolution for specific names. Useful when you want per-VPC behavior without managing multiple zones. |

---

## 8. Firewall Rules

### Health Check Traffic

Google health check probes must reach the ILB backend. Although health checks are optional for Serverless NEGs (Cloud Run handles its own health), the firewall rule is still recommended in case you add non-serverless backends later.

```bash
gcloud compute firewall-rules create allow-health-check \
  --network=workloads-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges="130.211.0.0/22,35.191.0.0/16" \
  --target-tags=ilb-backend \
  --description="Allow Google health check probes to ILB backends"
```

### Proxy-Only Subnet to Backend

The Envoy proxies in the proxy-only subnet must reach the backend service port:

```bash
gcloud compute firewall-rules create allow-proxy-to-backend \
  --network=workloads-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges="10.100.64.0/24" \
  --target-tags=ilb-backend \
  --description="Allow proxy-only subnet to reach backends"
```

### VPN Source Ranges to ILB

Allow traffic from the Apigee VPC (via VPN) to reach the ILB frontend:

```bash
gcloud compute firewall-rules create allow-vpn-to-ilb \
  --network=workloads-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges="10.0.0.0/16" \
  --description="Allow Apigee VPC ranges (via VPN) to reach ILB frontend"
```

Replace `10.0.0.0/16` with the actual CIDR range of the Apigee VPC.

### Apigee NAT Ranges (VPC Peering Model)

When Apigee uses VPC peering, it sends traffic from its NAT IP range. This range is allocated during Apigee provisioning:

```bash
gcloud compute firewall-rules create allow-apigee-nat \
  --network=workloads-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges="10.1.0.0/20" \
  --description="Allow Apigee NAT range to reach ILB (peering model)"
```

Replace `10.1.0.0/20` with the actual Apigee NAT range from your Apigee instance configuration.

### Summary

| Rule | Source | Destination | Port | Required For |
|------|--------|-------------|------|--------------|
| Health check | `130.211.0.0/22`, `35.191.0.0/16` | ILB backend | 443 | Health probes |
| Proxy-only subnet | Proxy-only subnet CIDR | ILB backend | 443 | Envoy to backend |
| VPN ranges | Apigee VPC CIDR | ILB frontend IP | 443 | Apigee traffic via VPN |
| Apigee NAT | Apigee NAT range | ILB frontend IP | 443 | Apigee peering model |

---

## 9. Cost Estimate

All prices are approximate, based on us-central1 pricing as of 2025. Actual costs vary by region and usage.

### Infrastructure Costs

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| Internal ALB forwarding rule | ~$18.00 | First 5 forwarding rules; $18/mo each |
| ILB data processing | ~$0.008/GB | Per GB processed through the ILB |
| HA VPN tunnels (4 tunnels) | ~$73.00 | $0.05/hr per tunnel x 4 tunnels x 730 hrs |
| Cloud Router | Included | No separate charge |
| Serverless NEG | No charge | No additional cost beyond Cloud Run |
| Private DNS zone | ~$0.20 | Per managed zone per month |
| DNS queries | ~$0.40/million | Per million queries |
| **Total (base)** | **~$91/mo** | **Before data processing charges** |

### Alternative: PSC Non-Peering Path

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| Internal ALB forwarding rule | ~$18.00 | Same as above |
| ILB data processing | ~$0.008/GB | Per GB processed |
| PSC forwarding rule | ~$18.00 | For the PSC endpoint |
| PSC data processing | ~$0.01/GB | Per GB through PSC |
| Serverless NEG | No charge | No additional cost |
| Private DNS zone | ~$0.20 | Per managed zone |
| **Total (base)** | **~$36/mo** | **Before data processing charges** |

> **Note:** The PSC path avoids the ~$73/mo VPN tunnel cost but adds a PSC forwarding rule cost. For high-throughput workloads, compare per-GB data processing charges between VPN and PSC.

---

## 10. Scaling Characteristics

### URL Map Limits

| Limit | Value |
|-------|-------|
| Path rules per path matcher | 2,000 |
| Path matchers per URL map | 20 |
| Host rules per URL map | 10,000 |
| Total path rules per URL map | Up to 2,000 per path matcher x 20 matchers |

A single ILB with one URL map can route to many Cloud Run services using path-based or host-based rules.

### Serverless NEG

- **One Serverless NEG per Cloud Run service.** Each NEG points to exactly one Cloud Run service.
- NEGs are regional. You need separate NEGs for Cloud Run services in different regions.
- No limit on the number of Serverless NEGs you can create per project (subject to project quota).

### Scaling to 1000+ Services

| Scale | Approach |
|-------|----------|
| 1-100 services | Single ILB with path-based routing. One URL map, one or more path matchers. |
| 100-500 services | Single ILB with host-based routing. Group services by subdomain (e.g., `orders.api.internal.example.com`, `inventory.api.internal.example.com`). |
| 500-2000 services | Single ILB near URL map limits. Consider splitting by domain or functional area. |
| 2000+ services | Multiple ILBs, each handling a domain or service group. Multiple forwarding rules, each with its own IP and URL map. |

### Regional Considerations

- Internal ALBs are **regional**. If Cloud Run services span multiple regions, you need an ILB per region.
- Each region requires its own proxy-only subnet, forwarding rule, and URL map.
- VPN tunnels are also regional. Cross-region traffic adds latency and egress cost.

### Throughput

- The ILB itself has no fixed QPS ceiling. Throughput is bounded by:
  - **Proxy-only subnet capacity:** Envoy proxies scale automatically, but the subnet must have enough IPs. A `/24` provides 256 addresses, generally sufficient.
  - **VPN tunnel bandwidth:** Each HA VPN tunnel supports up to 3 Gbps. Four tunnels provide up to 12 Gbps aggregate (with ECMP).
  - **Cloud Run concurrency and instance limits:** Cloud Run autoscales independently.

---

## 11. Testing Requirements

Core networking validation only. No VPC-SC testing in scope.

### What to Deploy

| Component | Detail |
|-----------|--------|
| Cloud Run service | A simple test service (e.g., returns `{"status": "ok"}`) in the Workloads VPC project |
| Serverless NEG | Pointing to the test Cloud Run service |
| Internal ALB | Full stack: forwarding rule, target HTTPS proxy, SSL cert, URL map, backend service |
| Proxy-only subnet | In the Workloads VPC, same region as the ILB |
| HA VPN tunnels | Between Apigee VPC and Workloads VPC (if using VPN path) |
| Cloud Routers | With custom route advertisements including the ILB subnet |
| Private DNS zone | In the Apigee VPC (or bridge VPC) with an A record for the ILB IP |
| Firewall rules | All rules from Section 8 |

For PSC model: additionally deploy the PSC service attachment and configure the Apigee endpoint attachment.

### What to Validate

| Test | Expected Result |
|------|-----------------|
| DNS resolution from Apigee VPC | `api.internal.example.com` resolves to `10.100.0.10` |
| BGP route propagation | Apigee VPC Cloud Router shows learned route for ILB subnet |
| TLS handshake | Successful TLS connection to the ILB on port 443 |
| End-to-end via Apigee proxy | Apigee proxy targeting `https://api.internal.example.com/test` returns Cloud Run response |
| Path-based routing | Different paths route to different Cloud Run services |
| Latency through VPN | Measure round-trip time; typically adds 1-3 ms per VPN hop |
| Failover (HA VPN) | Disable one tunnel; traffic fails over to remaining tunnels |

### Test Commands

**Verify DNS resolution from a test VM in the Apigee VPC:**

```bash
gcloud compute ssh test-vm --zone=us-central1-a --project=apigee-project -- \
  "dig +short api.internal.example.com"
# Expected: 10.100.0.10
```

**Verify BGP routes on the Apigee VPC Cloud Router:**

```bash
gcloud compute routers get-status apigee-router \
  --region=us-central1 \
  --project=apigee-project \
  --format="table(result.bestRoutes[].destRange, result.bestRoutes[].nextHopVpnTunnel)"
# Expected: 10.100.0.0/24 route pointing to VPN tunnel
```

**Test TLS handshake from a VM in the Apigee VPC:**

```bash
gcloud compute ssh test-vm --zone=us-central1-a --project=apigee-project -- \
  "openssl s_client -connect 10.100.0.10:443 -servername api.internal.example.com </dev/null 2>/dev/null | head -5"
# Expected: Certificate chain and "Verify return code: 0 (ok)" or self-signed warning
```

**Curl the ILB from a test VM in the Apigee VPC:**

```bash
gcloud compute ssh test-vm --zone=us-central1-a --project=apigee-project -- \
  "curl -sk https://api.internal.example.com/test"
# Expected: {"status": "ok"} from the Cloud Run test service
```

**Test path-based routing (if multiple services configured):**

```bash
gcloud compute ssh test-vm --zone=us-central1-a --project=apigee-project -- \
  "curl -sk https://api.internal.example.com/orders && echo '---' && curl -sk https://api.internal.example.com/inventory"
# Expected: Different responses from orders-service and inventory-service
```

**Measure latency through VPN:**

```bash
gcloud compute ssh test-vm --zone=us-central1-a --project=apigee-project -- \
  "curl -sk -o /dev/null -w 'total: %{time_total}s\nconnect: %{time_connect}s\ntls: %{time_appconnect}s\n' https://api.internal.example.com/test"
# Expected: total time typically < 50ms for same-region
```

**Validate from Apigee (via API debug session):**

```bash
curl -X POST "https://apigee.googleapis.com/v1/organizations/${ORG}/environments/${ENV}/apis/${API_PROXY}/revisions/${REV}/debugsessions" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"timeout": "300"}'
```

Then send a request through the Apigee proxy and inspect the debug session for the target response, latency, and any connection errors.

### PoC Scripts

Runnable scripts for this option: [`scripts/option1/`](../scripts/option1/)
