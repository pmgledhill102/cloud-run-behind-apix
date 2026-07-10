# Path-Based Routing at Scale: URL Hierarchy → Apigee → Cloud Run

**Status: paper design.** This maps the company URL hierarchy onto Apigee and
Cloud Run constructs, works the scaling math at the target scale, and lists
what a PoC extension must prove. Claims marked **[VERIFY]** are unproven —
they are the PoC's target list, not established facts.

**Design point:** ~50 L1 domains, ~500 APIs, environment-per-lifecycle
(Dev / Pre-Prod / Prod). Connectivity layer is Option B/2b (PGA via restricted
VIP, VPC-SC perimeter) — which is scale-free per the
[scaling analysis](scaling-analysis.md): one wildcard DNS zone serves every
Cloud Run service, so **nothing in this document adds networking
infrastructure per service**. Everything below is Apigee configuration and
Cloud Run deployment topology.

---

## 1. The URL contract

One external domain; everything below it routes on path:

```
https://api.example.com/<Domain>/<L1-Domain>[/<L1-SubDomain>][/<L2-Domain>][/<L2-SubDomain>]/<api-name>[/<version>]/<ResourcePath>?params
```

Worked example:

```
https://api.example.com/payments/cards/issuing/disputes/v1/disputes/dsp-123?status=open
        └──────┬──────┘ └──┬───┘ └─┬─┘ └──┬──┘ └──┬───┘ └┬┘ └──────┬─────┘ └────┬────┘
            hostname     Domain    L1   L1-Sub  api-name  ver  ResourcePath    params
```

| Segment | Cardinality (target) | Meaning |
|---|---|---|
| hostname | 1 per lifecycle stage | `api.example.com` (prod), `api.preprod.example.com`, `api.dev.example.com` |
| `Domain` | ~8–12 | Top-level business/data domain (`payments`, `customers`, …) |
| `L1-Domain` | **~50 total** | Primary ownership boundary (`cards`, `accounts`, …) |
| `L1-SubDomain` … `L2-SubDomain` | optional | Finer partitions inside an L1 team's space |
| `api-name` | **~500 total** (~10 per L1) | A single API |
| `version` | optional, ~1–2 active per API | See §5 |
| `ResourcePath` + params | unbounded | Passed through untouched to the service |

---

## 2. Which construct consumes which segment

The core of the design — every URL segment is resolved by exactly one layer:

| URL element | Resolved by | Construct |
|---|---|---|
| hostname | Apigee **environment group** | group's hostname list → member environments |
| `/Domain/L1[/L1-Sub]` | Apigee **proxy base path** | selects the deployed proxy (most-specific match) |
| segments below the base path | **conditional flows** inside the proxy | selects a flow → route rule |
| `api-name` (+ `version` if pattern B) | **route rule → target endpoint** | selects the Cloud Run service |
| `ResourcePath?params` | **path suffix passthrough** | appended to the target URL, untouched |

```
 api.example.com ──► env group "prod-group" ──► environment "prod"
                                                     │
        /payments/cards…  ──────────────────────────►│ base-path match
                                                     ▼
                                        ┌─ proxy: payments-cards ─────────────┐
                                        │  BasePath /payments/cards           │
                                        │                                     │
        /issuing/disputes/v1/… ────────►│  Flow: pathsuffix ~ /issuing/       │
                                        │        disputes/v1/**               │
                                        │    └─► RouteRule → TargetEndpoint   │
                                        │          GoogleIDToken audience =   │
                                        │          https://payments-cards-    │
                                        │          disputes-<hash>.run.app    │
                                        └─────────────────┬───────────────────┘
                                                          ▼
                              restricted VIP (199.36.153.4/30, in-perimeter)
                                                          ▼
                              Cloud Run: payments-cards-disputes  /disputes/dsp-123
```

Two verified routing facts this design leans on (Apigee docs, with a
documented `/catalog` vs `/catalog/cart` example):

1. **Base paths must be unique within an environment group** — two proxies
   cannot claim the same base path.
2. **Nested base paths route by most-specific match** — `/payments` and
   `/payments/cards` can be *different proxies* and requests land correctly.
   **[VERIFY]** in the PoC anyway: this is the load-bearing wall.

---

## 3. Proxy granularity: where the deployment unit sits

A proxy is Apigee's unit of deployment, revision history, and blast radius.
Candidate granularities at the target scale (50 L1, 500 APIs):

