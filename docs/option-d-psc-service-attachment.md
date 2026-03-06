# Option D: PSC Published Service / Service Attachment

## 1. Overview

PSC Service Attachments allow you to **publish a service** (fronted by an Internal Load Balancer) in one VPC and **consume it from another VPC** via a PSC endpoint -- without VPC peering or VPN. The producer (Workloads VPC) creates an ILB plus a Service Attachment, and the consumer (Apigee VPC or Apigee itself) creates a PSC endpoint. Traffic flows through a PSC tunnel that Google manages entirely within its network fabric.

This pattern is best when:

- You need the **strongest cross-project or cross-org isolation** with approval-based access control.
- You want to **completely avoid VPN tunnels** between the Apigee VPC and the Workloads VPC.
- You need **full Layer-7 traffic control** (path-based routing, custom domains, TLS termination) that options B and C cannot provide.
- You want **producer-controlled accept/reject lists** governing which consumer projects can connect.

**Key trade-off**: This is the most complex option to set up and the most complex to scale, but it provides the strongest network isolation boundary of all four options.

> **Provisioning assumption:** This document assumes the **VPC Peering** provisioning model. For the PSC non-peering alternative, see [Section 4](#4-how-it-works-psc-non-peering-model).

---

## 2. Architecture Diagram

![Option D Architecture](diagrams/option-d-architecture.drawio.svg)

---

## 3. How It Works: VPC Peering Model

In the **VPC Peering** provisioning model, Apigee peers to a customer-managed "Apigee VPC." The PSC Service Attachment bridges the Apigee VPC and the Workloads VPC without requiring VPN tunnels between them.

### Producer Side (Workloads VPC)

1. An **Internal Application Load Balancer** (regional) is deployed with:
   - A **serverless NEG** backend pointing to each Cloud Run service.
   - A **URL map** for path-based routing across multiple Cloud Run services.
   - A **target HTTPS proxy** terminating TLS with a Google-managed or self-managed certificate.
   - A **forwarding rule** with a reserved internal IP (e.g., `10.100.0.10`).
2. A **PSC NAT subnet** (purpose: `PRIVATE_SERVICE_CONNECT`) is created -- this subnet provides source IPs for PSC traffic entering the producer VPC.
3. A **PSC Service Attachment** is created, pointing to the ILB forwarding rule, using the PSC NAT subnet.

### Consumer Side (Apigee VPC)

1. A **reserved internal IP** (e.g., `10.0.0.50`) is allocated in the Apigee VPC.
2. A **PSC endpoint** (forwarding rule with `--target-service-attachment`) is created, connecting to the Service Attachment in the Workloads VPC.
3. A **private DNS zone** maps the custom domain (e.g., `api.internal.example.com`) to the PSC endpoint IP.

### Traffic Path

```
Apigee proxy
  --> Apigee VPC (peered)
    --> PSC endpoint (10.0.0.50)
      --> PSC tunnel (Google-managed)
        --> Service Attachment (Workloads VPC)
          --> ILB frontend (10.100.0.10)
            --> Serverless NEG
              --> Cloud Run service
```

**No VPN tunnels are needed.** The PSC tunnel replaces the HA VPN that Option A requires.

---

## 4. How It Works: PSC (Non-Peering) Model

> This section covers the PSC non-peering alternative. This repository assumes VPC Peering provisioning -- see [Provisioning Decision](apigee-provisioning-decision.md).

In the **PSC (non-peering)** provisioning model, Apigee natively supports **PSC endpoint attachments** for southbound traffic. No intermediate customer VPC is required.

### Producer Side (Workloads VPC)

Identical to the VPC Peering model:

1. Internal Application Load Balancer with serverless NEG, URL map, target HTTPS proxy, and forwarding rule.
2. PSC NAT subnet.
3. PSC Service Attachment pointing to the ILB forwarding rule.

### Consumer Side (Apigee)

1. An **Apigee endpoint attachment** is configured, referencing the Service Attachment resource.
2. Apigee allocates a PSC endpoint internally -- no customer VPC is involved on the consumer side.
3. The Apigee proxy target server is configured with the endpoint attachment's hostname or IP.

### Traffic Path

```
Apigee proxy
  --> PSC endpoint attachment (Apigee-managed)
    --> PSC tunnel (Google-managed)
      --> Service Attachment (Workloads VPC)
        --> ILB frontend (10.100.0.10)
          --> Serverless NEG
            --> Cloud Run service
```

**No intermediate VPC needed.** Apigee connects directly to the Service Attachment via its native PSC support.

---

## 5. Traffic Flow Walkthrough

### VPC Peering Model -- Step by Step

| Step | Description | IP / Resource |
|------|-------------|---------------|
| 1 | Apigee proxy sends HTTPS request to target | `api.internal.example.com` |
| 2 | DNS resolves to PSC endpoint IP in Apigee VPC | `10.0.0.50` |
| 3 | Traffic enters the PSC tunnel from the consumer endpoint | PSC endpoint forwarding rule |
| 4 | Traffic arrives at the Service Attachment in the Workloads VPC | Source-NATed to PSC NAT subnet |
| 5 | Service Attachment forwards to ILB frontend | `10.100.0.10` |
| 6 | ILB evaluates the URL map and routes to the appropriate backend service | URL map path rule match |
| 7 | Backend service forwards via serverless NEG to Cloud Run | Cloud Run service URL |
| 8 | Cloud Run processes the request and returns a response | HTTP 200 |
| 9 | Response traverses back through the PSC tunnel to the PSC endpoint | `10.0.0.50` --> Apigee |

### PSC (Non-Peering) Model -- Step by Step

| Step | Description | IP / Resource |
|------|-------------|---------------|
| 1 | Apigee proxy sends HTTPS request to target | Endpoint attachment hostname |
| 2 | Apigee routes to its internal PSC endpoint attachment | Apigee-managed IP |
| 3 | Traffic enters the PSC tunnel | PSC endpoint attachment |
| 4 | Traffic arrives at the same Service Attachment in the Workloads VPC | Source-NATed to PSC NAT subnet |
| 5 | Service Attachment forwards to ILB frontend | `10.100.0.10` |
| 6 | ILB routes via URL map to the appropriate backend service | URL map path rule match |
| 7 | Serverless NEG forwards to Cloud Run | Cloud Run service URL |
| 8 | Response returns via the PSC tunnel to Apigee | Apigee-managed |

---

## 6. Components Required

### Producer Side (Workloads VPC)

| Component | Purpose |
|-----------|---------|
| **Internal Application Load Balancer** (regional) | L7 load balancing with path-based routing, TLS termination |
| **Serverless NEG** (one per Cloud Run service) | Backend that routes to a specific Cloud Run service |
| **URL map** | Path-based routing rules mapping paths to backend services |
| **Backend service** (one per serverless NEG) | Wraps each serverless NEG for the URL map |
| **Target HTTPS proxy** | Terminates TLS using a certificate |
| **Forwarding rule** | Binds the ILB to a reserved internal IP and port |
| **Proxy-only subnet** | Required by the regional internal ALB for Envoy proxies |
| **PSC NAT subnet** (purpose: `PRIVATE_SERVICE_CONNECT`) | Provides source IPs for traffic arriving through the Service Attachment |
| **PSC Service Attachment** | Publishes the ILB for consumption via PSC endpoints |

### Consumer Side

#### VPC Peering Model (Apigee VPC)

| Component | Purpose |
|-----------|---------|
| **Reserved internal IP** | Static IP in Apigee VPC for the PSC endpoint |
| **PSC endpoint** (forwarding rule) | Connects to the Service Attachment in the Workloads VPC |
| **Private DNS zone** | Maps custom domain to the PSC endpoint IP |
| **DNS A record** | `api.internal.example.com` --> PSC endpoint IP |

#### PSC (Non-Peering) Model (Apigee)

| Component | Purpose |
|-----------|---------|
| **Apigee endpoint attachment** | PSC connection from Apigee to the Service Attachment |
| **Apigee target server** | References the endpoint attachment for proxy routing |

---

## 7. DNS Configuration

### VPC Peering Model

Create a **private DNS zone** in the Apigee VPC (the consumer VPC that Apigee peers into):

```bash
# Create private DNS zone in Apigee VPC
gcloud dns managed-zones create apigee-internal \
  --dns-name="internal.example.com." \
  --visibility=private \
  --networks=apigee-vpc \
  --description="DNS zone for PSC endpoints consumed by Apigee"
```

```bash
# Add A record pointing to PSC endpoint IP
gcloud dns record-sets create api.internal.example.com. \
  --zone=apigee-internal \
  --type=A \
  --ttl=300 \
  --rrdatas=10.0.0.50
```

The Apigee proxy target server references `api.internal.example.com`. Because Apigee peers into this VPC, it resolves the private DNS zone and reaches the PSC endpoint.

### PSC (Non-Peering) Model

No manual DNS configuration is needed. Apigee resolves the endpoint attachment via its internal DNS to the PSC endpoint attachment IP. The Apigee proxy target server is configured with the endpoint attachment directly.

### What About the Workloads VPC?

**No DNS is needed in the Workloads VPC.** The ILB is accessed via the PSC Service Attachment, not via DNS resolution. Traffic arrives at the ILB through the PSC tunnel and is forwarded based on the URL map, not hostname lookup.

---

## 8. Firewall Rules

### Producer Side (Workloads VPC)

```bash
# Allow health checks from Google health-check ranges to backends
gcloud compute firewall-rules create allow-health-checks \
  --network=workloads-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=ilb-backend \
  --description="Allow Google health check probes to ILB backends"
```

```bash
# Allow proxy-only subnet to reach backends (required for regional internal ALB)
gcloud compute firewall-rules create allow-proxy-only-subnet \
  --network=workloads-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges=10.100.1.0/24 \
  --target-tags=ilb-backend \
  --description="Allow proxy-only subnet traffic to backends"
```

```bash
# Allow PSC NAT subnet to reach ILB frontend
# PSC traffic arrives source-NATed from the PSC NAT subnet
gcloud compute firewall-rules create allow-psc-nat-to-ilb \
  --network=workloads-vpc \
  --direction=INGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --source-ranges=10.100.2.0/24 \
  --description="Allow PSC NAT subnet traffic to ILB"
```

> **Note:** Replace `10.100.1.0/24` with your proxy-only subnet range and `10.100.2.0/24` with your PSC NAT subnet range.

### Consumer Side (Apigee VPC)

```bash
# Allow egress from Apigee VPC to PSC endpoint IP
gcloud compute firewall-rules create allow-egress-to-psc \
  --network=apigee-vpc \
  --direction=EGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --destination-ranges=10.0.0.50/32 \
  --description="Allow egress to PSC endpoint for Service Attachment"
```

### Service Attachment Access Control

The PSC Service Attachment has its own **accept/reject list** that controls which consumer projects can connect. This is independent of firewall rules and provides a strong access control boundary:

```bash
# Create Service Attachment with explicit accept list
gcloud compute service-attachments create my-service-attachment \
  --region=us-central1 \
  --producer-forwarding-rule=my-ilb-forwarding-rule \
  --connection-preference=ACCEPT_MANUAL \
  --consumer-accept-list=consumer-project-id=10 \
  --nat-subnets=psc-nat-subnet \
  --description="PSC Service Attachment for Apigee to Cloud Run"
```

The `--consumer-accept-list` specifies which projects can connect and the connection limit per project. Projects not on the list are rejected.

---

## 9. Cost Estimate

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| Internal ALB forwarding rule | ~$18.26 | 1 forwarding rule minimum |
| ILB data processing | ~$0.008/GB | Per GB processed through the ILB |
| PSC Service Attachment | $0 | No additional charge for the attachment itself |
| PSC endpoint forwarding rule (consumer) | ~$18.26 | 1 forwarding rule in consumer VPC |
| Private DNS managed zone | ~$0.20 | Per zone per month |
| DNS queries | ~$0.40/million | Negligible at low query volumes |
| VPN tunnels | **Not needed** | PSC replaces the VPN path |
| **Total (per service group)** | **~$36/mo** | Before data processing charges |

### At Scale

- A single ILB URL map can route to many Cloud Run services, so one ILB + one Service Attachment can serve an entire service group.
- If you need multiple ILBs (e.g., per domain or per team), each requires its own Service Attachment and PSC endpoint, adding ~$36/mo per group.
- Compared to Option A (~$18/mo + VPN costs), Option D trades VPN costs for the additional PSC endpoint forwarding rule cost.

---

## 10. Scaling Characteristics

| Dimension | Behavior |
|-----------|----------|
| **Services per ILB** | One URL map can route to up to **2,000 path rules**, each pointing to a different Cloud Run service via a serverless NEG |
| **Service Attachments per ILB** | **One** Service Attachment per ILB forwarding rule |
| **PSC endpoints per consumer VPC** | Default quota: **10 per VPC** (can be increased via quota request) |
| **Consumer projects per Service Attachment** | Up to **10** consumer projects per Service Attachment (configurable) |
| **Regional scope** | ILB + Service Attachment are **regional** -- replicate per region for multi-region deployments |

### Scaling to 1000+ Cloud Run Services

1. **Group services by domain or path prefix** into logical ILB URL maps. For example:
   - `api.internal.example.com/payments/*` --> ILB-1
   - `api.internal.example.com/orders/*` --> ILB-1
   - `data.internal.example.com/*` --> ILB-2
2. Each ILB gets **one Service Attachment**.
3. Each Service Attachment gets **one PSC endpoint** in the consumer VPC.
4. With 2,000 path rules per URL map, you need roughly **1 ILB per 2,000 services**.
5. At 10,000 services: ~5 ILBs, ~5 Service Attachments, ~5 PSC endpoints.

### Comparison to Other Options

This is the **most complex scaling model** of the four options:

- Options B and C require **no per-service infrastructure** -- they scale to thousands of Cloud Run services with a single DNS zone.
- Option A requires ILBs but no Service Attachments.
- Option D requires ILBs **plus** Service Attachments **plus** PSC endpoints.

The trade-off is the **strongest isolation boundary**: each Service Attachment has explicit accept/reject lists, and no VPC peering or VPN is needed between the consumer and producer.

---

## 11. Testing Requirements

### What to Deploy

Deploy the following components for a minimal end-to-end test (core networking only, no VPC-SC):

**Producer side (Workloads VPC):**

- A Cloud Run service (e.g., a simple hello-world container)
- A serverless NEG pointing to the Cloud Run service
- An Internal Application Load Balancer (URL map, backend service, target HTTPS proxy, forwarding rule)
- A proxy-only subnet
- A PSC NAT subnet (purpose: `PRIVATE_SERVICE_CONNECT`)
- A PSC Service Attachment pointing to the ILB forwarding rule

**Consumer side:**

- *VPC Peering model*: A PSC endpoint (forwarding rule) in the Apigee VPC, a reserved internal IP, a private DNS zone with an A record
- *PSC non-peering model*: An Apigee endpoint attachment referencing the Service Attachment

### What to Validate

| Validation | Expected Result |
|------------|-----------------|
| Apigee proxy request reaches Cloud Run via PSC | HTTP 200 with Cloud Run response body |
| Service Attachment connection status | `ACCEPTED` |
| PSC endpoint status | `ACTIVE` |
| Path-based routing through ILB | Different paths route to different Cloud Run services |
| Accept/reject list enforcement | Requests from unlisted projects are rejected |

### Test Commands

```bash
# Verify Service Attachment status and connections
gcloud compute service-attachments describe my-service-attachment \
  --region=us-central1 \
  --format="yaml(name, connectionPreference, connectedEndpoints)"
```

```bash
# Verify PSC endpoint (forwarding rule) status
gcloud compute forwarding-rules describe my-psc-endpoint \
  --region=us-central1 \
  --format="yaml(name, target, IPAddress, pscConnectionStatus)"
```

```bash
# Test connectivity from a VM in the consumer VPC (VPC Peering model)
# Deploy a test VM in the Apigee VPC to validate the PSC path
curl -v https://api.internal.example.com/hello \
  --resolve api.internal.example.com:443:10.0.0.50
```

```bash
# Verify ILB backend health
gcloud compute backend-services get-health my-backend-service \
  --region=us-central1
```

```bash
# List all PSC endpoints in a project
gcloud compute forwarding-rules list \
  --filter="target~serviceAttachments" \
  --format="table(name, IPAddress, target, pscConnectionStatus)"
```

```bash
# For PSC non-peering model: verify Apigee endpoint attachment
gcloud apigee endpoint-attachments describe my-endpoint-attachment \
  --organization=my-org \
  --location=us-central1
```

### Troubleshooting

If the PSC endpoint shows status `PENDING` instead of `ACTIVE`:

1. Verify the Service Attachment's `--consumer-accept-list` includes the consumer project.
2. Verify the PSC NAT subnet has available IPs.
3. Check that the Service Attachment's `--connection-preference` is set correctly.

If requests fail after the PSC connection is established:

1. Verify firewall rules allow traffic from the PSC NAT subnet to the ILB.
2. Verify the ILB health checks are passing.
3. Verify the URL map routes match the request path.
4. Check Cloud Run service logs for incoming requests.

### PoC Scripts

Runnable scripts for this option: [`scripts/option4/`](../scripts/option4/)
