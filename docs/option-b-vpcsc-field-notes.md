# Field Notes: Apigee → Cloud Run over PGA with VPC-SC

**Audience:** teams implementing the Option B (Private Google Access) pattern
with VPC Service Controls in a real, locked-down GCP organisation.

**What this is:** an honest account of building and validating the pattern on
a fresh, hardened project (org-policy location restrictions, no automatic
default-SA grants) — with the failures given equal billing to the successes.
Every error below was hit for real; every fix was validated live. The polished
end-state lives in [option-b-pga.md](option-b-pga.md) and
[`scripts/option2b/`](../scripts/option2b/); this document is the road that
got there.

**Headline:** the pattern works, end to end, perimeter enforced:

```
Test 2 [PASS]  inside-perimeter path (VM → PGA → Cloud Run)
Test 3 [PASS]  perimeter blocks cross-perimeter access
Test 4 [PASS]  Apigee southbound admitted through the perimeter
```

But it took ~3 elapsed days, 11 distinct failure modes, and several
multi-hour waits to get those three lines. Budget accordingly.

---

## 1. The two lessons that matter most

### Lesson 1: "It routes through the restricted VIP" is not "it is enforced"

Option B routes `*.run.app` to `199.36.153.4/30` (the VPC-SC-enforcing
endpoint) via a private DNS zone. Without a service perimeter, **nothing is
enforced** — the VIP passes everything through and security rests entirely on
IAM + `--ingress=internal`. If your security story mentions VPC-SC, you must
create the perimeter and *prove the negative case* (a request to an
out-of-perimeter resource being denied). Our negative test — curling a public
GCS bucket in an external project from inside the perimeter and expecting a
VPC-SC 403 — is the single most valuable test in the suite.

### Lesson 2: the Apigee tenant project is a second, invisible network

Apigee (VPC-peered model) runs in a Google-owned tenant project peered to
your VPC. It has its own routes and its own DNS, and **you cannot see either**.
Three of our hardest failures came from changes that silently altered tenant
state (see §4). Assume any VPC-SC change affects the tenant differently than
your own VMs, and test the Apigee path separately — a passing VM test proves
nothing about Apigee's path.

---

## 2. Failure catalogue — provisioning a hardened project

### 2.1 IAM grant to a service agent that doesn't exist yet

```
ERROR: (gcloud.projects.add-iam-policy-binding) INVALID_ARGUMENT:
Service account service-<num>@gcp-sa-apigee-mp.iam.gserviceaccount.com does not exist.
```

**Cause:** Google service agents are created lazily at different lifecycle
points. `gcp-sa-apigee-mp` only exists after the Apigee **runtime instance**
is provisioned — not after org creation, not after API enablement. Our IAM
script ran first and died (and, because of `set -euo pipefail`, took the
subsequent grants down with it).

**Fix:** make grants to maybe-not-yet-existing agents non-fatal, and re-apply
them from the provisioning script *after* the resource that creates the agent
is ACTIVE. We got this wrong twice — the first "fix" re-applied the grant
after **org** creation, which is still too early, and being fatal it aborted
provisioning before the instance was ever created.

**Know your service agents** (all bit us at different times):

| Agent | Created when | Role it needed | On |
|---|---|---|---|
| `service-<num>@gcp-sa-apigee-mp` | instance provisioning | `roles/run.invoker` | project |
| `service-<num>@gcp-sa-apigee` | org/API enablement | `roles/iam.serviceAccountTokenCreator` | the proxy's SA |
| `service-<num>@gcp-sa-apigee` | (same agent) | `roles/dns.peer` | project |
| `<num>-compute@developer` | project creation | Cloud Build roles (§2.3) | project |

### 2.2 Re-running provisioning raced the original run

```
"the resource is locked by another operation that is 30 percent completed so far
 where organization sb-paul-g-api2 is being created by operation: ..."
```

**Cause:** our script checked the org *existed* (HTTP 200) and skipped ahead —
but existence ≠ ACTIVE. An org mid-creation returns 200 with state
`CREATING`, and instance creation against it fails with the lock error above.

**Fix:** on re-entry, always wait for `state == ACTIVE`, not just presence.
This applies to every long-running Apigee resource (org, instance,
attachments).

### 2.3 Cloud Build in a location-restricted, hardened org

Three failures in sequence:

1. Local `docker build` — no Docker on the workstation, and Podman had
   amd64/arm64 issues on Apple Silicon. **Fix:** don't require a local
   container runtime at all; `gcloud builds submit` builds remotely on native
   amd64.
2. ```
   ERROR: (gcloud.builds.submit) HTTPError 412: 'us' violates constraint
   'constraints/gcp.resourceLocations'
   ```
   The default Cloud Build staging bucket is US multi-region. **Fix:**
   `--region=<eu-region>` plus a pre-created regional staging bucket passed
   via `--gcs-source-staging-dir`.