| Proxy per… | Proxy count | APIs/proxy | Deploy blast radius | Verdict |
|---|---|---|---|---|
| `Domain` | ~10 | ~50 | every L1 team in the domain | too coarse — deploy contention across teams |
| **`L1-Domain`** | **~50** | **~10** | one team | **default** — matches ownership boundary |
| `L1-SubDomain` | ~100–150 | ~3–5 | sub-team | escape hatch for hot/contended L1s |
| `api-name` | ~500 | 1 | one API | blows the per-env deployment limit (§6) |

**Recommendation: one proxy per L1-Domain by default**, splitting an L1 into
SubDomain proxies only when revision contention demands it (§7). Because
nested base paths coexist (fact 2 above), a split is **incremental**: carve
`/payments/cards/issuing` out into its own proxy while `/payments/cards`
keeps serving everything else — no big-bang migration. **[VERIFY]** the
carve-out behaviour explicitly.

---

## 4. Inside the proxy: branching to Cloud Run services

Sketch of the `payments-cards` proxy (base path `/payments/cards`):

```xml
<ProxyEndpoint name="default">
  <HTTPProxyConnection><BasePath>/payments/cards</BasePath></HTTPProxyConnection>
  <Flows>
    <!-- most-specific first: flows evaluate in order, first match wins -->
    <Flow name="issuing-disputes-v2">
      <Condition>proxy.pathsuffix MatchesPath "/issuing/disputes/v2/**"</Condition>
    </Flow>
    <Flow name="issuing-disputes-v1">
      <Condition>proxy.pathsuffix MatchesPath "/issuing/disputes/v1/**"</Condition>
    </Flow>
    <Flow name="acquiring-settlements">
      <Condition>proxy.pathsuffix MatchesPath "/acquiring/settlements/**"</Condition>
    </Flow>
  </Flows>
  <RouteRule name="disputes-v2">
    <Condition>proxy.pathsuffix MatchesPath "/issuing/disputes/v2/**"</Condition>
    <TargetEndpoint>disputes-v2</TargetEndpoint>
  </RouteRule>
  <!-- … one RouteRule per target … -->
</ProxyEndpoint>

<TargetEndpoint name="disputes-v2">
  <HTTPTargetConnection>
    <URL>https://payments-cards-disputes-v2-HASH.REGION.run.app</URL>
    <Authentication>
      <GoogleIDToken>
        <Audience>https://payments-cards-disputes-v2-HASH.REGION.run.app</Audience>
      </GoogleIDToken>
    </Authentication>
  </HTTPTargetConnection>
</TargetEndpoint>
```

Key mechanics:

- **Each Cloud Run service is a distinct TargetEndpoint** because the
  `GoogleIDToken` audience must match that service's URL exactly (learned
  the hard way — see [field notes §3](option-b-vpcsc-field-notes.md)). One
  deploy-time SA can serve all targets in the proxy, provided it holds
  `run.invoker` on each service.
- **Path suffix forwarding**: Apigee strips the base path and appends the
  remainder to the target URL — `ResourcePath?params` arrive at the service
  untouched. The service must either accept the full suffix
  (`/issuing/disputes/v1/…`) or the proxy rewrites it. **Decide once,
  estate-wide** — per-API rewrite rules are an operability tax. **[VERIFY]**
  what lands on the service and pick the convention.
- ~10 APIs × ≤2 versions + subdomain nesting ≈ **20–40 flows per proxy** at
  target scale: well within practice, but flow-count → latency is
  undocumented. **[VERIFY]** with a deliberately fat proxy (§9).

---

## 5. Versioning: two patterns, per-API choice

| | Pattern A: version-internal | Pattern B: version-per-service |
|---|---|---|
| Cloud Run | one service handles all its versions | `…-disputes-v1`, `…-disputes-v2` separate services |
| Proxy | version segment passes through in the suffix | flow + route rule + target per version |
| Fan-out cost | none | ×(active versions) flows/targets |
| Traffic control | in-service | per-version at the proxy (canary, kill-switch, independent scaling) |
| Fits when | additive changes, single codebase | breaking changes, migration windows, different runtimes |

Both are expressible in the same proxy simultaneously — pattern choice is
per-API, not estate-wide. The doc'd default: **A until you need B**.

---

## 6. The limits ledger

Verified against current Apigee PAYG documentation (2026-07):

