# Day-2 Operations: Who Does What When APIs Change?

This analysis traces what happens — and who has to act — when the API surface evolves. The focus is on whether the **central Apigee platform team** becomes a bottleneck.

## Operating Model

| Actor | Owns | Self-service? |
|---|---|---|
| **App team** | Cloud Run service, ILB/NEG/URL map (from templates), DNS records | Yes — deploys via CI/CD |
| **Apigee platform team** | Apigee proxies, environments, endpoint attachments, env group hostnames | Bottleneck under investigation |
| **Network platform team** | VPCs, peering, VPN tunnels, PSC base infrastructure, firewall policies | Engaged once at setup |

## Example API Surface

A banking platform. Five Cloud Run services across four teams, evolving over time.

```
Day 1:  GET  /accounts/{id}           →  accounts-api    (Team A)
        POST /accounts                →  accounts-api    (Team A)

Day 2:  GET  /cards/{id}              →  cards-api       (Team B)  ← new service, new path
        POST /cards/{id}/activate     →  cards-api       (Team B)

Day 3:  POST /payments                →  payments-api    (Team C)  ← extracted from accounts-api
        GET  /payments/{id}/status    →  payments-api    (Team C)

Day 4:  GET  /branches/{id}           →  branches-api    (Team D)  ← entirely new API product
        GET  /branches?near={lat,lng} →  branches-api    (Team D)

Day 5:  GET  /v2/accounts/{id}        →  accounts-api-v2 (Team A)  ← new version, new service
        GET  /v1/accounts/{id}        →  accounts-api    (still live)
```

---

## Option B (PGA) and Option C (PSC Google APIs)

These two options are operationally identical — the only difference is the DNS mechanism (restricted VIP vs PSC endpoint IP). Both use native `*.run.app` URLs.

### How routing works

```
Client → Apigee proxy → *.run.app URL → [PGA restricted VIP | PSC endpoint] → Cloud Run
```

Apigee does **all** the routing. Each proxy has a BasePath and a target URL pointing directly to a Cloud Run service's `*.run.app` URL. There is no ILB, no URL map, no NEG.

### Day-by-day: who does what

| Day | What changes | App team | Apigee team | Network team |
|-----|-------------|----------|-------------|--------------|
| **1** | `accounts-api` goes live | Deploy Cloud Run service | Create proxy: BasePath `/accounts` → `https://accounts-api-xxx.run.app` | Nothing |
| **2** | `cards-api` added | Deploy Cloud Run service | Create proxy: BasePath `/cards` → `https://cards-api-xxx.run.app` | Nothing |
| **3** | `payments-api` extracted | Deploy Cloud Run service | Create proxy: BasePath `/payments` → `https://payments-api-xxx.run.app` | Nothing |
| **4** | `branches-api` added | Deploy Cloud Run service | Create proxy: BasePath `/branches` → `https://branches-api-xxx.run.app` | Nothing |
| **5** | `accounts-api-v2` added | Deploy Cloud Run service | Create proxy: BasePath `/v2/accounts` → `https://accounts-api-v2-xxx.run.app`; update existing to `/v1/accounts` | Nothing |

### Apigee team involvement: every change

The Apigee team creates or updates a proxy for **every** new service or path change. This is the same amount of work regardless of connectivity option — it's inherent to using Apigee as an API gateway.

**But can this be self-service?** Yes. The proxy configuration is:
- A BasePath (e.g. `/accounts`)
- A target URL (the Cloud Run `*.run.app` URL)
- Standard policies (auth, rate limiting) from shared templates

If the Apigee team provides **proxy templates and a CI/CD pipeline**, app teams can own their own proxy config. The Apigee team's role shifts from "configure every proxy" to "maintain templates and guardrails."

### Network team involvement: zero (after initial setup)

The `*.run.app` wildcard DNS zone covers all current and future Cloud Run services. No DNS changes, no PSC changes, no firewall changes.

---

## Option A (ILB via VPN)

### How routing works

```
Client → Apigee proxy → ILB IP → URL map → Serverless NEG → Cloud Run
```

Routing happens in **two places**: Apigee routes to the ILB, and the ILB URL map routes to the correct backend. This split is the key operational difference.

### Day-by-day: who does what

| Day | What changes | App team | Apigee team | Network team |
|-----|-------------|----------|-------------|--------------|
| **1** | `accounts-api` goes live | Deploy Cloud Run, create NEG + backend, add to URL map: `/accounts/*` → `neg-accounts` | Create proxy: BasePath `/accounts` → `https://api.internal.example.com/accounts` | Nothing (ILB exists) |
| **2** | `cards-api` added | Deploy Cloud Run, create NEG + backend, add URL map rule: `/cards/*` → `neg-cards` | Create proxy: BasePath `/cards` → `https://api.internal.example.com/cards` | Nothing |
| **3** | `payments-api` extracted | Deploy Cloud Run, create NEG + backend, add URL map rule: `/payments/*` → `neg-payments` | Create proxy: BasePath `/payments` → `https://api.internal.example.com/payments` | Nothing |
| **4** | `branches-api` added | Deploy Cloud Run, create NEG + backend, add URL map rule: `/branches/*` → `neg-branches` | Create proxy: BasePath `/branches` → `https://api.internal.example.com/branches` | Nothing |
| **5** | `accounts-api-v2` added | Deploy Cloud Run, create NEG + backend, add URL map rule: `/v2/accounts/*` → `neg-accounts-v2` | Create proxy: BasePath `/v2/accounts` → `https://api.internal.example.com/v2/accounts`; update existing to `/v1/accounts` | Nothing |