3. ```
   Error 403: <num>-compute@developer.gserviceaccount.com does not have
   storage.objects.get access ...
   ```
   The build runs as the default compute SA, which in a hardened org (auto
   role grants disabled) has **no roles** — it couldn't even read the source
   tarball it had just uploaded. **Fix:** grant it `storage.objectViewer`,
   `logging.logWriter`, `artifactregistry.writer`.

### 2.4 Zonal stockout of small VM types

```
code: ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS ... vmType: e2-micro ... reason: stockout
```

`e2-micro` was simply out of stock in one zone of a small region (the type
was offered in all three zones — capacity, not availability). **Fix:** never
hardcode zone or machine type; make both overridable and switch zones first
(cheaper than changing type).

---

## 3. Failure catalogue — Apigee southbound authentication

The Apigee → Cloud Run leg had **never actually been exercised** until the
VPC-SC work forced it. It then failed three separate ways, in layers — each
fix revealing the next failure. If your Cloud Run services require
authentication (they should: `--no-allow-unauthenticated`,
`--ingress=internal`), you will meet all three.

### 3.1 Deploy-time: MISSING_SERVICE_ACCOUNT

```
"deployment validations failed; MISSING_SERVICE_ACCOUNT: Deployment of ...
 requires a service account identity, but one was not provided with the request."
```

A proxy whose target contains `<Authentication><GoogleIDToken>` **must** be
deployed with a service account (`?serviceAccount=<email>` on the deployment
API call). That SA is the identity Apigee mints ID tokens *as* — it needs
`roles/run.invoker` on the target service. The **deployer** additionally
needs `iam.serviceAccounts.actAs` (`roles/iam.serviceAccountUser`) on that
SA — `serviceAccountTokenCreator` alone is not sufficient.

### 3.2 Runtime: GoogleTokenGenerationFailure

```
"errorcode":"messaging.adaptors.http.filter.GoogleTokenGenerationFailure"
```

Deployment succeeded; the first request failed. Two independent gaps:

1. `iamcredentials.googleapis.com` was not enabled (it's not in anyone's
   default "Apigee needs these APIs" list — add it).
2. The Apigee service agent (`gcp-sa-apigee` — note: a *different* agent from
   `gcp-sa-apigee-mp`) needs `roles/iam.serviceAccountTokenCreator` **on the
   proxy's deploy-time SA**. It impersonates that SA to mint the token.

### 3.3 Runtime: TARGET_CONNECT_TIMEOUT — the deep one

```
"errorcode":"messaging.adaptors.http.flow.ServiceUnavailable","reason":"TARGET_CONNECT_TIMEOUT"
```

This appeared **only after** enabling VPC-SC on the servicenetworking peering,
and is the most important finding in this document. See §4.

---

## 4. The Apigee tenant under VPC-SC: what actually happens

`gcloud services vpc-peerings enable-vpc-service-controls` is required so
Apigee tenant traffic is treated as inside your perimeter. But it has a
side effect the docs under-sell: it **removes the tenant project's default
internet route** and installs restricted-VIP DNS + routing for
`googleapis.com` names — **and nothing else**.

Consequence: `*.run.app` is not a `googleapis.com` name. The tenant now
resolves your Cloud Run URL to its *public* IPs — which it no longer has any
route to. Result: connect timeout, forever. No amount of waiting fixes it.

What we tried, in order:

| Attempt | Result |
|---|---|
| Wait for propagation (docs say "up to 30 min") | ✗ — it was never going to work; not a propagation issue |
| Grant `roles/dns.peer` to the Apigee service agent | ✗ alone — the grant is a *prerequisite*, it activates nothing by itself |
| Apigee `organizations.dnsZones` API (create DNS peering zone) | ✗ — `FAILED_PRECONDITION: organization with VPC Peering enabled is not supported`. **That API is for PSC-provisioned orgs only** |
| `gcloud services peered-dns-domains create run-app --dns-suffix=run.app.` | ✓ — this is the mechanism for VPC-peered orgs |

The working combination for a **VPC-peered** org (all four together):

1. `gcloud services vpc-peerings enable-vpc-service-controls` on the peering
2. `roles/dns.peer` for `service-<num>@gcp-sa-apigee` on the project
3. A **peered DNS domain** for `run.app.` — tenant queries for that suffix
   are answered from *your* VPC's resolution order, where the private
   `run.app → restricted VIP` zone lives
4. A restricted-VIP static route (`199.36.153.4/30` →
   `default-internet-gateway`) with `--export-custom-routes` on the peering

Once the peered DNS domain existed, the runtime picked it up dynamically
within minutes — no instance recreation, no proxy redeploy.

> **If your org is PSC-provisioned instead:** ignore `peered-dns-domains` and
> use the `organizations.dnsZones` API. The two mechanisms are mutually
> exclusive by provisioning model, and nothing in the error messages of the
> wrong one points you at the right one.

---

## 5. Waiting: observed propagation and provisioning times

Plan your implementation windows around these. "Is it broken or is it
propagating?" was our single biggest time sink — twice we debugged things
that were already fixed, and once we waited on something that was never
going to fix itself (§4).

