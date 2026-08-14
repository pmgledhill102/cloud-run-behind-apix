# The Envoy Sidecar JWT Flow, Explained Three Ways

This document explains the **sidecar variant** of the auth PoC — the request
path where an Envoy `jwt_authn` ingress container enforces the client JWT
instead of in-process middleware — from three angles:

1. **Sequence view** (§3): who talks to whom, in what order, and where a
   request can die.
2. **Wire view** (§4): the actual bytes — headers at every hop, with the
   two tokens decoded, and what each checkpoint reads, checks, and adds.
3. **Checkpoint tables** (§5–6): each layer's single question, its inputs,
   and its rejection signature.

Everything here is grounded in live-verified behaviour: 6/6 pass on the
sidecar tests (E1–E3, part of the standard 14-check
[`scripts/auth/test.sh`](../../scripts/auth/test.sh) suite; re-verified
greenfield 2026-08-03), design doc
[§4.5 / §10 item 6](jwt-enforcement-design.md), and
[field notes §9–11](auth-poc-field-notes.md). Where a value is a PoC stand-in
(hostnames, key ids, timestamps) it is marked as such.

## 1. The cast

| Component | Where it runs | Role in this flow | Key config |
|---|---|---|---|
| `vm-test` | Apigee VPC | Stands in for the API consumer; signs client JWTs with the mock issuer's private key | key never leaves the VM (mimics an external IdP) |
| Apigee X runtime | peered tenant project | Edge gateway: env flow hook → `auth-verify` shared flow (`VerifyJWT`), then proxy `cr-auth-jwt-envoy` | BasePath `/auth-echo-envoy`; deployed as SA `apigee-poc` |
| `cr-idp-mock` | Cloud Run | Serves the issuer's public keys at `/.well-known/jwks.json` | consumed by Apigee `VerifyJWT` only — **not** by Envoy (see §7) |
| Cloud Run front end | Google infra | IAM check on the Google ID token, before any container starts | `--no-allow-unauthenticated`, custom audience `apigee-poc-auth` |
| Envoy ingress container | `cr-auth-echo-envoy`, port 8080 | `jwt_authn` filter: validates the client JWT | issuer/audience/JWKS via env; 0.25 vCPU / 128 Mi |
| app container | same service, `127.0.0.1:8081` | Business logic; JWT middleware **off** (`JWT_MODE=off`) — trusts the sidecar | echoes headers + claims so tests can prove the flow |