| Limit | Base | Intermediate | Comprehensive | Bites at our scale? |
|---|---|---|---|---|
| **Deployed proxies / env / region** | **20** | **50** | **100** (purchasable → 6,000) | **YES — the pivotal number** (§7) |
| Environments / org | 5 | 5 | 85 | only if sharding envs by domain |
| Basepaths / environment | 500 (temporary enforcement) | ← | ← | no (50–150 basepaths) |
| Basepaths / org | 3,000 | ← | ← | no |
| Basepaths / env group (latency guidance) | ≤3,000 recommended | ← | ← | no |
| Deployment units / org | 4,250–6,000 | ← | ← | no (≈150–450) |
| Shared flow deployments / env | 75 | ← | ← | watch if per-domain shared flows proliferate |
| Proxy revisions retained | 50 | ← | ← | ops hygiene only |
| Cloud Run services / project | 5,000 (quota) | | | no (~500–1,000 incl. versions) |
| Connectivity (DNS/PGA/VPC-SC) | scale-free | | | no — wildcard zone, no per-service infra |

Not found in current docs — **[VERIFY]** empirically or with Google:
env groups per org, hostnames per env group, proxy bundle zip size,
target servers per environment.

---

## 7. The scaling math, and what breaks first

At the design point (50 L1 proxies, env-per-lifecycle, each lifecycle env in
its own env group / hostname):

- **Proxies per env = 50** → PAYG **Intermediate is exactly at its ceiling
  with zero headroom**; a 51st L1 domain, or the *first* L1→SubDomain split,
  breaks it. **Comprehensive (100 included) is the honest minimum** for this
  design, and its purchasable ceiling (6,000) covers any plausible growth.
- **Everything else is comfortable** — basepaths, org deployment units,
  Cloud Run quotas all have ≥5× headroom.

So the failure sequence as the estate grows:

1. **Per-env deployment ceiling** (first, and the only structural one).
   Mitigations, in order of preference:
   a. Comprehensive env type + purchased deployments — config unchanged.
   b. **Environment sharding**: split `prod` into per-Domain environments
      (`prod-payments`, `prod-customers`, …) all attached to the *same* env
      group, so `api.example.com` is unchanged externally. Base paths stay
      unique across the group because Domains own distinct prefixes.
      Requires Comprehensive (85 envs/org). **[VERIFY]** cross-env routing
      within one group.
2. **Operational churn, not limits** (second): 50 proxies × frequent
   revisions. This is a CI/CD and ownership problem (§8), not an Apigee one.
3. **Org-level ceilings** (distant): 3,000 basepaths / 6,000 deployment
   units — at ~10× the design point, by which time multi-org federation is
   the conversation.

---

## 8. Ownership and delivery model

- **Proxy = repo = pipeline = team.** The L1 team owns
  `payments-cards` end to end: its proxy config, its Cloud Run services, its
  deploy cadence. A proxy deploy is a whole-proxy revision — there is no
  partial deploy — so **the proxy boundary is the contention boundary**.
  Two squads repeatedly queueing on one proxy's revisions is the signal to
  split to L1-SubDomain granularity (§3 makes that incremental).
- **Platform team owns**: the env group / hostname, environment topology,
  the Option 2b perimeter + connectivity, shared flows (auth, logging,
  CORS — mind the 75/env cap), and the naming standard (§below). Domain
  teams cannot break each other's routing: base-path uniqueness is enforced
  by Apigee at deploy time — a mis-scoped base path fails fast rather than
  shadowing a sibling. **[VERIFY]** the failure mode.
- **The 50-revision retention** limit is a nudge: high-churn proxies need
  their revision history exported to the repo, which the repo-per-proxy
  model gives for free.

### Naming convention

Derive every name from the path hierarchy — the estate stays greppable:

| Thing | Pattern | Example |
|---|---|---|
| Proxy | `<domain>-<l1>[-<l1sub>]` | `payments-cards` |
| Target endpoint | `<api>[-<version>]` | `disputes-v2` |
| Cloud Run service | `<domain>-<l1>-<api>[-<version>]` | `payments-cards-disputes-v2` |
| Env group | `<stage>-group` | `prod-group` |
| Hostname | `api[.<stage>].example.com` | `api.preprod.example.com` |

(The PoC's env-group hostname is `api.internal.example.com`; align to
`api.example.com` when extending.)

---

## 9. PoC extension plan

Build on the standing option 2b stack (perimeter enforced). Each item proves
a **[VERIFY]** above; ordered so the cheap, structural proofs come first:

1. **Nested base-path routing** — deploy `payments` (base path `/payments`)
   and `payments-cards` (`/payments/cards`) as separate proxies targeting
   distinct `cr-hello` clones; prove most-specific-match, then delete the
   nested proxy and prove fallback to `/payments`.
2. **The carve-out** — start with `/payments/cards` serving
   `/issuing/**` via flows; extract `/payments/cards/issuing` into its own
   proxy live; prove no request disruption and no 404 window.
3. **Base-path conflict** — attempt to deploy a second proxy claiming
   `/payments/cards`; capture the exact deploy-time error for the field
   notes.
4. **Branch fan-out** — one proxy with N conditional flows → N `cr-hello`
   clones (reuse the `SERVICE_COUNT` pattern from option-c-scaled); measure
   p50/p95 latency at N = 1, 10, 50, 100 flows.
5. **Both version patterns side by side** — one API as pattern A
   (suffix passthrough), one as pattern B (v1/v2 services); prove the
   suffix that lands on each service and fix the path convention.
6. **The deployment ceiling** — on a Base-type environment (limit **20**,
   so it's cheap to hit), script proxy deployments until refusal; capture
   the error and confirm the limit is per-env-per-region as documented.
7. **Env sharding under one hostname** — second environment attached to the
   same env group, proxy deployed there with a distinct Domain prefix;
   prove `api.example.com/<other-domain>/…` routes cross-env.
8. **Egress governance** — implemented ahead of this plan: `option2b/setup.sh`
   applies a perimeter egress allow-list admitting one named external Cloud
   Run project, and `option2b/test-external.sh` asserts blocked *and* allowed
   external targets in one run. Remaining: measure egress-rule change
   propagation with the harness, and record the syntax trap (logged
   `run.routes.invoke` is not valid `methodSelector` syntax — use
   `method: '*'` scoped by target project).

Success = each item either validated (moves from **[VERIFY]** into fact) or
produces a captured failure mode for the
[field notes](option-b-vpcsc-field-notes.md).

---

## 10. Reaching targets outside the perimeter

Not every legitimate target lives inside the perimeter. Three cases, three
mechanisms — decided per target type, not per team:

| Target | Mechanism | DNS | Path |
|---|---|---|---|
| In-perimeter Cloud Run | the design above | wildcard `*.run.app` → restricted VIP | Google backbone |
| Out-of-perimeter Cloud Run / GCP service | **perimeter egress rule** naming the target project | unchanged | backbone, still perimeter-audited |
| Non-Google external API (e.g. partner SaaS) | corporate proxy egress | public resolution | tenant → VPC → VPN/Interconnect → corp proxy → internet |

Two traps worth naming:

- **The DNS-override route is a mirage.** Pointing a more-specific private
  zone at `run.app`'s public IPs is fragile (hardcoded GFE anycast IPs) and
  mostly futile: VPC-SC enforcement is **not VIP-dependent** — traffic
  NAT-egressing from the perimeter project to the *public* `run.app` front
  door is still attributed to the project and still denied. Public front
  door ≠ perimeter bypass. It only "works" via egress that isn't attributed
  to the perimeter (i.e. hairpinned through the corporate proxy) — at which
  point a governed exfiltration path has been deliberately re-opened for
  traffic that never needed to leave Google. Use an egress rule instead.
- **Apigee has no internet route of its own** once VPC-SC is enabled on the
  peering, so the corp-proxy case requires tenant → customer-VPC routing
  (custom route export) and a route-based ("routable"/transparent) proxy —
  Apigee X's support for *explicit* forward-proxy configuration on targets
  is limited. **[VERIFY]** before committing to the corp-proxy pattern for
  Apigee southbound.

The egress-rule mechanism is implemented and testable today in
[`scripts/option2b/`](../scripts/option2b/) (see §9 item 8).

## 11. Open questions (out of PoC scope, needed for production)

- **Northbound TLS**: the PoC curls the instance IP with a `Host` header;
  production `api.example.com` needs a load balancer + managed cert in front
  of the Apigee instance (and the env-group hostname list kept in sync).
- **Multi-region**: the per-env deployment limit is per *region*; a
  second Apigee instance region doubles capacity but adds routing questions.
- **Env-type pricing**: Comprehensive vs Intermediate cost delta at 3
  lifecycle environments — needs a commercial check against the ~$0.50/hr
  PoC baseline.