### Apigee team involvement: every change (same as B/C)

The Apigee proxy work is identical — a BasePath and a target URL. The target URL pattern changes (ILB hostname instead of `*.run.app`), but the work is the same.

### App team involvement: more work per change

For every new Cloud Run service, the app team must also:
1. Create a Serverless NEG
2. Create a backend service
3. Add a URL map path rule
4. (These are templateable via Terraform modules)

### Network team involvement: zero (if ILB is app-team-owned)

Since the ILB is owned by the app team (from templates), no network team involvement. The VPN tunnels and VPCs are already in place.

**Risk**: if the ILB is *not* app-team-owned (e.g. shared ILB managed by a central team), then every new service requires a ticket to update the URL map. This creates a second bottleneck alongside Apigee.

---

## Option D (PSC Service Attachment)

### How routing works

```
Client → Apigee proxy → Endpoint Attachment host → Service Attachment → ILB → URL map → NEG → Cloud Run
```

Same as Option A but with an additional PSC layer between Apigee and the ILB.

### Day-by-day: who does what

| Day | What changes | App team | Apigee team | Network team |
|-----|-------------|----------|-------------|--------------|
| **1** | `accounts-api` goes live | Deploy Cloud Run, create NEG + backend, add to URL map | Create proxy: BasePath `/accounts` → `https://{ea-host}/accounts` | Nothing (SA + EA exist) |
| **2** | `cards-api` added | Deploy Cloud Run, create NEG + backend, add URL map rule | Create proxy: BasePath `/cards` → `https://{ea-host}/cards` | Nothing |
| **3** | `payments-api` extracted | Deploy Cloud Run, create NEG + backend, add URL map rule | Create proxy: BasePath `/payments` → `https://{ea-host}/payments` | Nothing |
| **4** | `branches-api` added | Deploy Cloud Run, create NEG + backend, add URL map rule | Create proxy: BasePath `/branches` → `https://{ea-host}/branches` | Nothing |
| **5** | `accounts-api-v2` added | Deploy Cloud Run, create NEG + backend, add URL map rule | Create proxy: BasePath `/v2/accounts` → `https://{ea-host}/v2/accounts`; update existing | Nothing |

### Apigee team involvement: every change (same as all options)

Identical proxy work. The target URL uses the endpoint attachment hostname instead of an ILB IP or `*.run.app` URL, but the configuration effort is the same.

### App team involvement: same as Option A

NEG + backend + URL map rule per new Cloud Run service.

### Network team involvement: only at major milestones

The Service Attachment and Endpoint Attachment are created once and shared across all services behind that ILB. New services don't require new PSC resources — they're added to the existing ILB URL map.

Network team is only needed when:
- A new ILB group is created (exceeding URL map limits or for isolation)
- A new Service Attachment + Endpoint Attachment pair is needed for the new group

---

## Summary: Apigee Team Workload per Change

| Scenario | Option B/C | Option A | Option D |
|----------|-----------|----------|----------|
| New Cloud Run service, new path | Create proxy | Create proxy | Create proxy |
| Path extraction (move to new service) | Update proxy target URL | Update proxy target URL + app team updates URL map | Update proxy target URL + app team updates URL map |
| New API version | Create new proxy, update old | Create new proxy, update old | Create new proxy, update old |
| **Apigee work is identical across all options** | | | |

The Apigee team does the **same amount of work regardless of connectivity option**. The proxy configuration (BasePath + target URL + policies) is always required.

## The Real Question: Can Apigee Proxy Config Be Self-Service?

The connectivity option doesn't change the Apigee team's workload. What changes it is **ownership of proxy configuration**:

| Model | Apigee team role | App team role |
|-------|-----------------|---------------|
| **Centralised** (current) | Creates/updates every proxy | Requests changes via ticket |
| **Template-based** | Maintains proxy templates, policies, CI/CD pipeline | Owns their proxy config, deploys via pipeline |
| **GitOps** | Reviews PRs, maintains shared policies | Full proxy config in their repo, merged via PR |

### What makes self-service easier or harder per option

| Factor | Option B/C | Option A/D |
|--------|-----------|------------|
| **Target URL discovery** | App team knows their own `*.run.app` URL (output of `gcloud run deploy`) | App team must know the shared ILB hostname and coordinate path prefixes |
| **Path conflict risk** | None — each proxy targets a unique Cloud Run URL | URL map path rules must not conflict across teams sharing an ILB |
| **Blast radius of misconfiguration** | Only affects one service | URL map error could break routing for all services on that ILB |
| **Self-service complexity** | Low — proxy template is BasePath + Cloud Run URL | Medium — must also manage NEG/backend/URL map alongside proxy |

### Recommendation

**Options B and C are most amenable to self-service proxy management.** The app team deploys a Cloud Run service, gets a URL, and configures their Apigee proxy from a template. No coordination with other teams needed. No shared state to conflict with.

**Options A and D can be self-service** but require more discipline: shared ILB URL maps need path-prefix conventions, and app teams need ILB management skills (or good Terraform modules). The Apigee proxy config itself is equally simple across all options.

**The bottleneck is not the connectivity option — it's the proxy ownership model.** Moving to template-based or GitOps proxy management eliminates the Apigee team bottleneck regardless of which option is chosen.