| Operation | Documented | Observed |
|---|---|---|
| Apigee org creation | 30–50 min | ~40 min |
| Apigee instance creation | 30–60 min | ~45 min |
| VPC-SC perimeter **enforcement** after create | "a few minutes, up to 30" | **not observably enforcing same-day; confirmed blocking the following morning** (confounded by an auth issue — see below — but plan for hours, not minutes) |
| VPC-SC perimeter deletion | similar | not separately measured — assume the same |
| IAM grant propagation | ~1–2 min | 1–2 min (a retry loop suffices) |
| Peered DNS domain pickup by Apigee runtime | undocumented | minutes |
| Access policy creation (async) | — | < 1 min, but poll — the create returns before it's listable |

**Rules of thumb we settled on:**

- Distinguish *"cannot ever work"* errors (4xx with a reason) from *"not yet"*
  states before waiting. A connect **timeout** after a VPC-SC change is
  usually a routing/DNS gap (§4), not propagation.
- Put a timestamp in every test run's output. When you're comparing scroll
  back across a day of attempts, "which run was this?" matters.
- Poll `state == ACTIVE`; never trust resource existence.

---

## 6. Operational gotchas that masqueraded as pattern failures

These cost us real debugging time and none of them were the pattern's fault:

1. **24-hour re-auth.** Our org enforces daily gcloud reauthentication. A
   test that passed at 5pm "failed" at 9am with an error our script
   suppressed (see next item). If a long provisioning script runs > 30 min,
   refresh tokens inside the loop.
2. **Suppressed stderr turns one error into another.** A script that did
   `describe ... 2>/dev/null` reported "service not found — is setup
   complete?" when the real error was `Reauthentication failed`. Under a
   perimeter this gets worse: the same lookup can fail with a VPC-SC denial,
   an auth error, or a genuinely missing resource — three different fixes.
   Print the underlying error, always.
3. **Stale gcloud quota project.** Access Context Manager is an org-level
   API; gcloud routes its calls through the configured quota project. Ours
   pointed at a deleted project → `USER_PROJECT_DENIED` on every ACM call.
   Pass `--billing-project=<project>` explicitly on all ACM commands.
4. **Perimeter names reject hyphens.** `[A-Za-z0-9_]` only:
   `apigee-poc-perimeter` → `INVALID_ARGUMENT`; `apigee_poc_perimeter` fine.
5. **Lock yourself in before you lock others out.** Create the perimeter with
   an ingress rule admitting your admin identity from any source, or your own
   `gcloud`/CI calls to restricted APIs die the moment enforcement lands.
   Remember every other identity (CI service accounts, teammates) will be
   blocked — decide who needs ingress rules *before* enforcement propagates.
6. **A test summary that's a legend, not a report.** Our first test script
   printed what each result *would mean* — reading as if everything passed
   while test 4 was failing. Make summaries print actual PASS/FAIL.

---

## 7. Checklist for implementing teams

Provisioning (hardened org):

- [ ] Enable `iamcredentials.googleapis.com` alongside the usual APIs
- [ ] Cloud Build: regional builds + regional staging bucket + explicit roles
      for the build SA
- [ ] All IAM grants to service agents: non-fatal + re-applied after the
      resource that creates the agent is ACTIVE
- [ ] No hardcoded zones/machine types
- [ ] Long-running scripts: poll `state`, refresh auth tokens, survive re-runs

Apigee → authenticated Cloud Run:

- [ ] Proxy target: `<Authentication><GoogleIDToken><Audience>`
- [ ] Deploy with `?serviceAccount=<sa>`; deployer has `actAs` on it
- [ ] SA has `run.invoker`; `gcp-sa-apigee` agent has `tokenCreator` on the SA
- [ ] **Test the Apigee leg explicitly** — VM tests do not cover it

VPC-SC:

- [ ] Scoped access policy (not the org default); org-level
      `accesscontextmanager.policyAdmin` needed to create it
- [ ] Ingress rule for admin/CI identities *in the initial perimeter spec*
- [ ] `enable-vpc-service-controls` on the peering **plus** the §4 DNS/routing
      set (peered model: `peered-dns-domains`; PSC model: `dnsZones` API)
- [ ] A negative test that proves denial of out-of-perimeter access
- [ ] Time budgeted for enforcement propagation (hours, pessimistically)
- [ ] Teardown tested — perimeters, policies, peered DNS domains and route
      exports all need explicit reversal

---

## 8. Pointers

- Working scripts: [`scripts/option2b/`](../scripts/option2b/) (setup, test
  with real PASS/FAIL reporting, teardown)
- Architecture reference: [option-b-pga.md](option-b-pga.md)
- DNS background: [dns-guide.md](dns-guide.md) (restricted vs private VIP)
- Apigee VPC-SC docs: <https://cloud.google.com/apigee/docs/api-platform/security/vpc-sc>
- Peered DNS domains: <https://cloud.google.com/sdk/gcloud/reference/services/peered-dns-domains>
