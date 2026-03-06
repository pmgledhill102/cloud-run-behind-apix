# Option B: Private Google Access (PGA)

## 1. Overview

Private Google Access (PGA) allows VMs and other resources without external IP addresses to reach Google APIs and services -- including Cloud Run's `*.run.app` URLs -- over Google's internal network. When Apigee sends a request to a Cloud Run service's `run.app` URL, PGA routes that traffic directly from the VPC where it is enabled onto Google's backbone. **Traffic never traverses the HA VPN tunnels** connecting the Apigee VPC to the Workloads VPC.

This is the simplest and cheapest connectivity option. There is no per-service infrastructure to deploy: no load balancers, no NEGs, no PSC service attachments. You enable PGA on a subnet, configure a private DNS zone, and point Apigee at the `*.run.app` URL.

> **Provisioning model:** This document assumes **VPC Peering** provisioning for Apigee. The PSC (non-peering) alternative is covered in [Section 4](#4-how-it-works-psc-non-peering-model).

**Best when:** you want the simplest, cheapest option with no per-service infrastructure, you do not need custom domains or advanced traffic management (path-based routing, Cloud Armor), and you are comfortable using the default `*.run.app` URLs that Cloud Run assigns.

---

## 2. Architecture Diagram

![Option B Architecture](diagrams/option-b-architecture.drawio.svg)

---

## 3. How It Works: VPC Peering Model

In the VPC Peering provisioning model, Apigee's runtime is peered to a customer-managed **Apigee VPC**. That Apigee VPC is in turn connected to the **Workloads VPC** via HA VPN tunnels.

For PGA to work in this model:

1. **PGA must be enabled on the subnet in the Apigee VPC** -- specifically the subnet that Apigee's peered network resolves from and originates traffic on.
2. **A private DNS zone** must be configured in the Apigee VPC to map `*.run.app` to the restricted or private Google VIP (see [Section 7: DNS Configuration](#7-dns-configuration)).
3. Apigee's runtime resolves the Cloud Run URL (e.g., `myservice-xyz-uc.a.run.app`) via the private DNS zone, which returns the restricted/private VIP address.
4. PGA intercepts the outbound traffic destined for that VIP and routes it directly onto Google's internal backbone.

**Traffic path:**

```
Apigee proxy --> PGA (Apigee VPC subnet) --> Google backbone --> Cloud Run
```

The HA VPN tunnels between the Apigee VPC and Workloads VPC are **not used** for this traffic. PGA routes directly to Google from the VPC where it is enabled.

---

## 4. How It Works: PSC (Non-Peering) Model

> **Note:** This section covers the PSC non-peering alternative. This repository assumes VPC Peering provisioning -- see [Provisioning Decision](apigee-provisioning-decision.md).

In the PSC (non-peering) provisioning model, Apigee uses **PSC endpoint attachments** for southbound traffic rather than VPC peering. There is no direct peering between Apigee's infrastructure and the customer VPC.

For PGA in this model, there are two possible configurations:

### Option 1: PGA on the customer VPC (via PSC hop)

1. Apigee sends traffic through a **PSC endpoint attachment** that lands in the customer's VPC.
2. The customer's VPC has **PGA enabled** on the relevant subnet.
3. DNS in the customer VPC maps `*.run.app` to the restricted/private VIP.
4. PGA routes the traffic from the customer VPC to Google's backbone.

**Traffic path:**

```
Apigee --> PSC --> Customer VPC (PGA-enabled subnet) --> Google backbone --> Cloud Run
```

### Option 2: Restricted VIP on the Apigee side

Apigee may resolve `run.app` directly if the restricted VIP configuration is applied on the Apigee infrastructure side. In this case, Apigee's own infrastructure routes traffic to the restricted Google VIP without traversing the customer VPC at all.

**Traffic path:**

```
Apigee --> restricted VIP --> Google backbone --> Cloud Run
```

In both cases, the HA VPN tunnels are **not used** for Cloud Run traffic.

---

## 5. Traffic Flow Walkthrough

The following numbered steps describe the end-to-end request lifecycle.

| Step | Description |
|------|-------------|
| 1 | Apigee proxy sends an HTTPS request to the Cloud Run service URL (e.g., `https://myservice-xyz-uc.a.run.app/endpoint`). |
| 2 | DNS resolves `myservice-xyz-uc.a.run.app` using the private DNS zone. The zone returns the restricted VIP (`199.36.153.4/30`) or private VIP (`199.36.153.8/30`) instead of the public IP. |
| 3 | PGA intercepts traffic destined for these VIP ranges on the PGA-enabled subnet. |
| 4 | Traffic routes over Google's internal backbone network. No VPN hop occurs. |
| 5 | The request reaches the Cloud Run service directly via Google's front-end infrastructure. |
| 6 | Cloud Run processes the request and returns the response over the same internal path. |
| 7 | The response arrives back at the Apigee proxy. |

> **Important:** Apigee must send the correct `Host` header matching the Cloud Run service's `run.app` URL. Cloud Run uses the `Host` header to route to the correct service. If the `Host` header does not match, Cloud Run will return a 404.

---

## 6. Components Required

PGA is the most minimal option in terms of infrastructure. The complete list of required components:

| Component | Required? | Notes |
|-----------|-----------|-------|
| PGA enabled on subnet | Yes | The subnet where Apigee resolves DNS / originates traffic |
| Private DNS zone for `*.run.app` | Yes | Maps Cloud Run URLs to restricted or private VIP |
| Cloud Run service | Yes | With IAM invoker permissions granted to the Apigee identity |
| Internal load balancer | **No** | Not needed |
| VPN tunnels (for this traffic) | **No** | PGA bypasses VPN entirely |
| Serverless NEG | **No** | Not needed |
| PSC service attachment | **No** | Not needed (unless using PSC provisioning model) |
| Forwarding rules | **No** | Not needed |

### Cloud Run Ingress Setting

The Cloud Run service must be accessible to traffic arriving via PGA. Set the ingress to one of:

- `internal` -- allows traffic from within the Google network (PGA traffic qualifies)
- `all` -- allows all traffic (less restrictive)

```bash
gcloud run services update SERVICE_NAME \
  --ingress=internal \
  --region=REGION
```

### IAM Invoker Permission

Grant the Apigee service identity permission to invoke the Cloud Run service:

```bash
gcloud run services add-iam-policy-binding SERVICE_NAME \
  --region=REGION \
  --member="serviceAccount:APIGEE_SERVICE_ACCOUNT" \
  --role="roles/run.invoker"
```

---

## 7. DNS Configuration

DNS is the key piece that makes PGA work for Cloud Run. Without correct DNS, Apigee will resolve the `run.app` URL to a public IP and traffic will not use PGA.

### Choose Your VIP

| VIP | Address Range | When to Use |
|-----|---------------|-------------|
| `restricted.googleapis.com` | `199.36.153.4/30` | With VPC Service Controls (VPC-SC) enforcement |
| `private.googleapis.com` | `199.36.153.8/30` | Without VPC-SC, general private access |

### Step 1: Create Private DNS Zone for `run.app`

```bash
gcloud dns managed-zones create run-app-zone \
  --dns-name="run.app." \
  --description="Private zone for Cloud Run PGA routing" \
  --visibility=private \
  --networks=APIGEE_VPC_NAME
```

### Step 2: Add Records Mapping `*.run.app` to the VIP

**Using CNAME to restricted VIP:**

```bash
gcloud dns record-sets create "*.run.app." \
  --zone="run-app-zone" \
  --type="CNAME" \
  --ttl=300 \
  --rrdatas="restricted.googleapis.com."
```

**Or using A records directly (restricted VIP):**

```bash
gcloud dns record-sets create "*.run.app." \
  --zone="run-app-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7"
```

### Step 3: Create Private DNS Zone for `googleapis.com` (Required for CNAME)

If you used a CNAME to `restricted.googleapis.com`, you also need a zone that resolves that name:

```bash
gcloud dns managed-zones create googleapis-zone \
  --dns-name="googleapis.com." \
  --description="Private zone for restricted googleapis VIP" \
  --visibility=private \
  --networks=APIGEE_VPC_NAME
```

```bash
gcloud dns record-sets create "restricted.googleapis.com." \
  --zone="googleapis-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7"
```

For the private VIP instead:

```bash
gcloud dns record-sets create "private.googleapis.com." \
  --zone="googleapis-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="199.36.153.8,199.36.153.9,199.36.153.10,199.36.153.11"
```

### Zone Visibility

The private DNS zone **must be authoritative** in the VPC where Apigee resolves DNS. Under VPC Peering provisioning (the assumed default), this is the **Apigee VPC**. If you are using the PSC non-peering model instead, the zone must be visible in the customer VPC where the PSC endpoint attachment lands.

Verify zone visibility:

```bash
gcloud dns managed-zones describe run-app-zone \
  --format="yaml(privateVisibilityConfig)"
```

---

## 8. Firewall Rules

PGA requires minimal firewall configuration. Traffic flows outbound from the VPC to Google's VIP ranges.

### Egress Rules

| Rule | Direction | Target | Destination | Port | Action |
|------|-----------|--------|-------------|------|--------|
| Allow PGA restricted VIP | Egress | All instances (or tagged) | `199.36.153.4/30` | 443 | Allow |
| Allow PGA private VIP | Egress | All instances (or tagged) | `199.36.153.8/30` | 443 | Allow |

> **Note:** The default VPC egress rule (`0.0.0.0/0 allow`) typically already permits this traffic. Explicit rules are only needed if you have restrictive egress policies.

```bash
# Only needed if default egress is denied
gcloud compute firewall-rules create allow-pga-restricted \
  --network=APIGEE_VPC_NAME \
  --direction=EGRESS \
  --action=ALLOW \
  --rules=tcp:443 \
  --destination-ranges="199.36.153.4/30" \
  --priority=1000 \
  --description="Allow egress to restricted Google VIP for PGA"
```

### Ingress Rules

No ingress rules are needed. PGA is outbound from the VPC's perspective -- the VPC initiates the connection to Google's backbone. Responses return on the established connection.

### Cloud Run Access Control

Cloud Run does not use VPC firewall rules for access control. Instead, IAM controls who can invoke the service (see [Section 6](#6-components-required)). The Cloud Run ingress setting controls which network paths are accepted.

---

## 9. Cost Estimate

PGA is the lowest-cost connectivity option.

| Component | Monthly Cost | Notes |
|-----------|-------------|-------|
| Private Google Access | $0.00 | No charge to enable PGA on a subnet |
| Cloud DNS private zone (`run.app`) | ~$0.20 | Per managed zone per month |
| Cloud DNS private zone (`googleapis.com`) | ~$0.20 | Only if using CNAME method |
| Cloud DNS queries | ~$0.00 | $0.40 per million queries (negligible for most) |
| Cloud Run invocations | Standard pricing | Per-request and per-vCPU-second; varies by workload |
| VPN tunnels | **$0.00** | Not needed for this traffic path |
| Load balancer | **$0.00** | Not needed |
| Forwarding rules | **$0.00** | Not needed |
| **Total infrastructure** | **~$0.20-$0.40/mo** | DNS zones only, plus standard Cloud Run usage costs |

Compared to other options:

| Option | Monthly Infrastructure Cost |
|--------|----------------------------|
| **A** (ILB + Serverless NEG) | ~$18+ (ILB forwarding rule + VPN) |
| **B** (PGA) | **~$0.20** |
| **C** (PSC for Google APIs) | ~$18 (PSC forwarding rule + DNS) |
| **D** (PSC Service Attachment) | ~$36+ (ILB + PSC forwarding rules) |

---

## 10. Scaling Characteristics

PGA scales inherently with Google's backbone infrastructure. There is no per-service resource to provision.

| Dimension | Behavior |
|-----------|----------|
| Adding a new Cloud Run service | Deploy the service, update Apigee proxy target URL. No infrastructure changes. |
| Per-service infrastructure | None. Each Cloud Run service has its own `*.run.app` URL covered by the wildcard DNS zone. |
| Forwarding rules / NEGs / ILBs | None to manage. |
| Regional behavior | Works across all regions automatically. The `*.run.app` wildcard covers services in any region. |
| Practical scaling limit | None. Google's backbone and PGA infrastructure scale without customer intervention. |
| Bottleneck risk | None from the connectivity layer. Cloud Run's own concurrency and instance limits apply as usual. |

### Scaling to 1000+ Services

At 1000 Cloud Run services, PGA requires **zero additional infrastructure**. The only change per service is:

1. Deploy the Cloud Run service.
2. Grant IAM invoker permission to the Apigee service account.
3. Configure the Apigee proxy with the new `*.run.app` target URL.

No DNS changes, no firewall changes, no load balancer updates. The wildcard DNS zone handles all `*.run.app` URLs.

---

## 11. Testing Requirements

Core networking validation only -- no VPC-SC testing.

### What to Deploy

| Resource | Configuration |
|----------|---------------|
| Cloud Run service | Simple test endpoint (e.g., returns 200 with service identity) |
| PGA | Enabled on the Apigee VPC subnet |
| Private DNS zone | `*.run.app` mapped to restricted or private VIP |
| (Optional) Test VM | In the Apigee VPC, **no external IP**, for manual curl testing |

#### Deploy a Test Cloud Run Service

```bash
gcloud run deploy pga-test-service \
  --image=us-docker.pkg.dev/cloudrun/container/hello \
  --region=REGION \
  --ingress=internal \
  --no-allow-unauthenticated
```

#### Enable PGA on the Subnet

```bash
gcloud compute networks subnets update SUBNET_NAME \
  --region=REGION \
  --enable-private-ip-google-access
```

#### Verify PGA is Enabled

```bash
gcloud compute networks subnets describe SUBNET_NAME \
  --region=REGION \
  --format="get(privateIpGoogleAccess)"
```

Expected output: `True`

### What to Validate

| Test | Expected Result |
|------|-----------------|
| Apigee proxy reaches Cloud Run via `*.run.app` URL | HTTP 200 response from Cloud Run service |
| DNS resolves to restricted/private VIP | `dig` returns `199.36.153.4/30` or `199.36.153.8/30` |
| Traffic does NOT traverse VPN | VPN tunnel metrics show no increase during test |
| Response includes Cloud Run identity | Response body or headers confirm the correct service |

### Test Commands

**From a test VM in the Apigee VPC (no external IP):**

```bash
# Verify DNS resolution
dig myservice-xyz-uc.a.run.app

# Expected: ANSWER section shows 199.36.153.4 (or .5/.6/.7 for restricted)
# or 199.36.153.8 (or .9/.10/.11 for private)

# Test connectivity (with authentication)
curl -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  https://pga-test-service-HASH-uc.a.run.app/
```

**Verify VPN is not carrying the traffic:**

```bash
# Check VPN tunnel metrics before and after the test
gcloud compute vpn-tunnels describe VPN_TUNNEL_NAME \
  --region=REGION \
  --format="yaml(detailedStatus)"

# Compare bytes sent/received in Cloud Monitoring:
# metric: compute.googleapis.com/vpn/tunnel_established
# metric: compute.googleapis.com/vpn/sent_bytes_count
# metric: compute.googleapis.com/vpn/received_bytes_count
# There should be no increase attributable to the test traffic.
```

**From the Apigee proxy (end-to-end):**

Configure an Apigee proxy with:
- Target URL: `https://pga-test-service-HASH-uc.a.run.app`
- Authentication: Google ID token with the Cloud Run service URL as audience

Send a test request through the Apigee proxy and confirm a successful response from Cloud Run.

### PoC Scripts

Runnable scripts for this option: [`scripts/option2/`](../scripts/option2/)
