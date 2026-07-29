# AuthN/AuthZ Enforcement: External-Issuer JWTs with Apigee + Cloud Run

**Status: paper design.** This document works out *where* token checks
(signature, expiry, issuer, audience, scopes, fine-grained authorization)
should be enforced when the API platform is Apigee → PGA → Cloud Run rather
than GKE + Istio. Claims marked **[VERIFY]** are unproven — they are the
target list for a future PoC (tests will live in `scripts/auth/`, tracked
separately).

**Scope and assumptions:**

- An **external auth system** (in-house IdP) issues JWTs to callers via a
  standard OAuth2/OIDC flow. The platform does not mint end-user tokens.
- Connectivity is Option B/2b: Apigee proxies reach Cloud Run over **PGA**
  inside a **VPC-SC perimeter** — but the perimeter is **wide** (spans many
  projects in the organisation). Perimeter membership must NOT be treated as
  authorization: an unrelated workload inside the perimeter can reach
  `*.run.app` over PGA and bypass Apigee entirely (§6).
- Target scale is **~1000 Cloud Run services**, so §7 treats operational
  concerns (ownership, patch propagation) as first-class design inputs, not
  afterthoughts.
- Builds on [path-routing-at-scale.md §4](../path-routing-at-scale.md)
  (the two auth scenarios) — this doc goes deeper on *where each individual
  check runs* and *who operates the machinery*.

---

## 1. The job Istio was doing

In a GKE world the answer is one word: the sidecar. It is worth being precise
about what that one component did, because every one of these jobs still has
to land somewhere:

| # | Check | Istio mechanism |
|---|---|---|
| 1 | JWT signature vs issuer JWKS (fetched + cached) | `RequestAuthentication` |
| 2 | Expiry (`exp`) / not-before (`nbf`) | `RequestAuthentication` |
| 3 | Issuer (`iss`) allow-list | `RequestAuthentication` |
| 4 | Audience (`aud`) match | `RequestAuthentication` |
| 5 | Scopes/claims → operation (method + path) | `AuthorizationPolicy` |
| 6 | Reject *before* app code runs | sidecar sits in the pod's network path |
| 7 | Uniform across every workload, no app-code change | injected at deploy; config is cluster-level |
| 8 | Centrally patchable | control-plane upgrade + pod restart |
| 9 | Workload-to-workload (hop) identity | mTLS / SPIFFE |

Rows 1–5 are token checks. Rows 6–9 are the *properties* that made the
sidecar model attractive: enforcement in the traffic path, uniformity,
central ownership, and a separate hop-identity layer. Apigee + Cloud Run has
no single component with all nine properties — the design below distributes
them across layers and then asks what that costs operationally.

## 2. Two tokens, two different questions

The design keeps two credentials rigorously separate; most confusion in this
space comes from conflating them:

| | Client JWT | Google ID token |
|---|---|---|
| Issued by | in-house auth system | Google (minted by Apigee per request) |
| Answers | "who is the **end user / client app**, what may they do?" | "is this hop **from Apigee**?" |
| Carried in | `Authorization: Bearer …` | `X-Serverless-Authorization` (to avoid clobbering — see below) |
| Validated by | Apigee (`VerifyJWT`) and/or the service | Cloud Run's front end (IAM), before any container runs |
| Lifetime | issuer policy (minutes–hours) | ~1 h, minted fresh by Apigee |

The Google token authenticates the *previous hop*; the client JWT
authenticates the *principal*. Neither substitutes for the other: a valid
Google token says nothing about the end user, and a valid client JWT says
nothing about whether the request actually came through Apigee (anyone
in-perimeter can replay a captured JWT directly at the service if only the
JWT is checked).

**Header collision:** Apigee's `<Authentication><GoogleIDToken>` block writes
`Authorization` by default — clobbering the client JWT. Cloud Run accepts the
Google token in `X-Serverless-Authorization` for exactly this case, and
Apigee's `<HeaderName>` element points the minted token there, leaving the
client JWT untouched in `Authorization`. **[VERIFY]** — highest-priority PoC
item; the whole combined design rests on it.

## 3. Threat model

What the layered design must defeat:

| ID | Threat | Primary control |
|---|---|---|
| T1 | External caller with no/garbage token | Apigee `VerifyJWT` at the edge |
| T2 | Expired, wrong-audience, or out-of-scope (but well-formed) JWT | Apigee `VerifyJWT` + product scope check |
| T3 | **In-perimeter workload calls the service directly over PGA, bypassing Apigee** (valid stolen JWT or no JWT) | Cloud Run IAM — `run.invoker` restricted to the proxy SA (§6) |
| T4 | A service team ships a service with auth middleware missing/misconfigured | Cloud Run IAM again — the service is still closed at the Google layer; conformance checks (§7.5) |
| T5 | Compromised neighbouring service pivots east-west | per-service IAM (services do not share invoker grants) + service-side authz |
| T6 | Issuer key compromise / rotation mishap | operational: rotation runbook, JWKS cache TTL bounds (§7.4) |

