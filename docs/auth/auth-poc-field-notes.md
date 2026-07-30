# Field Notes: Auth PoC Live Run — JWT Enforcement Layers

**Audience:** teams implementing the layered JWT enforcement design
([jwt-enforcement-design.md](jwt-enforcement-design.md)) on
Apigee → PGA → Cloud Run.

**What this is:** the first live end-to-end run of
[`scripts/auth/`](../../scripts/auth/README.md) (issue #34), executed
2026-07-30 on a **greenfield** sandbox (`auth-test`) — nothing pre-existing,
so the run also re-validated options 2 and 2b from zero. As with
[option-b-vpcsc-field-notes.md](../option-b-vpcsc-field-notes.md), failures
get equal billing: every error below was hit for real, every fix validated
live and committed.

**Headline:** the design's §9 baseline works end to end, 8/8 assertions:

```text
Test 1 [PASS]  JWKS served over PGA (allow-unauth + ingress=internal)
Test 2 [PASS]  client JWT validated end-to-end (VerifyJWT + middleware)
Test 2 [PASS]  client JWT arrived intact in Authorization (§10 item 1)
Test 3 [PASS]  expired token   → 401 at the Apigee edge
Test 3 [PASS]  wrong-aud token → 401 at the Apigee edge
Test 3 [PASS]  missing token   → 401 at the Apigee edge
Test 4 [PASS]  direct PGA call, no token → 403 before the container
Test 4 [PASS]  direct PGA call, valid client JWT → still blocked
```

Plus the two informational probes: `X-Serverless-Authorization` **is
forwarded to the container** (not stripped), and a Google ID token from a
broadly-granted SA succeeds directly (200) — the invoker-hygiene residual
risk of §6, demonstrated.

## Corrections found by the live run (in run order)

### 1. `setup-iam.sh`: IAM propagation race (fixed)

First project-level binding seconds after SA creation failed with
`INVALID_ARGUMENT: Service account ... does not exist` — `describe`
succeeds before the policy backend sees the SA. Fixed with a retry wrapper
(6 × 10 s) on all mandatory bindings; the freshly-minted default compute SA
can race identically.

### 2. `setup-slow.sh`: org `state=ACTIVE` ≠ org creation finished (fixed)

On a greenfield project the org reports `ACTIVE` while the creation LRO is
still at ~30% — instance creation then fails with
`FAILED_PRECONDITION: the resource is locked by another operation`. Fixed:
after the ACTIVE poll, wait until `organizations/{org}/operations` shows
nothing in flight.

### 3. Option 2 alone cannot serve Apigee → `ingress=internal` Cloud Run

With Apigee up and the proxy target set, `/hello` via the instance returned
the Cloud Run **public** frontend's 404 page. Pre-2b, the Apigee tenant
resolves `run.app` via public DNS and egresses via its default internet
route — and the public frontend 404s internal-ingress services.
`option2/test.sh` only exercises VM→PGA, so option 2's Apigee leg had never
actually been proven against an internal-ingress service. The fix is
option 2b's tenant plumbing (peered DNS domain for `run.app`, restricted-VIP
route + custom-route export, VPC-SC on the peering) — after which the same
call returns 200 through the restricted VIP. Documented in
[option-b-pga.md](../option-b-pga.md).

### 4. Stale org-level ACM state silently neutered the 2b perimeter (fixed)

The scoped access policy (and its perimeter) from the *previous* sandbox
survived that project's deletion — org-level resources don't die with the
project. `option2b/setup.sh` found the policy by title, "succeeded", and
applied egress rules — while the perimeter's `resources` still named the
dead project number: **nothing was enforced, with no error anywhere**.
Fixed: setup now verifies the policy's scope covers the current project,
deletes/recreates stale policy + perimeter, and ensures the project is in
the perimeter's resources.

### 5. `gcloud compute networks peerings list` returns nested rows (fixed)

