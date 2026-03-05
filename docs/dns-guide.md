# DNS Guide

Cross-cutting DNS reference for all four Apigee-to-Cloud Run connectivity options.

> This guide assumes the **VPC Peering** provisioning model. All private DNS zones are created in the **Apigee VPC** (the customer-managed VPC that Apigee peers into). See [Provisioning Decision](apigee-provisioning-decision.md).

## DNS Requirements by Option

| Option | Zone needed | Records | VPC binding |
|---|---|---|---|
| **A** (ILB via VPN) | Custom domain zone (e.g., `internal.example.com`) | A → ILB IP | Apigee VPC |
| **B** (PGA) | `run.app` | A → restricted/private VIP | Apigee VPC |
| **C** (PSC Google APIs) | `run.app` | A → PSC endpoint IP | Apigee VPC |
| **D** (PSC Service Attachment) | Custom domain zone | A → PSC consumer endpoint IP | Apigee VPC |

## Google VIPs for Private Access

Two sets of virtual IPs (VIPs) are available for private access to Google APIs:

### restricted.googleapis.com

```
199.36.153.4/30
```

- IPs: 199.36.153.4, 199.36.153.5, 199.36.153.6, 199.36.153.7
- Supports only APIs that are VPC Service Controls compatible
- Use when: VPC-SC perimeter is enforced or planned
- Cloud Run (`run.googleapis.com`): supported

### private.googleapis.com

```
199.36.153.8/30
```

- IPs: 199.36.153.8, 199.36.153.9, 199.36.153.10, 199.36.153.11
- Supports all Google APIs (including those not in VPC-SC)
- Use when: no VPC-SC requirement, maximum API compatibility needed
- Cloud Run (`run.googleapis.com`): supported

### Which to choose

| Criteria | restricted | private |
|---|---|---|
| VPC-SC enforcement | Required | Not supported |
| API coverage | VPC-SC APIs only | All Google APIs |
| Cloud Run access | Yes | Yes |
| Recommendation | Use if VPC-SC is needed | Use if VPC-SC is not needed |

## Option B: PGA DNS Configuration

Private Google Access requires DNS to map Google API domains to the restricted or private VIP.

### Create zone for run.app

```bash
gcloud dns managed-zones create run-app-zone \
  --description="Route run.app to restricted VIP" \
  --dns-name="run.app." \
  --visibility=private \
  --networks="APIGEE_VPC_NAME"
```

### Add CNAME for all run.app subdomains

```bash
gcloud dns record-sets create "*.run.app." \
  --zone="run-app-zone" \
  --type="CNAME" \
  --ttl=300 \
  --rrdatas="run.app."
```

### Add A records for run.app apex

```bash
gcloud dns record-sets create "run.app." \
  --zone="run-app-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7"
```

### Also create zone for googleapis.com (required)

```bash
gcloud dns managed-zones create googleapis-zone \
  --description="Route googleapis.com to restricted VIP" \
  --dns-name="googleapis.com." \
  --visibility=private \
  --networks="APIGEE_VPC_NAME"

gcloud dns record-sets create "restricted.googleapis.com." \
  --zone="googleapis-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="199.36.153.4,199.36.153.5,199.36.153.6,199.36.153.7"

gcloud dns record-sets create "*.googleapis.com." \
  --zone="googleapis-zone" \
  --type="CNAME" \
  --ttl=300 \
  --rrdatas="restricted.googleapis.com."
```

## Option C: PSC Google APIs DNS Configuration

PSC endpoints for Google APIs provide an internal IP and auto-generate DNS entries.

### Create the PSC endpoint

```bash
# Reserve an internal IP
gcloud compute addresses create psc-google-apis-ip \
  --region=REGION \
  --subnet=SUBNET_NAME \
  --addresses=10.0.0.100

# Create the PSC endpoint
gcloud compute forwarding-rules create psc-google-apis \
  --region=REGION \
  --network=APIGEE_VPC_NAME \
  --address=psc-google-apis-ip \
  --target-google-apis-bundle=all-apis
```

### Auto-generated p.googleapis.com zone

When you create a PSC endpoint for Google APIs, GCP automatically creates a private DNS zone:

- Zone: `p.googleapis.com`
- Records: `run-ENDPOINT_ID.p.googleapis.com → <PSC endpoint IP>`
- This zone is auto-bound to the VPC

You can use this auto-generated hostname directly, or create your own zone:

### Custom zone for run.app (recommended)

```bash
gcloud dns managed-zones create run-app-psc-zone \
  --description="Route run.app to PSC endpoint" \
  --dns-name="run.app." \
  --visibility=private \
  --networks="APIGEE_VPC_NAME"

gcloud dns record-sets create "*.run.app." \
  --zone="run-app-psc-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="10.0.0.100"

gcloud dns record-sets create "run.app." \
  --zone="run-app-psc-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="10.0.0.100"
```