T3 is the pivotal one: it is why "do all the checks in Apigee" is
insufficient no matter how good the Apigee policy is, and it can only be
closed by a control that Cloud Run itself enforces.

## 4. Enforcement point catalogue

What each available component *can* do, and where it is blind.

### 4.1 Apigee — `VerifyJWT` in a shared flow, attached via flow hooks

The natural home for checks 1–5 on the north-south path:

- `VerifyJWT` validates signature against the issuer's **JWKS** (`<JWKS
  uri>` with built-in caching), `exp`/`nbf` (with configurable clock skew),
  `iss`, `aud`, and arbitrary additional claims.
- Verified claims land in flow variables (`jwt.{policy}.claim.*`) for
  routing, quota keys, and header propagation.
- **Scope → operation** mapping: Apigee's native model is OAuth scopes on
  **API products**; with an external issuer the equivalent is a shared-flow
  step comparing the JWT `scope` claim against the required scope for the
  matched flow (per-operation attribute). Coarse-grained ("does this token
  carry `disputes.read`?"), not resource-grained.
- Packaged as a **shared flow** attached via **environment-level flow
  hooks**, it runs on *every* proxy in the environment — individual proxy
  teams cannot forget it or opt out. This is the closest analogue to
  Istio's "uniform, centrally owned" property (rows 7–8), and it is the
  single biggest operational win in the whole design: one deployment
  updates the fleet with **zero service redeploys** (§7.2).
- Also the right place for **SpikeArrest / Quota** keyed on a JWT claim
  (client id / subject), and for auditing (who called what).

**Blind spot:** only traffic that traverses Apigee. Contributes nothing
against T3. Apigee is a *policy* enforcement point, not a *reachability*
control.

### 4.2 Cloud Run IAM — the platform-enforced service boundary

`--no-allow-unauthenticated` + `roles/run.invoker` granted **only** to the
Apigee proxy's service account. Cloud Run's front end (GFE-side, before any
container starts or bills) validates the Google ID token in
`Authorization` or `X-Serverless-Authorization`.

- The **only per-service control the platform enforces regardless of what
  the service team ships**. Closes T3 and T4 — Istio row 6's "reject before
  app code" property, for the hop-identity layer.
- Cannot see the client JWT at all. It answers "is this Apigee?", never
  "is this Alice, with scope X?".
- Plumbing per target (from [field notes §3](../option-b-vpcsc-field-notes.md)):
  audience must match the service URL exactly, proxy SA needs `run.invoker`
  per service, Apigee service agent needs `tokenCreator` on the SA. At 1000
  services this is automation territory, not console territory. **Custom
  audiences** (`--add-custom-audiences`) let every TargetEndpoint use one
  fixed audience string instead of per-service URLs — worth **[VERIFY]**
  as a scale simplification.

### 4.3 Network layer — ingress + VPC-SC (outer ring only)

`--ingress=internal` plus the perimeter keeps the internet out and provides
data-exfiltration control. By stated assumption it is **not** an
authorization mechanism here: the perimeter is wide, so "in-perimeter" ≈
"somewhere in the org". Keep it, count it as defence in depth, and design
as if any org workload can open a TCP connection to any service.

### 4.4 In-service middleware — shared per-language library

A platform-owned library (JWT validation + claims → request context +
fine-grained authorization helpers) wired into every service's framework
stack:

- The **only** layer that can do **fine-grained / resource-level
  authorization**: "Alice may read *this* dispute because her `customer_id`
  claim matches the row". No gateway or sidecar can ever do this — it
  requires joining claims with application data. This layer exists in
  *every* pattern; the design choice is only how much *validation* it also
  repeats.
- Zero-trust posture: re-validating signature/expiry in-service costs
  little (JWKS cached in-process) and removes "trust whatever headers
  arrive" as a failure class.
- **Operational cost is the story**: one library per language × N languages,
  propagated by rebuild-and-redeploy of every consuming service (§7.2).

### 4.5 Cloud Run sidecar — the literal Istio analogue

Cloud Run supports **multi-container revisions with an ingress container**:
an Envoy (with the `jwt_authn` filter) or ESPv2 container receives traffic
and forwards to the app container over localhost. This reproduces Istio
rows 1–6 almost exactly, without app-code changes and identically across
languages.

- Enforcement is in the revision's traffic path — an app team cannot skip
  it *if* deploy tooling injects it (unlike Istio, there is no
  cluster-level injection: the "injection" point is the deploy pipeline,
  which becomes part of the trust story).
- One image to own instead of N libraries — but images are **pinned per
  revision**, so a patched sidecar still requires redeploying every
  service (§7.2). Fine-grained authz still lives in app code regardless.
- **[VERIFY]** ingress-container + JWT-filter pattern on Cloud Run,
  including cold-start and latency impact.

### 4.6 Considered and rejected

| Component | Why not |
|---|---|
| **IAP** | Built around Google identities / Workforce Identity Federation; the requirement is an in-house issuer's JWT as the primary credential. Federating everything through Google identity is a bigger architectural change than this design assumes. |
| **Cloud Armor** | No JWT validation capability; also sits on external LBs, which this topology doesn't use. |
| **API Gateway / ESPv2 as a separate proxy layer** | A second gateway product alongside Apigee duplicates the edge; ESPv2 only makes sense here in the §4.5 sidecar position. |
| **mTLS Apigee→Cloud Run** | Google's front end terminates TLS for `run.app`; custom client certs can't reach the service. Hop identity is tokens (Google ID token), not certs. |

## 5. The checks matrix

Where each check *can* run (✓), where it *cannot* (✗), and where the design
says it **must** run (bold):

| Check | Apigee (shared flow) | Cloud Run IAM | Sidecar | App middleware |
|---|---|---|---|---|
| Client JWT signature vs JWKS | **✓ must** | ✗ | ✓ | ✓ defence in depth |
| Client JWT `exp` / `nbf` | **✓ must** | ✗ | ✓ | ✓ defence in depth |
| Client JWT `iss` | **✓ must** | ✗ | ✓ | ✓ defence in depth |
| Client JWT `aud` (API audience) | **✓ must** | ✗ | ✓ | ✓ defence in depth |
| Scopes → operation (coarse authz) | **✓ must** (product/flow mapping) | ✗ | ✓ (path-level) | ✓ |
| Fine-grained / resource authz | ✗ | ✗ | ✗ | **✓ only possible here** |
| Hop authentication ("came via Apigee") | ✗ (it *is* the hop) | **✓ must** | partial¹ | partial¹ |
| Rate limiting / quota per client | **✓ must** | ✗ | ✓ crude | ✗ practical |
| Revocation / issuer deny-list | ✓ best placed² | ✗ | ✓ | ✓ |
| Audit of authn decisions | **✓** + | ✓ (audit logs on denial) | ✓ | ✓ |

¹ A sidecar or app *can* also validate the Google ID token from
`X-Serverless-Authorization`, but Cloud Run IAM has already done so
platform-side; re-checking adds little.
² If the issuer publishes revocation (introspection endpoint or short-TTL
deny-list), the edge is the one place that check runs once per request
rather than per service. With short-lived access tokens, revocation may
reduce to "keep TTLs short" — issuer-policy decision, not platform.

Reading of the matrix: **every token check lands in Apigee; the bypass
problem lands on Cloud Run IAM; fine-grained authz lands in the app; the
open design choice is only whether validation is *repeated* service-side by
a library (§4.4) or a sidecar (§4.5).**

## 6. Closing the direct-PGA bypass (T3)

The question posed at the outset: if checks live in Apigee, what stops
someone inside the (wide) perimeter calling `https://svc-xyz.run.app`
directly? Ranked by strength:

