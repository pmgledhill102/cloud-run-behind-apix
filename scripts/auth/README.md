# Auth PoC — JWT Enforcement Layers

Working prototype of the recommended baseline from
[`docs/auth/jwt-enforcement-design.md`](../../docs/auth/jwt-enforcement-design.md) (§9),
built on top of Option 2/2b (PGA, optional VPC-SC perimeter).

```
VM (mints client JWTs, ← mock external IdP: private key stays local)
 │  Authorization: Bearer <client JWT>
 ▼
Apigee env ── PreProxy FLOW HOOK → 'auth-verify' shared flow
 │             └─ VerifyJWT: RS256 (pinned), exp, iss, aud — JWKS from cr-idp-mock
 │  proxy 'cr-auth-jwt' (/auth-echo) target:
 │    Google ID token (CUSTOM audience) → X-Serverless-Authorization
 │    client JWT untouched              → Authorization
 ▼
PGA restricted VIP
 ▼
cr-auth-echo: IAM-closed (--no-allow-unauthenticated) → JWT middleware → echo
cr-idp-mock:  JWKS endpoint (allow-unauth + ingress=internal — §7.4 mirror posture)
```

## Usage

```bash
# Prerequisites: shared/setup-iam.sh, shared/setup-base.sh, option2/setup.sh
# (+ shared/setup-slow.sh for the Apigee parts; option2b optional)

./scripts/auth/setup.sh      # ~3-4 min first run (2 image builds), ~30s after
./scripts/auth/test.sh
./scripts/auth/teardown.sh

# Sidecar variant (§10 item 6): Envoy jwt_authn ingress container
# in front of the same app (middleware off) — run setup.sh first:
./scripts/auth/setup-envoy.sh
./scripts/auth/test-envoy.sh
./scripts/auth/teardown-envoy.sh
```

The sidecar variant's request path — headers at every hop, what each layer
checks, rejection signatures — is walked through in
[`docs/auth/envoy-sidecar-flow.md`](../../docs/auth/envoy-sidecar-flow.md).

**Warning:** setup attaches the shared flow via the env-level flow hook, so
**every** proxy in the env requires a valid JWT until teardown (that's the
point — fleet-wide, structurally unskippable). The option2/3 `/hello` tests
will 401 while the Auth PoC is up.

Mock-issuer keys live in `scripts/auth/state/` (gitignored, created by
setup, removed by teardown). The private key never leaves the local machine
— `test.sh` signs JWTs locally, mimicking an external issuer.

## What the tests prove (design doc §10 mapping)

| §10 item | Claim | Test |
|---|---|---|
| 1 | Combined headers: Google token in `X-Serverless-Authorization`, client JWT intact in `Authorization` | Test 2 |
| 2 | Direct PGA call bypassing Apigee → blocked by Cloud Run IAM before the container (T3) | Test 4 |
| 3 | Flow-hook shared flow rejects expired / wrong-aud / missing JWTs at the edge; latency | Tests 2, 3, 5 |
| 4 (partial) | JWKS mirror posture reachable in-perimeter; cold-start fetch timing in auth-echo startup logs | Test 1 + logs |
| 5 | Cloud Run custom audience — fixed-string `aud`, no per-service URL plumbing | Test 2 |

Not covered (follow-ups): item 6 (sidecar/ingress-container variant), item 7
(org-policy preventive controls — needs org perms), item 8 (edge deny-list).

## Caveats

- **Project-level `run.invoker`**: this PoC project grants invoker broadly
  (the VM's SA needs it for options 1–4 tests), so a direct call with a
  *Google* ID token succeeds here where the target design's per-service
  grants would 403. Test 4 prints this explicitly. The meaningful proofs are
  the no-token and client-JWT-only 403s.
- **JWKS fetch by auth-echo**: `cr-idp-mock` is `ingress=internal`; whether
  a non-VPC-egress Cloud Run service can reach it is itself a finding — the
  container logs which source (`url` fetch vs `env` fallback) won, and
  `jwks_source` appears in every echo response. **Answered live**: it can't —
  the fetch 404s at the public frontend in ~75–100 ms and the env fallback
  wins (see `docs/auth/auth-poc-field-notes.md`).
- Diagrams: `docs/diagrams/auth-enforcement-layers.drawio` (concept),
  `docs/diagrams/auth-poc-architecture.drawio` (this build), and
  `docs/diagrams/envoy-sidecar-{sequence,headers}.drawio` (sidecar-variant
  request flow).
