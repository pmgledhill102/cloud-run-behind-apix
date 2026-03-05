# Option C: PSC Endpoint for Google APIs

## 1. Overview

Private Service Connect (PSC) endpoints for Google APIs assign a concrete internal IP address within your VPC to access Google APIs -- including Cloud Run. Unlike Private Google Access (Option B), which routes traffic through special Google-owned VIPs (`199.36.153.4/30` or `199.36.153.8/30`), PSC gives you an explicit, auditable internal IP from one of your own subnets.

> **Provisioning model:** This document assumes the **VPC Peering** provisioning model as the default. The PSC (non-peering) alternative is covered in [Section 4](#4-how-it-works-psc-non-peering-model).

**When to use Option C:**

- You need a specific, known internal IP for firewall rule enforcement
- You require VPC Service Controls (VPC-SC) integration with auditable endpoints
- Organizational policy demands that all Google API traffic use identifiable internal IPs
- You want an enterprise-grade alternative to PGA with tighter network governance

**Key characteristics:**

| Property | Value |
|---|---|
| Traffic path | Google backbone (bypasses VPN) |
| Load balancer required | No |
| VPN dependency | No |
| DNS complexity | Medium |
| VPC-SC support | Native (with `vpc-sc` bundle) |
| Per-service infrastructure | None -- single endpoint covers all Google APIs |
| Monthly base cost | ~$18 |

---

## 2. Architecture Diagram

![Option C Architecture](diagrams/option-c-architecture.drawio.svg)

---

## 3. How It Works: VPC Peering Model

In the VPC Peering provisioning model, Apigee X is peered to a customer-managed **Apigee VPC**. The PSC endpoint for Google APIs is created in this Apigee VPC, giving Apigee a direct path to Google APIs without traversing the HA VPN tunnels to the Workloads VPC.

### Setup

1. **Reserve an internal IP** in the Apigee VPC (e.g., `10.0.0.100`).
2. **Create a PSC endpoint** (forwarding rule) targeting the `all-apis` or `vpc-sc` bundle.
3. **Configure a private DNS zone** for `run.app` that maps `*.run.app` to the PSC endpoint IP.
4. The DNS zone must be **authoritative in the Apigee VPC** so that Apigee's DNS resolution picks it up.

### Traffic path

```
Apigee proxy
  → DNS resolves *.run.app to 10.0.0.100 (PSC endpoint)
    → PSC forwarding rule in Apigee VPC
      → Google backbone
        → Cloud Run service
```

### Key points

- The PSC endpoint is created **in the Apigee VPC**, not the Workloads VPC.
- VPN tunnels between Apigee VPC and Workloads VPC are **not used** for this traffic.
- Apigee resolves DNS within its peered VPC, so the private DNS zone must be associated with that VPC.
- A single PSC endpoint serves all Google APIs -- every Cloud Run service in every region is reachable through it.

---

## 4. How It Works: PSC (Non-Peering) Model

> **Note:** This section covers the PSC non-peering alternative. This repository assumes VPC Peering provisioning -- see [Provisioning Decision](apigee-provisioning-decision.md).

In the PSC (non-peering) provisioning model, Apigee does not peer to a customer VPC. Instead, Apigee uses **PSC endpoint attachments** for southbound traffic into a customer VPC.

### Setup

1. **Create a PSC endpoint for Google APIs** in the customer VPC where the Apigee PSC endpoint attachment terminates.
2. **Reserve an internal IP** in that customer VPC (e.g., `10.1.0.100`).
3. **Create the forwarding rule** targeting the `all-apis` or `vpc-sc` bundle.
4. The PSC endpoint IP is **reachable from Apigee** through the PSC plumbing (the endpoint attachment).
5. **Configure DNS** so that Apigee resolves `*.run.app` to the PSC endpoint IP.

### Traffic path

```
Apigee
  → PSC endpoint attachment
    → Customer VPC
      → PSC Google APIs endpoint (10.1.0.100)
        → Google backbone
          → Cloud Run service
```

### Key points

- The PSC endpoint lives in the **customer VPC**, not in an Apigee-owned VPC.
- Apigee reaches the customer VPC through the PSC endpoint attachment, then traffic hits the PSC Google APIs forwarding rule.
- From the PSC endpoint, traffic routes over Google's backbone to Cloud Run -- it does **not** traverse HA VPN tunnels.
- This model also requires the **PSC endpoint attachment configuration on the Apigee side** to enable southbound connectivity.

---

## 5. Traffic Flow Walkthrough

The following numbered steps describe the request/response path. This applies to both provisioning models; the only difference is how Apigee reaches the VPC containing the PSC endpoint (peering vs. PSC endpoint attachment).

| Step | Description |
|---|---|
| 1 | Apigee proxy sends an HTTPS request to `myservice-xyz-uc.a.run.app` |
| 2 | DNS resolves to the PSC endpoint IP (e.g., `10.0.0.100`) via the private DNS zone for `run.app` |
| 3 | Traffic is routed to the PSC endpoint (forwarding rule in the VPC) |
| 4 | PSC tunnels the traffic to Google's API frontend over Google's internal backbone |
| 5 | The request reaches the Cloud Run service, which processes it and returns a response |
| 6 | The response returns via the PSC tunnel back to the forwarding rule IP |
| 7 | Apigee proxy receives the response and returns it to the API client |

> **Note:** When a PSC endpoint for Google APIs is created, GCP auto-generates a `p.googleapis.com` DNS zone. For example, `run-<hash>.p.googleapis.com` may be created as an alternative hostname. You can use this auto-generated hostname in Apigee target endpoints instead of configuring a custom private DNS zone for `run.app`.

---

## 6. Components Required

### Both provisioning models

| Component | Required | Notes |
|---|---|---|
| PSC endpoint (forwarding rule) for Google APIs | Yes | Target bundle: `all-apis` or `vpc-sc` |
| Internal IP address reservation | Yes | Reserved in the VPC where the PSC endpoint is created |
| Private DNS zone for `run.app` | Yes | Maps `*.run.app` to the PSC endpoint IP |
| Cloud Run service | Yes | With IAM invoker permissions for the Apigee service account |
| Load balancer | **No** | Not required |
| VPN tunnels | **No** | Traffic bypasses VPN entirely |
| Serverless NEG | **No** | Not required |

### Additional for PSC non-peering alternative

| Component | Required | Notes |
|---|---|---|
| PSC endpoint attachment on Apigee side | Yes | Enables southbound connectivity from Apigee into the customer VPC |
| Service attachment in customer VPC | Yes | Target for the Apigee PSC endpoint attachment |

### gcloud: Reserve internal IP and create PSC endpoint

```bash
# Reserve an internal IP address for the PSC endpoint
gcloud compute addresses create psc-google-apis-ip \
  --region=us-central1 \
  --subnet=apigee-subnet \
  --addresses=10.0.0.100

# Create the PSC endpoint (forwarding rule) for Google APIs
gcloud compute forwarding-rules create psc-google-apis \
  --region=us-central1 \
  --network=apigee-vpc \
  --address=psc-google-apis-ip \
  --target-google-apis-bundle=all-apis
```

> To use VPC-SC bundle instead, replace `all-apis` with `vpc-sc` in the `--target-google-apis-bundle` flag. Only VPC-SC-supported APIs will be reachable through the `vpc-sc` bundle.

### gcloud: Create private DNS zone

```bash
# Create private DNS zone for run.app
gcloud dns managed-zones create run-app-psc \
  --dns-name="run.app." \
  --visibility=private \
  --networks=apigee-vpc \
  --description="Route run.app to PSC endpoint"

# Add wildcard A record pointing to PSC endpoint IP
gcloud dns record-sets create "*.run.app." \
  --zone=run-app-psc \
  --type=A \
  --ttl=300 \
  --rrdatas="10.0.0.100"
```

---

## 7. DNS Configuration

DNS is the critical piece that makes PSC for Google APIs work. Without correct DNS, Apigee will resolve `*.run.app` to public IPs and traffic will not flow through the PSC endpoint.

### Auto-generated `p.googleapis.com` zone

When you create a PSC endpoint for Google APIs, GCP automatically creates a DNS zone under `p.googleapis.com`. For example:

```
run-<unique-hash>.p.googleapis.com
```

You can use this hostname directly in Apigee target endpoint configurations. This avoids the need for a custom private DNS zone for `run.app`, but requires updating all Apigee proxy target URLs to use the `p.googleapis.com` hostname.

### Custom private DNS zone for `run.app`

For most deployments, creating a private DNS zone is simpler because Apigee proxies can use standard `*.run.app` hostnames.

| DNS Record | Type | Value | Zone |
|---|---|---|---|
| `*.run.app` | A | `10.0.0.100` (PSC endpoint IP) | `run.app` (private) |

**Requirements:**

- The private DNS zone must be **authoritative** in the VPC where Apigee resolves DNS.
  - VPC Peering model: associate the zone with the **Apigee VPC**.
  - PSC model: associate the zone with the **customer VPC** where the PSC endpoint lives (DNS must be resolvable from Apigee's perspective through the PSC attachment).
- The zone overrides public DNS for `run.app` within the VPC. All Cloud Run services will resolve to the PSC endpoint IP.
- If using the `vpc-sc` bundle, only APIs that support VPC Service Controls are reachable. Cloud Run (`run.googleapis.com`) is supported.

### Choosing between `all-apis` and `vpc-sc` bundles

| Bundle | APIs reachable | Use when |
|---|---|---|
| `all-apis` | All Google APIs | No VPC-SC requirement, broadest compatibility |
| `vpc-sc` | Only VPC-SC-supported APIs | VPC-SC perimeter is enforced, compliance requirement |

---

## 8. Firewall Rules

PSC endpoints are internal to the VPC, so standard VPC firewall rules govern access. The firewall configuration for Option C is minimal.

### Required rules

| Rule | Direction | Source | Destination | Port | Purpose |
|---|---|---|---|---|---|
| Allow egress to PSC endpoint | Egress | Apigee IP range | PSC endpoint IP (`10.0.0.100/32`) | 443 | HTTPS to Google APIs via PSC |

### gcloud: Create firewall rule

```bash
gcloud compute firewall-rules create allow-apigee-to-psc \
  --network=apigee-vpc \
  --direction=EGRESS \
  --action=ALLOW \
  --destination-ranges=10.0.0.100/32 \
  --rules=tcp:443 \
  --priority=1000 \
  --description="Allow Apigee to reach PSC endpoint for Google APIs"
```

### What is NOT needed

- **No health check firewall rules.** PSC endpoints do not require health checks -- Google manages the underlying connectivity.
- **No special Google IP ranges.** Unlike PGA, you do not need to allow `199.36.153.x/30` ranges.
- **No VPN-related firewall rules** for this traffic path. Traffic does not traverse VPN tunnels.

### Cloud Run IAM

Firewall rules control network-level access. Invocation authorization is handled by **Cloud Run IAM**:

```bash
# Grant the Apigee service account permission to invoke Cloud Run
gcloud run services add-iam-policy-binding myservice \
  --region=us-central1 \
  --member="serviceAccount:apigee-runtime@PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

---

## 9. Cost Estimate

Option C has a low, predictable cost structure. The PSC forwarding rule is the primary cost component.

| Component | Monthly Cost | Notes |
|---|---|---|
| PSC forwarding rule | ~$18.00 | Charged like a standard forwarding rule |
| Data processing (PSC) | ~$0.01/GB | Per-GB charge on traffic through the PSC endpoint |
| Cloud DNS private zone | ~$0.20 | Per managed zone per month |
| VPN tunnels | **$0.00** | Not needed -- traffic bypasses VPN |
| Load balancer | **$0.00** | Not needed |
| Serverless NEG | **$0.00** | Not needed |
| **Total (base)** | **~$18.20/mo** | Plus ~$0.01/GB data processing |

### Cost comparison with other options

| Option | Base Monthly Cost | VPN Cost | Notes |
|---|---|---|---|
| **A** (ILB + NEG via VPN) | ~$18 (ILB) | + VPN costs | Per-region ILB required |
| **B** (PGA) | ~$0.20 | $0.00 | Cheapest option |
| **C** (PSC for Google APIs) | ~$18.20 | $0.00 | Enterprise-grade, auditable IP |
| **D** (PSC Service Attachment) | ~$36+ | $0.00 | ILB + PSC per service group |

> Option C costs more than Option B (PGA) but provides an explicit internal IP for firewall enforcement and audit trails. The ~$18/mo premium over PGA buys network governance and VPC-SC-native integration.

---

## 10. Scaling Characteristics

Option C scales exceptionally well. A single PSC endpoint covers all Google APIs, so there is no per-service infrastructure to manage.

### Single endpoint, all services

| Property | Behavior |
|---|---|
| Cloud Run services covered | **All** -- every service in every region |
| Forwarding rules needed | **1** (per VPC where PSC is deployed) |
| Per-service infrastructure | **None** |
| Adding a new Cloud Run service | Deploy the service, update the Apigee proxy target URL -- no infrastructure changes |

### Scaling limits

| Limit | Value | Impact |
|---|---|---|
| PSC endpoints per VPC | Check [VPC quotas](https://cloud.google.com/vpc/docs/quota) | Rarely a concern -- one endpoint serves all APIs |
| Concurrent connections | Subject to VPC and PSC quotas | Monitor PSC endpoint metrics |
| Bandwidth | Limited by VPC egress capacity | Not a practical bottleneck for API traffic |

### What happens at 1000+ Cloud Run services

1. **No infrastructure changes.** The same single PSC endpoint and DNS zone serve all 1000+ services.
2. **No forwarding rule fan-out.** Unlike Option A (which needs ILBs per region) or Option D (which needs ILB + service attachment per group), Option C remains a single forwarding rule.
3. **Apigee proxy management is the bottleneck.** The scaling challenge shifts to managing Apigee proxy configurations, not infrastructure.
4. **DNS stays simple.** The `*.run.app` wildcard A record covers every Cloud Run service hostname automatically.

---

## 11. Testing Requirements

Core networking validation only -- no VPC-SC testing in the initial validation.

### What to deploy

| Resource | Configuration |
|---|---|
| PSC endpoint for Google APIs | Forwarding rule with `all-apis` bundle in the target VPC |
| Internal IP reservation | Static IP in the VPC subnet (e.g., `10.0.0.100`) |
| Private DNS zone | `run.app` zone with `*.run.app` A record pointing to PSC IP |
| Cloud Run test service | Simple hello-world service with IAM invoker grant |
| Test VM (optional) | VM in the same VPC for manual DNS and connectivity testing |

### What to validate

| # | Validation | Expected Result |
|---|---|---|
| 1 | Apigee proxy can reach Cloud Run via PSC endpoint | HTTP 200 response from Cloud Run service |
| 2 | DNS resolves `*.run.app` to PSC IP (not public IP) | `nslookup` returns `10.0.0.100` |
| 3 | Traffic does NOT traverse VPN tunnels | VPN tunnel metrics show no increase in traffic |
| 4 | `p.googleapis.com` auto-zone is created | Zone visible in Cloud DNS or via `gcloud dns managed-zones list` |
| 5 | PSC endpoint shows traffic in metrics | Forwarding rule metrics dashboard shows bytes processed |

### Test commands

Run these from a test VM in the VPC where the PSC endpoint is deployed:

```bash
# Verify DNS resolution returns the PSC endpoint IP
nslookup myservice-xyz-uc.a.run.app
# Expected: 10.0.0.100

# Verify connectivity through the PSC endpoint
curl -v https://myservice-xyz-uc.a.run.app \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)"
# Expected: HTTP 200 with Cloud Run service response

# Verify the PSC endpoint forwarding rule exists
gcloud compute forwarding-rules describe psc-google-apis \
  --region=us-central1
# Expected: Shows target=all-apis, IPAddress=10.0.0.100

# Verify the auto-generated p.googleapis.com zone
gcloud dns managed-zones list --filter="dnsName:p.googleapis.com"
# Expected: Zone created by PSC endpoint

# Check PSC endpoint metrics (forwarded bytes)
gcloud monitoring metrics list \
  --filter='metric.type="compute.googleapis.com/forwarding_rule/psc/egress_bytes_count"'
```

### Apigee proxy test

Configure an Apigee proxy target endpoint to call the Cloud Run service:

```xml
<TargetEndpoint name="default">
  <HTTPTargetConnection>
    <URL>https://myservice-xyz-uc.a.run.app</URL>
  </HTTPTargetConnection>
</TargetEndpoint>
```

Invoke the Apigee proxy and verify the end-to-end flow returns a successful response from Cloud Run.
