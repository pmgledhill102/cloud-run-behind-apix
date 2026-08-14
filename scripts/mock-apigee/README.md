# Mock-Apigee Quick Stack

A "fake Apigee tenant" for fast iteration (issue #51): a second VPC peered to
`apigee-vpc` with an Envoy gateway VM standing in for the Apigee runtime
instance. Spin-up ~2–3 minutes and ~£6/month, versus ~75–90 minutes and
~£0.50/hour for the real thing — so header, grant, and routing experiments
iterate in the inner loop, and the real Apigee suites become the
confirmation gate.

```text
vm-test (apigee-vpc) ──peering──▶ mock-apigee-gw:443 (apigee-tenant-mock VPC)
                                   │  Envoy:
                                   │   jwt_authn   = VerifyJWT flow hook
                                   │   gcp_authn   = GoogleIDToken target auth
                                   │   routes      = API proxies
                                   ▼
                        run.app → 199.36.153.4-7 (restricted VIP / PGA)
                                   │
                                   ▼
                       cr-hello / cr-auth-echo (Cloud Run, IAM-closed)
```

## Engine: Envoy (decision per #51, verified against source)

The one behaviour that had to be faithful is the **combined-header pattern**:
client JWT untouched in `Authorization`, minted Google ID token in
`X-Serverless-Authorization`. Envoy's `gcp_authn` filter supports this:

- `token_header {name, value_prefix}` — the fetched ID token is **written**
  to that header on the upstream request (`addTokenToRequest()` →
  `hdrs.setCopy(...)` in `gcp_authn_filter.cc`; the proto comment's word
  "extract" is misleading).
- Per-upstream audience via the cluster's
  `typed_filter_metadata["envoy.filters.http.gcp_authn"]` (`Audience.url`) —
  `/auth-echo` uses the Cloud Run **custom audience** (`apigee-poc-auth`,
  §10 item 5 fidelity); `/hello` uses the service URL.
- Tokens come from the VM metadata server (default compute SA, which holds
  `run.invoker` from `setup-iam.sh`), with `cache_config` caching.

Pinned to `envoyproxy/envoy:v1.31-latest` — same lineage as the proven
sidecar variant (`scripts/auth/envoy/`); the v1.31 proto includes
`token_header` and the `cluster`/`timeout` config style. If Envoy ever
fights back, the decided fallback is a small Go gateway
(`google.golang.org/api/idtoken`), but it was not needed.

## Usage

```bash
# Prerequisites: shared/setup-base.sh + auth/setup.sh (keypair, cr-auth-echo).
# setup-slow.sh (Apigee) and option2b (VPC-SC) NOT required — that's the point.
export PROJECT_ID=<your-project>   # required — no default

./scripts/mock-apigee/setup.sh      # ~2-3 min (+ ~1-2 min first image pull)
./scripts/mock-apigee/test.sh       # M1-M4
./scripts/mock-apigee/teardown.sh   # full reverse, ~1-2 min
```

Iterating on gateway behaviour = edit `gateway/envoy.yaml.tmpl`, delete the
image + VM (or run teardown/setup), rebuild — minutes, no Apigee in the loop.

## Fidelity table

| Faithful (same as real Apigee) | Mocked / NOT validated |
|---|---|
| Topology hop-for-hop: internal-IP TLS northbound, VPC peering hop, southbound via restricted VIP (PGA) | servicenetworking mechanics (VPC-SC-on-peering, peered DNS domains) — hand-replicated with standard peering + own zone |
| Combined-header target auth: client JWT in `Authorization`, Google ID token in `X-Serverless-Authorization` | Apigee policy XML (VerifyJWT config, flow-hook casing — the things that bite for real, see auth field notes) |
| Cloud Run custom audience (fixed string, no per-service URL plumbing) | Apigee fault signatures: Envoy answers 401/403 plain text, not `{"fault":...}` JSON |
| Fleet-wide edge JWT enforcement (every route except `/healthz`) | VPC-SC perimeter semantics (use option2b) |
| Cloud Run IAM enforcement (services stay closed; gateway's tokens must pass) | Apigee analytics, quotas, deploy lifecycle, env groups |

**The rule: mock = inner loop, real Apigee = confirmation gate.** Anything
proven here still needs one real-Apigee run (options 2/2b + auth suites)
before it's documented as verified.

## Costs

| | Mock stack | Real Apigee |
|---|---|---|
| Spin-up | ~2–3 min | ~75–90 min |
| Running cost | one e2-micro + NAT ≈ £6/month | ~£0.50/hour (≈£360/month) |
| Teardown/rebuild | ~3 min round trip | hours |

## Limitations

- The gateway VM's self-signed cert means `curl -k` (same as the PoC's
  real-Apigee tests against `10.2.0.2`).
- `jwt_authn` reads the JWKS inline from env at boot — key rotation means
  re-creating the VM (or extending the gateway to serve remote JWKS).
- Routes are static in `envoy.yaml.tmpl`; adding a service = adding a route
  + cluster block. That's the fast-iteration surface, not a limitation per
  se — it's the mock equivalent of deploying a new proxy.