1. **Cloud Run IAM (`--no-allow-unauthenticated`, invoker = proxy SA
   only)** — platform-enforced, per-service, identity-based. A direct
   caller without a Google ID token minted from *that specific SA* gets a
   403 from Cloud Run's front end; the container never runs. This is the
   design's answer. It also means the **pure scenario-B posture
   (`--allow-unauthenticated` + JWT-only, from path-routing §4) is ruled
   out at this trust level** — it leaves every service one forgotten
   middleware away from open-to-the-org (T4).
2. `--ingress=internal` — keeps the internet out; does nothing against
   in-perimeter callers.
3. VPC-SC — org-boundary control; wide by assumption.
4. Obscurity of `run.app` URLs — not a control (URLs leak via logs, DNS,
   config repos).

Residual risk after (1): a caller who can impersonate the Apigee proxy SA
(has `tokenCreator` on it) can bypass Apigee's policy checks. That
concentrates the review surface onto **IAM grants on one SA** (or a few,
per environment) — auditable, alertable, and far smaller than "anything in
the perimeter". Optionally segment proxy SAs per domain so a compromise
doesn't unlock all 1000 services. **[VERIFY]** the 403-before-container
behaviour and its audit-log signature from an in-perimeter VM.

## 7. Operating this at ~1000 services

