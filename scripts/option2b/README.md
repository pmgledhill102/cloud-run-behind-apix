# Option B + VPC-SC: Private Google Access with an enforced perimeter

Extends [Option B](../option2/README.md) with a real VPC Service Controls
perimeter. Option 2 routes `*.run.app` through the **restricted VIP**
(`199.36.153.4/30`) — the VPC-SC-enforcing endpoint — but creates no perimeter,
so nothing is actually enforced. Option 2b creates an **enforced** perimeter
around the project and proves both directions:

- **Positive**: traffic inside the perimeter (VM → PGA → Cloud Run, and
  Apigee southbound) keeps working unchanged.
- **Negative**: a restricted service in a project *outside* the perimeter
  (a public GCS bucket) is denied from inside it with a VPC-SC 403.

```
                    ┌───────── perimeter (this project) ─────────┐
VM / Apigee ────────│──► restricted VIP ──► Cloud Run (inside)   │──► 200 OK
                    │                                            │
VM ─────────────────│──► restricted VIP ──► GCS bucket (OUTSIDE) │──► 403 VPC-SC
                    └────────────────────────────────────────────┘
```

## Scripts

| Script | Resources |
|---|---|
| `setup.sh` | Thin serial wrapper: `setup-early.sh` then `setup-finish.sh` — the original single-command flow |
| `setup-early.sh` | Pre-Apigee phase (needs only `setup-base`): ACM API, scoped access policy `apigee-poc-policy`, restricted-VIP static route, enforced perimeter `apigee_poc_perimeter` (restricts `run.googleapis.com`, `storage.googleapis.com`; ingress rule admits the caller identity; **egress allow-list** admits Cloud Run in `ALLOWED_EGRESS_PROJECT_NUMBER` only; underscores because perimeter names disallow hyphens) |
| `setup-finish.sh` | Post-Apigee phase (idempotent): VPC-SC on the Apigee servicenetworking peering, `dns.peer` grant for the Apigee service agent, custom route export on the peering, peered DNS domain `run-app` (tenant resolves `run.app` via this VPC), Apigee proxy target refresh (same update as `option2/setup.sh` — covers option2 having run before Apigee existed) |
| `test.sh` | Perimeter status + positive/negative enforcement tests + Apigee E2E |
| `measure-propagation.sh` | Probes the negative test every `INTERVAL` (60s) until the expected state arrives and reports elapsed time — `measure-propagation.sh blocked` after `setup.sh`, `measure-propagation.sh open` after `teardown.sh`. Pass the target: if the flip lands before the first probe (deletion has been near-instant), auto-detect would anchor on the wrong state |
| `setup-external.sh` | Governance-test fixtures: two Apigee pass-through proxies (`/external-blocked` → `BLOCKED_RUN_URL`, `/external-allowed` → `ALLOWED_RUN_URL`, both from `shared/env.sh`). Drift-aware: retargets via a new revision if a URL changes |
| `test-external.sh` | Proves the perimeter is **governable** — deny by default, admit by explicit egress policy. **Observes only** (fixtures come from `setup-external.sh`; exits with a hint if they're missing). Seven probes: laptop controls for both external services, Apigee→internal control, then Apigee/VM → blocked (expect BLOCKED) and Apigee/VM → allowed (expect OK) — with explicit leak and lockout checks |
| `experiment-tenant-dns.sh` | **Greenfield test of the "DNS peering isn't needed under VPC-SC" claim.** Phases `omit` → `dns` → `full` build the omitted state in from the start and add the pieces back one at a time; each phase probes `*.run.app` and `*.googleapis.com` through the same Apigee runtime in the same minute. See [the claim](#the-dns-peering-claim) below |
| `experiment-ip-target.sh` | **Retest of the IP-literal restricted-VIP target** (field notes §4.1, issue #99). Six proxies isolate one thing each — `Host` header (run.app name vs the IP), certificate validation (`IgnoreValidationErrors` on vs off), and `GoogleIDToken`+`IncludeEmail` auth — with two `run.app` controls (auth → expect 200; no auth → the Cloud Run IAM 403 signature). `TRACE=1` records `tlsHandshakeStatus`, `resolvedAddress` and the target-side `Host` from a debug session; `cleanup` removes the proxies |
| `teardown.sh` | Test fixture proxies, perimeter (incl. egress allow-list), policy (only if ours and empty), peered DNS domain, route + export, `dns.peer`, peering VPC-SC off |

## Why the Apigee tenant needs DNS + routing plumbing

Enabling VPC-SC on the servicenetworking peering **removes the tenant
project's default internet route** and installs restricted-VIP DNS/routing for
`googleapis.com` names — but not `run.app`. Without help, the tenant resolves
`run.app` to public IPs it can no longer route to (`TARGET_CONNECT_TIMEOUT`).
Two mechanisms exist to peer DNS into the customer VPC, and they are
**mutually exclusive by provisioning model**:

- **PSC (non-peering) orgs**: the Apigee `organizations.dnsZones` API.
- **VPC-peered orgs (this repo)**: a servicenetworking **peered DNS domain**
  (`gcloud services peered-dns-domains create`). The `dnsZones` API returns
  `FAILED_PRECONDITION` for peered orgs (found live).

With the peered DNS domain in place, the tenant resolves `run.app` via this
VPC's `run-app-pga` zone → restricted VIP → its own restricted-VIP route
(installed by the VPC-SC enablement) → Cloud Run, inside the perimeter.

## The DNS-peering claim

> "The peered DNS domain and the network routes aren't required if VPC Service
> Controls is enabled, because enabling it redirects the DNS to
> `restricted.googleapis.com` anyway."
> — reported from a Google support agent, 2026-09

Half of that is right, and the half that is right is the reason the other half
is so persuasive. `enable-vpc-service-controls` really does install
restricted-VIP DNS and routing inside the Apigee tenant — **for
`*.googleapis.com` names**. Cloud Run is reached at `*.run.app`, which is not
one of them, so nothing in that redirect covers the hop this pattern depends
on.

`experiment-tenant-dns.sh` tests it rather than asserting it, and does so on a
stack that **never had** the DNS peering — closing the loophole left by field
notes §4/§9, which established the same thing by deleting the peering from a
working stack:

```bash
export PROJECT_ID=<your-project>

# Build the stack with the plumbing deliberately omitted:
SKIP_RESTRICTED_VIP_ROUTE=1 ./scripts/option2b/setup-early.sh
SKIP_TENANT_DNS=1           ./scripts/option2b/setup-finish.sh

./scripts/option2b/experiment-tenant-dns.sh omit   # expect: run.app FAILS
./scripts/option2b/experiment-tenant-dns.sh dns    # expect: run.app WORKS
./scripts/option2b/experiment-tenant-dns.sh full   # expect: no further change
```

Two omission switches make the "without it" state reachable on purpose rather
than by deleting resources afterwards:

| Variable | Script | Omits |
|---|---|---|
| `SKIP_RESTRICTED_VIP_ROUTE=1` | `setup-early.sh` | the `restricted-vip` static route |
| `SKIP_TENANT_DNS=1` | `setup-finish.sh` | `dns.peer`, the custom route export, and the peered DNS domain |

Results are recorded in
[field notes §4.2](../../docs/option-b-vpcsc-field-notes.md).

To capture the run as an artifact rather than as scrollback — for a Google CE or
a support escalation — set `EVIDENCE_DIR` (and `EVIDENCE_REDACT=1`, since this
repo is public):

```bash
PROJECT_ID=<your-project> EVIDENCE_DIR=docs/repro/evidence EVIDENCE_REDACT=1 TRACE=1 \
  ./scripts/option2b/experiment-tenant-dns.sh omit
```

Each phase writes a transcript and a manifest; see
[`docs/repro/evidence/`](../../docs/repro/evidence/). The reader-facing writeup
of the whole thing is [`docs/repro/dns-peering.md`](../../docs/repro/dns-peering.md).

## Prerequisites

- `shared/setup-base.sh` and `option2/setup.sh` completed (option2 provides the
  DNS zone and restricted-VIP routing this builds on).
- **Org-level permission**: creating the access policy requires
  `roles/accesscontextmanager.policyAdmin` on the organization. To reuse an
  existing policy instead: `PROJECT_ID=<your-project> ACCESS_POLICY_ID=<id> ./scripts/option2b/setup.sh`.
- Apigee (`shared/setup-slow.sh`) optional — test 4 skips if absent.

## Parallel workflow: hide propagation inside Apigee provisioning

Perimeter enforcement after create is **highly variable — ~1 min to ~35 min
observed** across runs (probe-measured ~35 min on the 2026-08-03 rebuild; ~1
min on an earlier instrumented run — see
[field notes §5](../../docs/option-b-vpcsc-field-notes.md)). Run serially
after `setup-slow.sh`, that tail is pure wall-clock waste. Nothing in the
perimeter half of option2b needs Apigee — so create the perimeter right after
`setup-base.sh` and let propagation overlap the ~60-90 min Apigee window:

```text
setup-base → (setup-slow ∥ option2b/setup-early) → option2/setup
           → option2b/setup-finish → option2b/test
```

Early enforcement is safe for the parallel `setup-slow` run: only `run` and
`storage` are restricted (the Apigee provisioning APIs are unaffected), and
Cloud Build image builds succeed under the enforced perimeter (the ingress
rule admits the caller + build SA).

```bash
export PROJECT_ID=<your-project>   # required — no default

./scripts/shared/setup-base.sh          # ~5 min
./scripts/shared/setup-slow.sh &        # ~60-90 min, in parallel with:
./scripts/option2b/setup-early.sh       # perimeter — propagation clock starts

# ...when setup-slow completes:
./scripts/option2/setup.sh              # DNS zone (+ proxy target if Apigee up)
./scripts/option2b/setup-finish.sh      # Apigee plumbing + proxy target refresh
./scripts/option2b/test.sh
```

If `option2/setup.sh` runs before Apigee exists, its proxy-target update
skips gracefully — `setup-finish.sh` re-runs the same update, so the end
state is independent of that ordering.

## Run instructions

```bash
export PROJECT_ID=<your-project>   # required — no default

./scripts/option2b/setup.sh                        # setup-early + setup-finish
./scripts/option2b/measure-propagation.sh blocked  # optional: measure enforcement arrival
./scripts/option2b/test.sh                         # core perimeter validation

# Governance test (blocked AND allowed external Cloud Run):
./scripts/option2b/setup-external.sh               # ~1-2 min (fixture proxies)
./scripts/option2b/test-external.sh

# when done:
./scripts/option2b/teardown.sh
```

## Notes and caveats

- **Propagation**: perimeter create/delete takes minutes to take effect;
  `test.sh` retries the negative test but may still need a re-run.
- **Admin continuity**: the perimeter includes an ingress rule allowing the
  script caller's identity from any source, so `gcloud`/laptop access to
  restricted services keeps working. Other identities calling restricted
  services from outside the perimeter are denied — including CI.
- **`storage.googleapis.com` is restricted** purely for the negative test.
  Side effect: re-running `shared/setup-base.sh`'s Cloud Build step while the
  perimeter is up works for the caller identity (ingress rule) but would fail
  for other identities.
- **Apigee**: `setup-finish.sh` enables VPC-SC on the servicenetworking peering
  (per the [Apigee VPC-SC docs](https://cloud.google.com/apigee/docs/api-platform/security/vpc-sc)),
  which places Apigee tenant-project southbound traffic inside the perimeter.
  Full production lockdown additionally maps `*.googleapis.com` to the
  restricted VIP — out of scope here (only `run.app` is mapped, by option2).
- **ACM quota project**: all ACM commands pass `--billing-project` explicitly;
  ACM is org-level and gcloud otherwise uses the configured quota project,
  which may be stale.

## Cost while running

VPC Service Controls and Access Context Manager are **free**. Total cost is
identical to option2 (~$0.01/day).
