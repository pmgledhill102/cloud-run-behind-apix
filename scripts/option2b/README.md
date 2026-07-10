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
| `setup.sh` | ACM API, scoped access policy `apigee-poc-policy`, VPC-SC on the Apigee peering, `dns.peer` grant for the Apigee service agent, restricted-VIP static route + custom route export, peered DNS domain `run-app` (tenant resolves `run.app` via this VPC), enforced perimeter `apigee_poc_perimeter` (restricts `run.googleapis.com`, `storage.googleapis.com`; ingress rule admits the caller identity; **egress allow-list** admits Cloud Run in `ALLOWED_EGRESS_PROJECT_NUMBER` only; underscores because perimeter names disallow hyphens) |
| `test.sh` | Perimeter status + positive/negative enforcement tests + Apigee E2E |
| `measure-propagation.sh` | Probes the negative test every `INTERVAL` (60s) until the expected state arrives and reports elapsed time — `measure-propagation.sh blocked` after `setup.sh`, `measure-propagation.sh open` after `teardown.sh`. Pass the target: if the flip lands before the first probe (deletion has been near-instant), auto-detect would anchor on the wrong state |
| `test-external.sh` | Proves the perimeter is **governable** — deny by default, admit by explicit egress policy. Two out-of-perimeter Cloud Run services with opposite expectations: `BLOCKED_RUN_URL` (no egress rule → must be denied) and `ALLOWED_RUN_URL` (allow-listed by setup.sh → must succeed). Seven probes: laptop controls for both, Apigee→internal control, then Apigee/VM → blocked (expect BLOCKED) and Apigee/VM → allowed (expect OK) — with explicit leak and lockout checks |
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

## Prerequisites

- `shared/setup-base.sh` and `option2/setup.sh` completed (option2 provides the
  DNS zone and restricted-VIP routing this builds on).
- **Org-level permission**: creating the access policy requires
  `roles/accesscontextmanager.policyAdmin` on the organization. To reuse an
  existing policy instead: `ACCESS_POLICY_ID=<id> ./scripts/option2b/setup.sh`.
- Apigee (`shared/setup-slow.sh`) optional — test 4 skips if absent.

## Run instructions

```bash
./scripts/option2b/setup.sh           # ~2-5 min
# wait a few minutes for perimeter propagation (can be up to ~30)
./scripts/option2b/test.sh
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
- **Apigee**: `setup.sh` enables VPC-SC on the servicenetworking peering
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