### 7.1 Ownership model

| Actor | Owns | Security-fix blast radius |
|---|---|---|
| **Identity team** | The external issuer, signing keys, JWKS endpoint, token TTL/claims schema, rotation calendar | Issuer-side only (until a claim schema change — that ripples everywhere) |
| **Apigee platform team** | The auth **shared flow**, flow-hook attachment, scope→operation mapping data, quota policy | Redeploy one shared flow per environment |
| **App platform team** | Middleware libraries (per language) and/or the sidecar image; base images; deploy tooling that injects/pins them; conformance checks | Rebuild/redeploy up to 1000 services |
| **App teams (~50 domains)** | Fine-grained authz logic, correct middleware wiring, service IAM posture (from templates) | Their own services |

The wrong ownership answer at this scale is "each app team maintains its own
JWT code" — 1000 hand-rolled validators is 1000 places for the same CVE.

### 7.2 Patch propagation — the deciding operational comparison

What happens when a security fix (JWT library CVE, algorithm-confusion
class bug, new required claim) must roll out:

| Mechanism | Update action | Service redeploys needed | Fleet-wide latency | Failure isolation |
|---|---|---|---|---|
| **Apigee shared flow** | deploy new shared-flow revision per env | **0** | minutes | one change affects all traffic at once — needs canary env / preprod soak |
| **Sidecar image** | publish patched image | **all ~1000** (images pin per revision) | days–weeks without automation | per-service rollout, can canary |
| **Per-language library** | publish N library versions | **all ~1000**, gated on each team's rebuild | weeks–months tail without forcing functions | per-service |
| Cloud Run platform / IAM | Google's job | 0 | n/a | n/a |

Consequences:

- **Put every check that can live in the shared flow, in the shared flow.**
  It is the only mechanism with Istio-like central patchability.
- Any service-side mechanism (library *or* sidecar) makes "redeploy the
  fleet" a routine platform operation. That machinery — config-as-code
  service definitions, CI fan-out, staged rollout, and a dashboard of "who
  is on which middleware/sidecar version" — is a **prerequisite**, not a
  nice-to-have. (Istio had the same property hidden inside "restart the
  pods"; Cloud Run just has no `kubectl rollout restart` for 1000
  services.)
- Version skew is therefore permanent background state. The conformance
  check (§7.5) must report versions, and the platform team needs an agreed
  "minimum supported middleware version" policy with teeth (CI gate).

### 7.3 Choosing library vs sidecar for the service-side layer

| Driver | Favours |
|---|---|
| Polyglot estate (many languages) | **Sidecar** — one image vs N libraries |
| Mostly one/two languages with strong shared framework | **Library** — no extra hop, no second container's memory/CPU, simpler local dev |
| Fine-grained authz complexity (claims deep in business logic) | Library involved either way — sidecar never removes the in-app layer (§5), it only de-duplicates *validation* |
| Cold-start / latency sensitivity | Library (sidecar adds a proxy hop + container start) **[VERIFY]** magnitude |
| Trust in deploy tooling to inject uniformly | Sidecar needs it; library needs the same discipline via build tooling |

Given Cloud Run IAM already guarantees requests came through Apigee (which
performed full validation), the service-side layer is defence in depth plus
claims extraction — not the primary gate. That weakens the case for paying
the sidecar's per-request price and operational surface: **default
recommendation is the library**, with the sidecar as the fallback if the
estate is too polyglot for library coverage. Revisit if IAM closure cannot
be guaranteed for some service class.

### 7.4 JWKS and key rotation

- Both Apigee (per instance) and every service (per container) cache the
  issuer JWKS. Cache TTLs bound two things: how fast a *new* signing key is
  usable (rotation) and how long a *revoked* key keeps verifying
  (compromise). Agree TTLs with the identity team; rotation runbook =
  publish new key in JWKS → wait > max cache TTL → start signing with it →
  retire old key after token max-age.
- **Egress**: the JWKS URL is an external endpoint. Apigee *and* every
  Cloud Run service (if service-side validation is on) must be able to
  fetch it through the egress allow-list — one more entry in the
  [governed allow-list](../option-b-vpcsc-field-notes.md), and a good
  argument for an **internally mirrored JWKS** (a tiny Cloud Run service
  the platform team owns) so 1000 services don't each need external
  egress. Mirror then becomes a critical dependency with an owner, SLO,
  and fail-closed semantics. **[VERIFY]** JWKS fetch behaviour under the
  perimeter/egress setup.