Two tokens travel together and answer different questions
(design doc [§2](jwt-enforcement-design.md#2-two-tokens-two-different-questions)):

| | Client JWT | Google ID token |
|---|---|---|
| Question | "who is the end user / client app?" | "is this hop from Apigee?" |
| Header | `Authorization: Bearer …` | `X-Serverless-Authorization: Bearer …` |
| Checked by | Apigee `VerifyJWT`, then Envoy `jwt_authn` | Cloud Run IAM |
| Never checked by | Cloud Run IAM (opaque to it) | Envoy or the app (already consumed by IAM) |

## 2. One-paragraph summary

The client sends its JWT in `Authorization` to Apigee. The environment-level
flow hook runs `VerifyJWT` before any proxy logic — signature against the
IdP's JWKS, `exp`/`nbf`, `iss`, `aud` — so garbage dies at the edge. The
matched proxy then mints a **Google ID token** (audience: the fixed custom
string `apigee-poc-auth`) and puts it in `X-Serverless-Authorization`,
leaving the client JWT byte-for-byte untouched. Cloud Run's front end
validates the Google token (is this Apigee's SA, with `run.invoker`?) before
any container runs, then forwards **both** headers to the ingress container.
Envoy's `jwt_authn` filter re-validates the client JWT against an inline
JWKS — the zero-trust re-check the library variant does in-process — and
proxies to the app over localhost with `Authorization` preserved
(`forward: true`). The app, with its own middleware off, trusts the sidecar
and just does business logic.

## 3. Sequence view

![Envoy sidecar JWT flow — sequence diagram](../diagrams/envoy-sidecar-sequence.svg)

Step by step (numbers match the diagram):

1. **Client → Apigee.** `GET /auth-echo-envoy` to the Apigee instance IP
   with `Host: api.internal.example.com` (selects the env group) and the
   client JWT in `Authorization`.
2. **Flow hook fires first.** `PreProxyFlowHook` → shared flow
   `auth-verify` → policy `VJ-VerifyClientJWT`. This runs before the
   proxy's own PreFlow, on *every* proxy in the environment — a proxy
   author cannot forget it. Checks: algorithm pinned to RS256, signature
   against the JWKS fetched (and cached) from `cr-idp-mock`, `exp`/`nbf`
   with clock skew, `iss = https://idp.poc.internal`,
   `aud = api://apigee-poc`. Any failure → **401 to the client**; the
   request never reaches the proxy, let alone Cloud Run.
3. **Proxy routes, target auth mints.** BasePath `/auth-echo-envoy`
   matches proxy `cr-auth-jwt-envoy`; the TargetEndpoint's
   `<Authentication><GoogleIDToken>` block has Apigee mint a Google ID
   token as the proxy's deploy SA (`apigee-poc`), audience
   `apigee-poc-auth`. `<HeaderName>` steers it into
   `X-Serverless-Authorization`, so the client JWT in `Authorization`
   survives. Minted tokens are cached until near expiry (≈ 0 amortised
   cost).
4. **Apigee → Cloud Run front end** over the PGA restricted VIP. IAM
   validates the Google ID token *before any container starts or bills*:
   Google signature, audience must match the service's custom audience,
   and the SA must hold `roles/run.invoker`. Failure → **403** with no
   container involvement (this is what kills the T3 direct-bypass threat).
   The client JWT is opaque at this layer.
5. **Front end → Envoy (ingress container, :8080).** Both auth headers are
   forwarded — Cloud Run does not strip `X-Serverless-Authorization` after
   consuming it (verified live, a useful bonus: the workload can observe
   the hop identity, not just trust it).
6. **Envoy `jwt_authn`.** Extracts the Bearer token from `Authorization`
   (its default source — `X-Serverless-Authorization` passes through
   untouched), then re-validates: RS256 signature against the **inline**
   JWKS, `iss`, `aud`, `exp`/`nbf`. `/healthz` is the one JWT-exempt route
   (startup probe path, §8). Failure → **401** (expired/missing) or
   **403** (audience mismatch) — note the taxonomy differs from Apigee's
   uniform 401 (§6).
7. **Envoy → app** over `127.0.0.1:8081`, plain HTTP. `forward: true`
   keeps `Authorization` intact so the app could still read claims for
   fine-grained authorization. The app's own middleware is off
   (`JWT_MODE=off`): it trusts the sidecar, tags the response
   `"mode":"off (enforced by ingress container)"`, and echoes which
   headers arrived.
8. **Response** retraces the path: app → Envoy → front end → Apigee →
   client, `200`.

## 4. Wire view — the same request, hop by hop

![Envoy sidecar JWT flow — headers at each hop](../diagrams/envoy-sidecar-headers.svg)

The example data below is one consistent request (PoC values; timestamps
abbreviated, tokens truncated — the base64url prefixes are genuine encodings
of the JSON shown).

### The client JWT (minted on `vm-test`, before hop A)

```text
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InBvYy1rZXktMSJ9  . eyJpc3MiOiJodHRwczovL2lkcC5wb2MuaW50ZXJuYWwi…  . MEUCIQDX…
└─ header ─────────────────────────────────────────────────┘    └─ payload ───────────────────────────────────┘   └─ RS256 sig
```

```json
// header                                   // payload
{                                           {
  "alg": "RS256",   // pinned everywhere      "iss": "https://idp.poc.internal",
  "typ": "JWT",                               "aud": "api://apigee-poc",
  "kid": "poc-key-1" // selects JWKS key      "sub": "test-user",
}                                             "scope": "echo.read",
                                              "iat": 1785436000,
                                              "exp": 1785436300   // iat + 5 min
                                            }
```

### Hop A — client → Apigee

```http
GET /auth-echo-envoy HTTP/1.1
Host: api.internal.example.com
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InBvYy1rZXktMSJ9.eyJpc3MiOi…
```

*Read here:* `Host` picks the env group; the flow hook's `VerifyJWT` reads
`Authorization` (its default source) and checks sig / `exp` / `nbf` / `iss`
/ `aud` against the JWKS from
`https://cr-idp-mock-….run.app/.well-known/jwks.json` (cached on the
message processors). Verified claims land in flow variables
(`jwt.VJ-VerifyClientJWT.claim.*`) — available for routing, quota keys, or
header propagation, though this PoC doesn't use them downstream.

### Hop B — Apigee → Cloud Run front end

```http
GET / HTTP/2                                        ← BasePath /auth-echo-envoy stripped
Host: cr-auth-echo-envoy-abc123xyz-ew.a.run.app     ← target's run.app host (PoC-shaped hash)
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InBvYy1rZXktMSJ9.eyJpc3MiOi…
X-Serverless-Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjZmNzI1NDEw…
```

Two changes, one non-change:

- **Added** — `X-Serverless-Authorization` carries the freshly minted (or
  cache-hit) Google ID token. Decoded payload:

  ```json
  {
    "iss": "https://accounts.google.com",
    "aud": "apigee-poc-auth",            // CUSTOM audience — fixed string, not the service URL
    "azp": "1046…",
    "email": "apigee-poc@PROJECT_ID.iam.gserviceaccount.com",
    "email_verified": true,
    "iat": 1785436010,
    "exp": 1785439610                    // ~1 h; Apigee caches until near expiry
  }
  ```

- **Rewritten** — request line and `Host`: the proxy strips its BasePath
  and targets the service URL.
- **Unchanged** — `Authorization` is byte-identical to hop A. This is the
  whole point of `<HeaderName>X-Serverless-Authorization</HeaderName>`:
  without it, Apigee's `GoogleIDToken` block would clobber the client JWT.

### Hop C — Cloud Run front end → Envoy (ingress container)

```http
GET / HTTP/1.1
Host: cr-auth-echo-envoy-abc123xyz-ew.a.run.app
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InBvYy1rZXktMSJ9.eyJpc3MiOi…
X-Serverless-Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjZmNzI1NDEw…
```

*Checked before this hop happens:* IAM validated the Google ID token —
Google signature, `aud` equals the custom audience `apigee-poc-auth`
(accepted because the service was deployed with
`--add-custom-audiences=apigee-poc-auth`), and principal `apigee-poc` holds
`run.invoker`. No container ran yet when that decision was made. Both
headers are then forwarded as-is; the Google token has already done its job
but remains observable.

*Checked on arrival:* Envoy's `jwt_authn` re-validates the client JWT from
`Authorization` — RS256 vs the **inline** JWKS (`JWKS_JSON` env var, §7),
`iss = https://idp.poc.internal`, `aud = api://apigee-poc`, `exp`/`nbf`.

### Hop D — Envoy → app (localhost)

```http
GET / HTTP/1.1                                      ← 127.0.0.1:8081, plain HTTP inside the instance
Host: cr-auth-echo-envoy-abc123xyz-ew.a.run.app
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InBvYy1rZXktMSJ9.eyJpc3MiOi…   ← forward: true
X-Serverless-Authorization: Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IjZmNzI1NDEw…                     ← passed through untouched
x-request-id: 7f9c…                                 ← Envoy housekeeping
```

`forward: true` in the provider config is why `Authorization` survives —
`jwt_authn` strips the token by default after a successful check. Keeping
it means the app can still decode claims for fine-grained authorization
(the one job no gateway or sidecar can ever take over).

### The response (app → … → client)

```json
{
  "service": "cr-auth-echo-envoy",
  "hostname": "…",
  "headers_seen": {
    "authorization": true,              ← proves forward: true worked
    "x_serverless_authorization": true  ← proves Cloud Run forwarded the hop identity
  },
  "jwt": { "valid": true, "mode": "off (enforced by ingress container)" },
  "jwks_source": "env"                  ← inline JWKS, not a URL fetch (§7)
}
```

`200` all the way back. `test.sh` E1 asserts on `"mode":"off` and
`"authorization":true` — together they prove the sidecar (not the app) did
the enforcement and the JWT still reached the app.

## 5. What each checkpoint reads, checks, and adds

| # | Layer | Question answered | Reads | Checks | Adds / changes | On failure |
|---|---|---|---|---|---|---|
| 1 | Apigee `VerifyJWT` (env flow hook) | "Is this a well-formed, live token from our issuer, for us?" | `Authorization` | RS256 (pinned) sig vs `cr-idp-mock` JWKS (cached) · `exp`/`nbf` · `iss` · `aud` | claims → flow variables | 401, fault `steps.jwt.*` |
| 2 | Apigee TargetEndpoint `Authentication` | *(not a check — a mint)* | — | — | `X-Serverless-Authorization: Bearer <Google ID token>` (aud `apigee-poc-auth`, SA `apigee-poc`, cached ~1 h); rewrites path + `Host` | — |
| 3 | Cloud Run IAM (front end) | "Is this hop from Apigee's SA?" | `X-Serverless-Authorization` | Google sig · `aud` = custom audience · caller has `run.invoker` | consumes the Google token but still forwards the header | 403, before any container runs |
| 4 | Envoy `jwt_authn` (ingress container) | "Is the client JWT valid?" (zero-trust re-check) | `Authorization` | RS256 sig vs inline JWKS · `iss` · `aud` · `exp`/`nbf` | none (`forward: true` = keep header); routes to `127.0.0.1:8081` | 401 or 403 (see §6) |
| 5 | App middleware | *(off — trusts the sidecar)* | headers, for echo only | none (`JWT_MODE=off`) | response body | — |

Defence in depth in one line: **layer 3 answers "from Apigee?", layers 1
and 4 answer "valid user?" — and a request must pass all of them.** A
stolen client JWT replayed directly at the service dies at layer 3 with no
container ever starting; a compromised or misconfigured Apigee env still
can't push an invalid client JWT past layer 4.

## 6. Rejection matrix — the same bad tokens, layer by layer

From the live test runs (`test.sh` Tests 3–4 and E2). "Direct"
means bypassing Apigee with a valid Google ID token in
`X-Serverless-Authorization`, so Cloud Run IAM is satisfied and Envoy is
isolated as the deciding layer:

| Bad input | Path | Dies at | Code | Observable signature |
|---|---|---|---|---|
| Expired client JWT | via Apigee | flow hook `VerifyJWT` | 401 | fault `steps.jwt.TokenExpired` |
| Wrong-audience client JWT | via Apigee | flow hook `VerifyJWT` | 401 | fault `steps.jwt.InvalidClaim` |
| No client JWT | via Apigee | flow hook `VerifyJWT` | 401 | fault `steps.jwt.FailedToResolveVariable` |
| No Google ID token (any client JWT) | direct to `run.app` URL | Cloud Run IAM | 403 | request log `run.googleapis.com%2Frequests`, "The request was not authenticated" — no container ran |
| Expired client JWT | direct, IAM satisfied | Envoy `jwt_authn` | 401 | body `Jwt is expired` |
| Wrong-audience client JWT | direct, IAM satisfied | Envoy `jwt_authn` | **403** | body `Audiences in Jwt are not allowed` |
| No client JWT | direct, IAM satisfied | Envoy `jwt_authn` | 401 | body `Jwt is missing` |

The gotcha (field notes §11): **the layers do not share a rejection
taxonomy.** Apigee `VerifyJWT` and the library middleware return 401 for
all three client-JWT failures; Envoy returns 403 for an audience mismatch.
Alerting rules and client retry logic must not assume "invalid JWT ⇒ 401"
uniformly. Note also that on the normal (via-Apigee) path Envoy's checks
are unreachable for these cases — the flow hook rejects first; Envoy's
re-validation only becomes the deciding layer for traffic that didn't
traverse Apigee, which is exactly the zero-trust scenario it exists for.

## 7. Why Envoy's JWKS is inline (and Apigee's is a URL)

Two different JWKS delivery mechanisms are in play, deliberately:

- **Apigee** fetches `https://cr-idp-mock-…/.well-known/jwks.json` at
  policy evaluation time (`<JWKS uri>`), cached on the message processors.
  Reachable because Apigee's tenant DNS resolves `*.run.app` to the
  restricted VIP.
- **Envoy** gets the key material **inline** via the `JWKS_JSON` env var,
  rendered into `local_jwks.inline_string` at container start. A
  remote-JWKS config would fail here: `cr-auth-echo-envoy` has no VPC
  egress, and an `ingress=internal` JWKS service is unreachable from a
  no-VPC-egress Cloud Run consumer — the fetch hits the public frontend
  and 404s (field notes, §7.4 sharpening). Inline-via-env is the PoC's
  working stand-in for the design's push model (§7.4: the platform pushes
  keys to sidecars as config; rotation = config redeploy, and in
  production that means **two overlapping keys** in the JWKS during
  rotation so in-flight tokens survive the cutover).

Same trade-off, restated: Apigee's cache refreshes on a TTL with no
service involvement; Envoy's keys are pinned per revision — key rotation
touches every service's config, which is the standing operational cost of
any sidecar/library layer (design doc §7.2).

## 8. Startup: how two containers become one ready instance

Cold start is where sidecars earn a bad reputation, so the topology
matters (design doc §4.5, verified live):

```text
T0 ──────────────────────────────────────────────▶ time
 │
 ├─ envoy container:  envsubst → envoy up (~0.6 s) ─┐
 │                                                  │  startup probe: GET :8080/healthz
 ├─ app container:    JWKS parse → listen :8081 ────┤  (JWT-exempt route, 1 s period)
 │                                                  ▼
 │                        probe passes only when BOTH are up —
 │                        it traverses Envoy → app, so readiness
 └──────────────────────  gates on the full path         ────────▶ instance serves
```

- **No `--depends-on`** — both containers start at T0. A serialized
  topology was measured at a flat **+0.65 s**; in parallel, Envoy's ~0.6 s
  init overlaps the app's own boot, so the marginal cold-start cost is
  ≈ 0 for any app slower than Envoy itself (verified with a heavy-app
  emulation via `APP_START_DELAY`).
- The probe's path is the reason `/healthz` is JWT-exempt in
  `envoy.yaml.tmpl` — first-match rule ordering, before the catch-all
  `requires: poc-idp` rule. PoC shortcut: the echo app answers any path;
  production would pin this to a dedicated handler.
- **Size the sidecar explicitly**: per-container defaults (1 vCPU/512 Mi)
  silently double the instance footprint. 0.25 vCPU / 128 Mi ran the whole
  test suite; the cost was ≈ +7 ms p50 on the RS256 verify vs +3 ms at
  1 vCPU (field notes, "sidecar vs library numbers").

### 8.1 Fleet view — what "one sidecar" multiplies into

Everything above describes a single instance. The operational question is
what the same picture looks like once Apigee is fanning out across several
services, each of which the autoscaler has scaled independently.

Two diagrams cover this, and they are meant to be read in order — the same
snapshot at two zoom levels. Start with the shape:

![Request fan-out — Apigee path-routes to 3 Cloud Run services, Envoy sidecar + app per instance](../diagrams/fanout-services.svg)

One client, one Apigee instance path-routing to three services, each
autoscaled independently, every instance a two-container pod. That is the
whole mechanism, and for most conversations it is the diagram you want.

The second adds the auth machinery and the numbers that follow from it —
same nine instances, annotated:

![Sidecar fan-out at scale — the same snapshot with tokens, sizing and headroom](../diagrams/fanout-at-scale.svg)

Instance counts in both are illustrative (the PoC runs one service at
`--max-instances=5`); the arithmetic they make visible is not:

- **You never deploy the Envoy fleet — the autoscaler does.** Nine
  instances means nine Envoy processes, each with its own config and its
  own copy of the JWKS. The count moves with load, per service, and no
  deploy step corresponds to it.
- **Sidecar sizing is a fleet multiplier, not a per-service one.** At the
  PoC's 0.25 vCPU / 128 Mi that is +2.25 vCPU / +1.1 GiB across nine
  instances; on per-container defaults (1 vCPU / 512 Mi) the same nine cost
  +9 vCPU / +4.5 GiB. This is §8's "size the sidecar explicitly" bullet,
  seen from the fleet end.
- **Verification count scales with the fan-out.** The client JWT is
  verified once at the Apigee edge and again in every Envoy it reaches —
  1 + N for a single logical request path. That redundancy is the point
  (it is what closes the direct-bypass threat, §6), but it is redundancy
  you pay for per instance.
- **There is no shared control plane.** A JWKS rotation or an
  issuer/audience change reaches those Envoys only as a new revision on
  each service. That is the standing trade against enforcing once at the
  edge — design doc
  [§4.5](jwt-enforcement-design.md).
- **Scale-to-zero cuts both ways.** `min-instances 0` means no instance, no
  Envoy, no cost — and the first call after idle pays cold start for *both*
  containers, since the startup probe traverses Envoy → app (§8).

## 9. Seeing it live

```bash
export PROJECT_ID=<your-project>   # required — no default

./scripts/auth/setup.sh     # keypair, cr-idp-mock, shared flow + flow hook, BOTH variants
./scripts/auth/test.sh      # Tests 1-5 plus E1 happy path · E2 Envoy-isolated rejections · E3 latency vs library
./scripts/auth/teardown.sh  # remove both variants, shared flow, flow hook
```

Key sources if you want to trace the config behind each hop:

- Envoy filter chain and routes: [`scripts/auth/envoy/envoy.yaml.tmpl`](../../scripts/auth/envoy/envoy.yaml.tmpl)
- Proxy bundle + target `Authentication` block: [`scripts/auth/setup.sh`](../../scripts/auth/setup.sh) `deploy_auth_proxy()`
- `VerifyJWT` policy + flow hook attach: [`scripts/auth/setup.sh`](../../scripts/auth/setup.sh) step 6
- App echo behaviour / `JWT_MODE=off`: [`scripts/auth/container/main.go`](../../scripts/auth/container/main.go)
- Diagram sources: [`envoy-sidecar-sequence.drawio`](../diagrams/envoy-sidecar-sequence.drawio),
  [`envoy-sidecar-headers.drawio`](../diagrams/envoy-sidecar-headers.drawio),
  [`fanout-services.drawio`](../diagrams/fanout-services.drawio),
  [`fanout-at-scale.drawio`](../diagrams/fanout-at-scale.drawio)