`value(name)` yields the VPC's own name and a `network~servicenetworking`
filter never matches — so `export-custom-routes` was silently skipped
(tenant couldn't use the restricted-VIP route). Fixed with
`--flatten="peerings[]"` in option2b setup/teardown and setup-slow.

### 6. Shared flows need an INTERMEDIATE environment (fixed)

Deploying the shared flow failed with `INVALID_DESTINATION_ENVIRONMENT:
... it's a BASE environment`. PAYG environments default to BASE when the
create body omits `type`, and BASE excludes "extensible proxies" (shared
flows / flow hooks). Fixed: create the env as INTERMEDIATE, and PATCH
existing BASE envs (`?updateMask=type`) — noting the PATCH is an **LRO**
(~4 min observed, the env re-provisions) that must be awaited before
deploying, and that INTERMEDIATE bills higher than BASE.

### 7. Flow hook ID casing (fixed)

`PUT .../flowhooks/PreProxyFlowhook` → `INVALID_ARGUMENT`. Valid IDs:
`PreProxyFlowHook`, `PreTargetFlowHook`, `PostTargetFlowHook`,
`PostProxyFlowHook` — capital H. Otherwise the attach shape was exactly as
designed: `PUT` with `{"sharedFlow": "<name>"}`.

### 8. `test.sh` Test 4 probe sent two `Authorization` headers (fixed)

The informational Google-ID-token probe used `ssh_curl_auth` (which injects
the token as `Authorization`) *and* passed the client JWT as a second
`Authorization` header — Cloud Run honored neither (401), so the probe
could never demonstrate its documented claim. Fixed by minting the token
inline into `X-Serverless-Authorization`, which incidentally proved the
combined-header pattern VM-side before Apigee was even provisioned.

## Findings that shape the design

- **§10 item 1 (combined headers) holds** — including
  `X-Serverless-Authorization` being forwarded to the container, so
  services can observe (not just trust) the hop identity.
- **§10 item 5 (custom audiences) holds** end-to-end with one fixed string.
- **§7.4 JWKS mirror posture, sharpened:** an `ingress=internal` mirror is
  reachable from the VM (PGA) and from Apigee (tenant peered DNS →
  restricted VIP), but **not** from a no-VPC-egress Cloud Run consumer —
  that fetch hits the public frontend and 404s fast (~75–100 ms). The
  PoC's env-fallback path (`jwks_source:"env"`) is the working pattern;
  consumers wanting the URL path need VPC egress (or the §7.4 push model).
- **§7.6 direct-call signature:** platform request log
  (`run.googleapis.com%2Frequests`), `httpRequest.status=403`,
  `"The request was not authenticated ... Empty Authorization header
  value"`; 401 variant for non-Google bearer tokens. No Admin Activity
  entry — build detection as a log-based metric.
- **§8 latency:** full stack p50 25 ms vs VerifyJWT-only p50 24 ms (N=15,
  VM→Apigee→Cloud Run) — mint+IAM+middleware ≈ 1 ms at p50, consistent
  with the "≈ 0 amortised" mint-cache claim. p95 (501/650 ms) was
  cold-start noise; isolated VerifyJWT cost and p99 remain open.
- **VerifyJWT error taxonomy** (usable for §7.6 alerting): expired →
  `steps.jwt.TokenExpired`; wrong aud → `steps.jwt.InvalidClaim`; missing
  token → `steps.jwt.FailedToResolveVariable`. All 401 at the edge.

## Timings observed (greenfield, europe-north2)

| Step | Duration |
| --- | --- |
| `setup-iam.sh` + `setup-base.sh` | ~6 min |
| Apigee org creation (LRO fully done) | ~15 min |
| Apigee instance creation | ~35 min |
| Env BASE → INTERMEDIATE PATCH (LRO) | ~4 min |
| 2b perimeter + tenant DNS/route propagation | < 10 min |
| `auth/setup.sh` (first run, 2 image builds) | ~4 min |

## Sidecar variant (§10 item 6, issue #39) — second live session

`scripts/auth/setup-envoy.sh` deploys `cr-auth-echo-envoy`: an Envoy
`jwt_authn` ingress container in front of the same echo app (middleware off,
`APP_PORT=8081`), plus Apigee proxy `/auth-echo-envoy` with the identical
combined-header target. 6/6 tests pass. Corrections found on the way:

### 9. Cloud Build under the perimeter — two failure modes (fixed)

- **Client side:** `gcloud builds submit` touches the Google-managed
  `<project#>.cloudbuild-logs.googleusercontent.com` bucket, which lives in
  a Google-owned project outside the perimeter → egress violation
  (`RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER` on `storage.buckets.get`).
  Fix: `--default-buckets-behavior=regional-user-owned-bucket` at every
  build site, plus `roles/storage.admin` for the build SA (gcloud's
  pre-check names that role verbatim; objectCreator is not enough).
- **Worker side:** Cloud Build's shared workers run *outside* the
  perimeter, so with storage restricted the worker couldn't reach the now
  in-project logs bucket ("Failure setting up GCS logging ... prohibited
  by organization's policy"). Fix: admit the build SA through the
  perimeter's ingress policy (production answer: private worker pools).
- Earlier builds only succeeded because they pre-dated the perimeter — any
  greenfield that applies 2b before its first build hits both immediately.

### 10. Multi-container deploy shape (fixed)

- Service-level flags must precede the first `--container` group (a
  trailing `--quiet` is rejected as an unrecognized *container* flag).
- A `--depends-on` dependency must declare a startup probe — the deploy is
  rejected otherwise. TCP probe on the app port works.
- Cloud Run injects `PORT` only into the ingress container; the app behind
  Envoy needs its own port plumbing (`APP_PORT` in this PoC).

### 11. Envoy rejection taxonomy differs across layers

`jwt_authn`: expired → 401 "Jwt is expired"; missing → 401 "Jwt is
missing"; **audience mismatch → 403** "Audiences in Jwt are not allowed".
Apigee VerifyJWT and the library middleware both return 401 for all three.
Anything consuming rejection codes across layers (alerting, client retry
logic) must not assume 401 uniformly.

### Sidecar vs library numbers (crude, N=15 via Apigee)

| Path | p50 | p95 |
| --- | --- | --- |
| `/auth-echo-envoy` (Envoy hop, middleware off) | 22 ms | 48 ms |
| `/auth-echo` (library in-process) | 19 ms | 49 ms |

Envoy hop ≈ **+3 ms p50 warm** (a cooler earlier run showed +12 ms).
Startup: system logs show the app container probe-ready then Envoy ready
**~0.65 s later** — the sidecar's per-instance cold-start tax. Both numbers
back §7.3's library-default recommendation; the sidecar is proven viable
where polyglot pressure wins.

## Still open (issue #35)

§10 items 7–8: org-policy preventive controls, edge deny-list — plus the
§8 leftovers above (isolated VerifyJWT cost, p99, rigorous cold/warm split,
JWKS cache TTL, mirror stale-on-error).