## Option A: ILB DNS Configuration

ILB-based routing uses custom domain names pointing to the ILB IP.

### Create zone for custom domain

```bash
gcloud dns managed-zones create api-internal-zone \
  --description="Route internal API domain to ILB" \
  --dns-name="api.internal.example.com." \
  --visibility=private \
  --networks="APIGEE_VPC_NAME"

gcloud dns record-sets create "api.internal.example.com." \
  --zone="api-internal-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="10.100.0.10"
```

### For multiple services with path-based routing

A single DNS record → ILB IP, then the ILB URL map routes:

```
api.internal.example.com/service-a  → backend-service-a (serverless NEG → Cloud Run A)
api.internal.example.com/service-b  → backend-service-b (serverless NEG → Cloud Run B)
```

### For host-based routing (multiple domains)

```bash
# Each domain resolves to the same ILB IP
gcloud dns record-sets create "service-a.internal.example.com." \
  --zone="api-internal-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="10.100.0.10"
```

Then the ILB URL map host rules route to different backends.

## Option D: PSC Service Attachment DNS Configuration

The consumer side of a PSC Service Attachment needs DNS pointing to the PSC endpoint.

### Create zone for custom domain

```bash
gcloud dns managed-zones create psc-api-zone \
  --description="Route API domain to PSC endpoint" \
  --dns-name="api.internal.example.com." \
  --visibility=private \
  --networks="APIGEE_VPC_NAME"

gcloud dns record-sets create "api.internal.example.com." \
  --zone="psc-api-zone" \
  --type="A" \
  --ttl=300 \
  --rrdatas="10.0.0.50"
```

The PSC endpoint IP (10.0.0.50) is in the consumer VPC. Traffic tunnels via PSC to the producer's Service Attachment and ILB.

## DNS Forwarding Between VPCs

When Apigee VPC and Workloads VPC need to share DNS resolution (relevant for Option A with VPN):

### Cloud DNS peering (recommended)

```bash
# Create a peering zone in the Apigee VPC that forwards to the Workloads VPC
gcloud dns managed-zones create workloads-dns-peering \
  --description="Forward DNS to Workloads VPC" \
  --dns-name="internal.example.com." \
  --visibility=private \
  --networks="APIGEE_VPC_NAME" \
  --target-network="WORKLOADS_VPC_NAME" \
  --target-project="WORKLOADS_PROJECT_ID"
```

### DNS forwarding via Cloud DNS server policy

Alternative: use DNS forwarding with an inbound server policy on the Workloads VPC and conditional forwarding from the Apigee VPC.

```bash
# Inbound policy on Workloads VPC (creates inbound forwarder IPs)
gcloud dns policies create workloads-inbound \
  --description="Accept forwarded DNS queries" \
  --networks="WORKLOADS_VPC_NAME" \
  --enable-inbound-forwarding

# Forwarding zone in Apigee VPC targeting the inbound IPs
gcloud dns managed-zones create forward-to-workloads \
  --description="Forward queries to Workloads VPC" \
  --dns-name="internal.example.com." \
  --visibility=private \
  --networks="APIGEE_VPC_NAME" \
  --forwarding-targets="INBOUND_IP_1,INBOUND_IP_2"
```

Note: DNS forwarding IPs must be reachable from the Apigee VPC (via VPN for Option A).

## Cloud DNS Response Policies

Response policies can override DNS responses for specific queries. Useful for:

- Redirecting specific service URLs to different backends
- A/B testing different connectivity options
- Emergency failover

```bash
gcloud dns response-policies create apigee-overrides \
  --description="Override DNS for Apigee traffic" \
  --networks="APIGEE_VPC_NAME"

gcloud dns response-policies rules create redirect-service-a \
  --response-policy="apigee-overrides" \
  --dns-name="service-a-xyz-uc.a.run.app." \
  --local-data="service-a-xyz-uc.a.run.app.,A,300,10.100.0.10"
```

## Common Pitfalls

1. **Zone not bound to correct VPC**: Private DNS zones must be authoritative in the VPC where the DNS query originates. For peering model, this is the Apigee VPC.

2. **CNAME vs A records for run.app**: Using CNAME `*.run.app → restricted.googleapis.com` requires that `restricted.googleapis.com` also resolves privately. Use A records for simplicity.

3. **Conflicting zones**: If multiple private zones match the same query, the most specific one wins. A zone for `run.app.` will override a zone for `app.`.

4. **PSC auto-zone conflicts**: The auto-generated `p.googleapis.com` zone is always present when a PSC endpoint exists. Do not create a conflicting manual zone.

5. **TTL considerations**: Low TTL (60-300s) for ILB and PSC IPs allows faster failover. Google VIPs (199.36.153.x) are stable and can use higher TTL.
