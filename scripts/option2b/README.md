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
| `setup.sh` | ACM API, scoped access policy `apigee-poc-policy`, VPC-SC on the Apigee peering, enforced perimeter `apigee-poc-perimeter` (restricts `run.googleapis.com`, `storage.googleapis.com`; ingress rule admits the caller identity) |
| `test.sh` | Perimeter status + positive/negative enforcement tests + Apigee E2E |
| `teardown.sh` | Perimeter, policy (only if ours and empty), peering VPC-SC off |

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