- Issuer outage: JWKS caches mean validation survives *brief* outages;
  policy question is fail-closed (reject when JWKS unrefreshable and keys
  expired) — the answer should be fail-closed, stated up front.

### 7.5 Enforcement of the enforcement

At 1000 services, "the design says IAM-closed" is worthless without
verification that reality matches:

- **Flow hooks** make the Apigee side structural — proxies cannot skip the
  shared flow. Nothing equivalent exists for Cloud Run flags, so:
- **Conformance-as-code**: a periodic audit (Cloud Asset Inventory query or
  script) asserting for every service: `--no-allow-unauthenticated`, no
  `allUsers`/broad invoker bindings, `ingress=internal`, expected SA
  pattern, middleware/sidecar version ≥ minimum. Violations page the
  platform team. This audit is a prime candidate for the first tests in
  `scripts/auth/`.
- **Org policy** where possible: e.g. Domain Restricted Sharing blocks
  `allUsers` grants org-wide (kills accidental
  `--allow-unauthenticated`-equivalent IAM). **[VERIFY]** which postures
  can be made *preventive* via org policy vs merely *detective* via audit.
- Deploy templates: app teams deploy from golden pipeline templates that
  set the flags and inject the middleware — conformance drift then implies
  someone went around the pipeline, itself a signal.

### 7.6 Observability of auth decisions

| Failure | Where it appears |
|---|---|
| Bad/expired/out-of-scope JWT | Apigee: 401/403 in analytics + policy fault variables; alert on rate spikes (credential-stuffing signal) |
| Direct-call attempt (T3) | Cloud Run request log: 403, `severity=WARNING`, no container instance started; IAM denial in audit logs **[VERIFY]** exact signature |
| Service-side validation failure while Apigee passed it | Service logs — should be **near-zero**; non-zero means skew between edge and service validation configs (alert) |
| JWKS refresh failures | Apigee policy faults / middleware logs — leading indicator of a looming fail-closed event |

## 8. Resulting shape (recommended baseline)

```
Client ──JWT──► Apigee env (flow hook → auth shared flow)
                 │  VerifyJWT: sig, exp/nbf, iss, aud   ← T1, T2
                 │  scope→operation check, quota
                 │  mint Google ID token ─► X-Serverless-Authorization
                 │  client JWT untouched ─► Authorization
                 ▼
               PGA / restricted VIP  (perimeter = outer ring only)
                 ▼
Cloud Run front end: IAM validates Google token            ← T3, T4
  (--no-allow-unauthenticated, invoker = proxy SA, ingress=internal)
                 ▼
Service: middleware re-validates JWT (defence in depth),
         extracts claims → fine-grained resource authz     ← T5 + row 5's
         (the check nothing upstream can ever do)             deep half
```

- Apigee shared flow = the Istio `RequestAuthentication` + coarse
  `AuthorizationPolicy`, centrally patchable, structurally unskippable.
- Cloud Run IAM = the reachability gate Istio got from mTLS — and the
  answer to "why can't someone just call it over PGA".
- App middleware (library, not sidecar, by default) = fine-grained authz +
  zero-trust revalidation.
- Everything service-side rides on fleet-redeploy automation and
  conformance auditing, which are part of the design, not ops detail.

## 9. Open questions / PoC target list

1. **[VERIFY]** `X-Serverless-Authorization` + `Authorization` combined
   pattern end-to-end (Google token accepted, client JWT arrives intact).
2. **[VERIFY]** Direct PGA call from an in-perimeter VM → 403 before
   container start; capture the audit-log signature for detection.
3. **[VERIFY]** `VerifyJWT` shared flow via env flow hook: rejects expired
   / wrong-`aud` / missing-scope tokens; measure added latency; JWKS fetch
   + cache behaviour through the egress allow-list.
4. **[VERIFY]** Custom audiences (`--add-custom-audiences`) to collapse
   per-service audience plumbing to one string.
5. **[VERIFY]** Sidecar (ingress-container Envoy `jwt_authn`) variant:
   works on Cloud Run? cold-start and latency cost vs library?
6. **[VERIFY]** Preventive controls: which of the §7.5 postures can org
   policy enforce vs audit-only?
7. Open: proxy-SA segmentation granularity (one per env vs per domain) —
   trade blast radius against IAM-plumbing volume.
8. Open: issuer claims schema — is there a stable tenant/subject claim the
   fine-grained layer can rely on across all 1000 services?
