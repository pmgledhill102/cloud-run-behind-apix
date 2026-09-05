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

And the sharper claim — **egress is denied by default and admitted only
where an explicit policy names the target project** — proven with controls
on both sides and both outcomes in one run
([`test-external.sh`](../scripts/option2b/test-external.sh), validated
2026-07-10):

```
Probe 0a [PASS]  control: laptop → blocked-list service (expect OK)
Probe 0b [PASS]  control: laptop → allow-list service (expect OK)
Probe 1  [PASS]  control: Apigee → in-perimeter cr-hello (expect OK)
Probe 2  [PASS]  Apigee → BLOCKED external (expect BLOCKED)
Probe 3  [PASS]  VM → BLOCKED external (expect BLOCKED)
Probe 4  [PASS]  Apigee → ALLOWED external (expect OK)
Probe 5  [PASS]  VM → ALLOWED external (expect OK)
```

The detail that makes this conclusive: the VM's DNS resolution, printed in
the probe output, shows **both** external services resolving to the same
restricted VIP (`199.36.153.4-7`). Blocked and allowed traffic take the
*identical* network path — the only difference is the egress policy naming
one target project. This is governance, not routing.

Worth knowing for monitoring/assertions: the blocked Cloud Run request is
refused by the Google Front End at the restricted VIP with a **plain HTML
`403 Forbidden` ("Access is forbidden")** — not a structured VPC-SC JSON
error like the storage API returns. Match on status, not body shape. The
storage-API denial *does* include a `vpcServiceControlsUniqueIdentifier`,
which can be searched in Cloud Audit Logs to locate the exact denial event
and its ingress/egress violation details — the HTML 403 offers no such
handle, so for Cloud Run denials go straight to the audit logs. The same
wildcard `*.run.app → 199.36.153.x` zone resolves *external* services'
hostnames too — that is precisely why the perimeter catches them.

The egress allow-list is applied by `setup.sh` (admitting Cloud Run in a
single named external project, `ALLOWED_EGRESS_PROJECT_NUMBER`); the fixture
proxies are provisioned by `setup-external.sh` so the test itself only
observes. No DNS changes anywhere: the same restricted-VIP path simply
starts admitting the one named egress, on Google's backbone, still
perimeter-audited. **Syntax trap (found live)**: the permission name that
denials log (`targetResourcePermissions: run.routes.invoke`) is *not*
accepted as an egress `methodSelector` for `run.googleapis.com` —
`INVALID_ARGUMENT`. Use `method: '*'` and scope by target project instead;
the audit-log entry tells you *what* to allow, not the literal syntax.

But it took ~3 elapsed days, 11 distinct failure modes, and several
multi-hour waits to get those lines. Budget accordingly.

**If you have been told the tenant DNS peering is unnecessary under VPC-SC,
read [§4.2](#42-vpc-sc-redirects-dns-to-restrictedgoogleapiscom-so-you-dont-need-the-peering)
first.** It is the one claim in this area that is half true, and the true half
is what makes it convincing.

**Taking this to Google?** [`docs/repro/dns-peering.md`](repro/dns-peering.md)
is the same finding written for a Customer Engineer who will not run any of
this — the claim, the mechanism, what it takes to reproduce, and the specific
asks — without the 800 lines around it.

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

The sharpest instance of this: point your `run.app` zone at the **private**
VIP instead of the restricted one and your workloads carry on returning
`200` while every Apigee call dies with `TARGET_CONNECT_TIMEOUT`, because
only the tenant lost its route. §4.1 has the reproduction; §9 has the
one-test method for telling that apart from a firewall problem.

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

The working combination for a **VPC-peered** org:

1. `gcloud services vpc-peerings enable-vpc-service-controls` on the peering
2. `roles/dns.peer` for `service-<num>@gcp-sa-apigee` on the project
3. A **peered DNS domain** for `run.app.` — tenant queries for that suffix
   are answered from *your* VPC's resolution order, where the private
   `run.app → restricted VIP` zone lives
4. A restricted-VIP static route (`199.36.153.4/30` →
   `default-internet-gateway`) with `--export-custom-routes` on the peering —
   **belt and braces, not load-bearing; see the correction below**

> **Correction (verified live 2026-09-04).** This list used to say "all four
> together". Item 4 is **not load-bearing for connectivity**. With items 1–3
> in place we deleted the `restricted-vip` route outright and Apigee kept
> working: three requests spanning eight minutes all reached Cloud Run, and a
> debug-session trace of a *fresh* connection (`isFromClientPool=false`,
> `socketUseCount=0`) showed `resolvedAddress = 199.36.153.7` and
> `connectionStatus = CONNECTED` with no route of ours in existence.
> `enable-vpc-service-controls` installs restricted-VIP routing *inside the
> tenant*, and that is what actually carries this traffic. Keep the route if
> you like — it costs nothing — but do not go hunting for a missing route
> when you are debugging a timeout. What *is* load-bearing is item 3: delete
> the peered DNS domain and southbound dies in about a minute (§9). Both halves
> were re-confirmed greenfield — built without them rather than broken after
> the fact — in §4.2.

Once the peered DNS domain existed, the runtime picked it up dynamically
within minutes — no instance recreation, no proxy redeploy.

> **If your org is PSC-provisioned instead:** ignore `peered-dns-domains` and
> use the `organizations.dnsZones` API. The two mechanisms are mutually
> exclusive by provisioning model, and nothing in the error messages of the
> wrong one points you at the right one.

### 4.1 Restricted vs private VIP — the trap that produces TARGET_CONNECT_TIMEOUT

**Verified live 2026-09-04, A/B/A, on an otherwise-working stack.**

`enable-vpc-service-controls` installs tenant routing for the **restricted**
VIP (`199.36.153.4/30`) only. It installs **nothing** for the **private** VIP
(`199.36.153.8/30`). So if your private `run.app` zone points at the private
range, the tenant resolves your Cloud Run URL to an address it cannot route
to, and every southbound call dies at TCP connect — the §3.3 symptom, with no
VPC-SC change and nothing in Cloud Run's logs to show for it.

| Private `run.app` zone points at | workload path (VM → Cloud Run) | Apigee path |
|---|---|---|
| `199.36.153.4-7` (restricted) | `200` | connects |
| **`199.36.153.8-11` (private)** | **`200`** | **`503 TARGET_CONNECT_TIMEOUT` in ~3 s** |
| `199.36.153.4-7` (restored) | `200` | connects again |

The middle row is the whole trap: **your workloads keep working**, because
your own VPC still has a default route covering the private VIP. Only the
tenant — whose default route `enable-vpc-service-controls` removed — is
stranded. So a VM test "proves" the path is healthy while Apigee times out,
and the obvious suspects (firewall, routes, auth) are all innocent.

**Adding and exporting a custom route for `199.36.153.8/30` does not fix it.**
We created the route, confirmed `exportCustomRoutesToPeer: true` on the
peering, and the tenant still could not reach `199.36.153.9` — while a VM in
the same VPC reached it fine (`403` in 0.30 s, i.e. TCP and TLS both
succeeded). Exported custom routes evidently reach the servicenetworking peer
network but not the Apigee runtime tenant that makes the call: there are two
Google-managed tenant projects in play (the peering's
`…-tp/global/networks/servicenetworking`, and the org's `apigeeProjectId`)
and you can see into neither. Caveat: tested to ~4 minutes after route
creation, not longer.

**Fix:** point the zone at `199.36.153.4-7`. Cloud Run is a VPC-SC-supported
service, so the restricted VIP serves it. DNS-only change — no routes, no
firewall rules, no proxy redeploy.

**Security consequence, worth raising explicitly.** While you are on the
private VIP, Apigee southbound is **not** subject to VPC-SC enforcement even
though `enable-vpc-service-controls` is switched on — the switch is on, but
the traffic never traverses the enforcing endpoint. If a compliance story
claims that path is perimeter-protected, it is not. Moving to the restricted
VIP starts genuinely enforcing it, so expect a `403` rather than a `200` if
the perimeter does not yet admit the path. That `403` is progress, not a
regression: connectivity works and it has become a policy question (§7 shows
how to find the denial in audit logs).

**Targeting the VIP by IP is not a workaround.** A target of
`<URL>https://199.36.153.5/</URL>` with an `AssignMessage`-set `Host` header
returns `403 "The service you are trying to access is not available on
Google's Restricted VIPs"` in ~45 ms. The Google front end selects the backend
from **TLS SNI**, not from the `Host` header, and connecting by raw IP puts
the IP in SNI. DNS is precisely what lets the hostname reach SNI while the
packets go to the VIP — which is why the peered DNS domain is load-bearing
and the static route is not.

---

### 4.2 "VPC-SC redirects DNS to restricted.googleapis.com, so you don't need the peering"

**Verified live 2026-09-04, greenfield, on a stack that never had the DNS
peering.** Reproduce with
[`option2b/experiment-tenant-dns.sh`](../scripts/option2b/experiment-tenant-dns.sh).

A Google support agent told us the peered DNS domain and the network routes
are not required once VPC Service Controls is enabled, because enabling it
"redirects the DNS to `restricted.googleapis.com` anyway".

**The mechanism they describe is real. It just does not cover `run.app`.**
`enable-vpc-service-controls` installs restricted-VIP DNS and routing inside
the Apigee tenant for `*.googleapis.com` names. Cloud Run is reached at
`*.run.app`, which is not one of them.

§4 and §9 already pointed this way, but both established it by *deleting* the
peered DNS domain from a working stack. That leaves a loophole: perhaps
enablement binds tenant `run.app` resolution once, and deleting the peering
afterwards only removes something already bound. So this run built the
omission in from the start (`SKIP_TENANT_DNS=1`,
`SKIP_RESTRICTED_VIP_ROUTE=1`) and added the pieces back one at a time.

Every row probes **two** hostnames through the same Apigee runtime within the
same minute — that pairing is the whole point, because it separates "the
tenant has no DNS/routing" from "the tenant has no DNS/routing *for this
name*":

`cr-hello` is `--ingress=internal`, which turns out to matter independently
(see below), so it is a column rather than a constant — compare rows at equal
ingress:

| # | State | `cr-hello` ingress | Apigee → `*.run.app` | Apigee → `storage.googleapis.com` | VM control |
|---|---|---|---|---|---|
| 0 | Baseline: **no** VPC-SC, no plumbing | `internal` | `404` in 0.36 s (public GFE) | `200` | `200` |
| 1 | `enable-vpc-service-controls` only | `internal` | **`503` `TARGET_CONNECT_TIMEOUT` in 3.26 s** | `200` in 0.76 s | `200` |
| 2 | \+ `dns.peer` \+ peered DNS domain | `internal` | **`404` in 0.067 s** (connected — see below) | `200` | `200` |
| 3 | (row 2 unchanged) | **`all`** | **`200` in 0.058 s** | `200` | `200` |
| 4 | \+ restricted-VIP route \+ custom route export | `all` | `200` in 0.060 s — **no change** | `200` | `200` |
| 5 | (row 4 unchanged) | `internal` | `404` in 0.049 s | `200` | `200` |

Read row 1 against row 0 and the claim inverts: enabling VPC-SC did not make
the DNS peering unnecessary, it is **what made it necessary**. Before
enablement the tenant reached Cloud Run over its own default internet route;
enablement removes that route, and installs a replacement for `googleapis.com`
only. Row 1 is the proof in one line — the googleapis probe returns `200`
through exactly the redirect the support agent is describing, in the same
minute that the `run.app` probe cannot open a socket at all.

Row 4 against row 3 confirms the §4 correction independently, and this time on
a stack that never had them: adding the restricted-VIP route and its
custom-route export changes nothing, `200` either side.

The debug-session trace at row 1 shows the §9 "no socket" signature exactly —
`resolvedAddress`, `connectionStatus` and `tlsHandshakeStatus` are not merely
wrong, they are **absent**:

```text
error.class = com.apigee.errors.http.server.ServiceUnavailableException
error.state = TARGET_REQ_FLOW
state       = TARGET_REQ_FLOW
```

#### The `404` in rows 2 and 3 is a second finding, not a failure of the fix

Connectivity is restored the moment the peered DNS domain exists: the response
time collapses from 3.26 s (timeout, no socket) to ~0.05 s, which is the
restricted VIP answering. The `404` is Google's front end declining to route
the request to an `--ingress=internal` service.

Proved by A/B/A — rows 2→3 and 4→5 above are that experiment, run twice, with
the peering, DNS and routes untouched across the flip:

| `cr-hello` ingress | Apigee → `run.app` | VM → `run.app` |
|---|---|---|
| `internal` | `404` in 0.049 s | `200` |
| **`all`** | **`200` in 0.058 s** | `200` |
| `internal` (restored) | `404` in 0.049 s | `200` |

So the full southbound path — tenant DNS, restricted VIP, TLS, ID-token auth —
works end to end. What the tenant lacks is *admission* to an internal-ingress
service.

**This run could not close why.** Creating the perimeter needs org-level
`roles/accesscontextmanager.policyAdmin`, which the sandbox identity did not
have, so rows 0–3 were all run with **no perimeter at all** — only
`enable-vpc-service-controls` on the peering. Earlier runs in this document
reached `200` from Apigee against the same `--ingress=internal` service *with*
a perimeter in place (the §0 headline `Test 4 [PASS]`), which strongly suggests
the perimeter is what makes the Apigee tenant count as internal. Consistent,
but not demonstrated here — one variable differs, and it is the one we could
not set. Treat it as the next thing to test, not as established.

The practical read either way: **`enable-vpc-service-controls` on the peering
is not sufficient on its own.** It buys `googleapis.com` routing and takes away
the default route. Cloud Run needs the peered DNS domain for connectivity, and
appears to need the perimeter for admission when ingress is `internal`.

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
| VPC-SC perimeter **enforcement** after create | "a few minutes, up to 30" | **highly variable — three instrumented samples: ~1 min, ~35 min, and ~40 min** (probe loop, 60s resolution; creation-to-enforcement, probe-start gaps added). The 2026-08-03 greenfield sample also caught **flapping on a clean perimeter**: first BLOCKED at ~20 min, reverted to OPEN, stable from ~40 min — so require N consecutive confirmations (`CONFIRM=3+`) before trusting the state. Deleting-then-recreating a perimeter interleaves both propagation waves and flaps worse (BLOCKED×3 then OPEN again observed). Treat 30 min as the planning envelope, 40+ min as possible; do not design processes assuming either extreme |
| VPC-SC perimeter deletion | similar | **near-instant in our one measured sample** — already OPEN at the first probe seconds after teardown finished. Asymmetry with creation (~30 min) noted; don't assume either direction's timing from the other |
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
- Don't measure propagation by ad-hoc manual retries — run a probe loop that
  timestamps every attempt and reports the flip
  ([`measure-propagation.sh`](../scripts/option2b/measure-propagation.sh)).
  Manual spot-checks gave us "somewhere between 15 minutes and overnight";
  the loop gives a number.
- Enforcement can **flap** mid-propagation (seen on a clean greenfield
  perimeter, worse on delete-then-recreate) — one BLOCKED probe is not
  arrival; require consecutive confirmations (`CONFIRM=3`, or `5` after a
  delete/recreate).
- Since the split (issue #52), creation-side propagation is **wall-clock
  free**: `setup-early.sh` starts the clock during the ~60–90 min Apigee
  provisioning window, and all three observed samples (1/35/40 min) fit
  inside it — verified greenfield 2026-08-03 (63 min project-to-tested vs
  ~110 min serial).

### The flap: enforcement arrival is not monotonic

The propagation table treats "enforcement arrives" as a single event. It
isn't. On 2026-08-03 we caught the transition mid-flight twice — with the
instrumented probe loop, so the timelines below are logged observations,
not reconstruction from memory. In both cases the perimeter's **state went
BLOCKED, reverted to OPEN, then settled BLOCKED** — a probe that stopped
at the first 403 would have declared victory during a window in which the
perimeter was still intermittently wide open.

**Case 1 — delete then recreate (worst case).** An existing enforcing
perimeter was torn down and an equivalent one created ~1 minute later
(verifying the #52 split on a non-greenfield project). The two propagation
waves interleaved:

| Wall clock | Observation |
|---|---|
| ~15:25 | old perimeter deleted (had been enforcing for ~5.5 h) |
| ~15:26 | new perimeter created, API reports ENFORCED |
| 15:30–15:32 | probe: **BLOCKED ×3 consecutive** — looked arrived |
| 15:33–15:40 | test suite: **OPEN** — three 200s a minute apart |
| ~15:55 | probe (`CONFIRM=5`): BLOCKED, stable from here on |

Net: ~30 minutes of ambiguity in which *both* "it's enforcing" and "it's
not enforcing" were observable minutes apart. Our first probe run
confirmed ×3 and exited green at 15:32; the test suite then read the
opposite. Without the timestamped probe logs this would have looked like a
broken test, and this doc's older self would have said "propagation, wait
30 minutes" — the truth was messier: it had *arrived and left again*.

**Case 2 — clean greenfield creation (no prior perimeter, ever).** Same
shape, which is the important part — flapping is not an artifact of
delete/recreate interleaving:

| Wall clock | Observation |
|---|---|
| 17:37 | perimeter created on a fresh project, API reports ENFORCED |
| 17:39–17:55 | probe: OPEN throughout |
| 18:00 | probe: **BLOCKED** (first confirmation) |
| 18:01–18:15 | probe: **OPEN again** — confirmation counter reset |
| 18:17–18:19 | probe: BLOCKED ×3 consecutive, stable from here on |

Net: first flip at ~20 min, stable at ~40 min, with a reversion in
between on a perimeter that had never existed before.

**Reading it.** We can't see inside the control plane, but the shape is
consistent with enforcement rolling out across multiple enforcement points
that converge at different times: mid-window, consecutive requests hit
differently-converged paths and get different answers. Caveats on the
data: 60 s probe resolution, one probe target (the storage negative test),
one VM vantage point, n=2 flap observations — enough to prove flapping
happens, not enough to characterise its distribution.

**What this changes in practice:**

- A single 403 is not "enforced", and — worse for compliance — a
  *confirmed streak* early in the window is still not "enforced for good".
  If the perimeter is load-bearing for a change window, verify at the
  point of need, not once at arrival.
- `measure-propagation.sh`'s `CONFIRM` knob exists for this. `CONFIRM=3`
  caught Case 2's reversion (counter reset); it was fooled in Case 1
  (three greens inside a flap). After a delete/recreate, use `CONFIRM=5`.
- Symmetrically, assume the mid-window perimeter provides only
  **intermittent** protection: for real environments, treat the window
  between create and stable-confirm as *unprotected* for planning
  purposes.
- Test suites should never anchor pass/fail on a single early negative
  probe; re-run after a settle period before debugging (we lost a cycle to
  exactly this in Case 1).

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

## 7. Finding denials in Cloud Audit Logs

Every VPC-SC denial lands in the project's **Policy Denied** audit log
(`cloudaudit.googleapis.com/policy`) — enabled by default. For egress
violations (a caller inside your perimeter reaching out), the entry is in
*your* project, not the target's. Two query recipes, both validated live:

```bash
# By the unique ID from a storage-API denial response:
gcloud logging read \
  'protoPayload.metadata.vpcServiceControlsUniqueId="<ID>"' \
  --project=<project> --freshness=3h

# All Cloud Run denials (the HTML 403s give you no ID — sweep by service):
gcloud logging read 'logName="projects/<project>/logs/cloudaudit.googleapis.com%2Fpolicy"
  AND protoPayload.serviceName="run.googleapis.com"' \
  --project=<project> --freshness=3h
```

What the entries contain (far more than any client-visible error):
`violationReason`, the perimeter name, the caller IP, the **target project
number**, the permission that was attempted (`storage.buckets.get`,
`run.routes.invoke`), and a `vpcServiceControlsTroubleshootToken` for the
console's VPC-SC troubleshooter.

The denials from our two blocked probes, side by side — note how the source
attribution differs:

| Field | VM probe | Apigee probe |
|---|---|---|
| `methodName` | `run.googleapis.com/HttpIngress` | `run.googleapis.com/HttpIngress` |
| `callerIp` | `10.0.0.2` (the VM) | `gce-internal-ip` |
| `source` | `projects/<num>` | `projects/<num>/[servicenetworking.googleapis.com]` |
| `sourceType` | `Network` | `Resource` |
| `violationReason` | `NETWORK_NOT_IN_SAME_SERVICE_PERIMETER` | `RESOURCES_NOT_IN_SAME_SERVICE_PERIMETER` |

The Apigee row is the notable one: the tenant's southbound traffic is
attributed as a **servicenetworking-attached resource of the customer
project** — direct audit-log evidence that `enable-vpc-service-controls` on
the peering makes Apigee "inside" the perimeter, exactly the mechanism §4
relies on. It also means Apigee-originated denials are distinguishable from
VM/workload-originated ones at a glance, which your SOC will appreciate.

One caution when turning a denial into an egress allow rule: the entry's
`targetResource` is exactly what the rule's `resources:` needs, but the
`targetResourcePermissions` value is **not** valid `methodSelector` syntax —
`run.routes.invoke` was rejected with `INVALID_ARGUMENT` when used as a
`permission:` selector for `run.googleapis.com`. Use `method: '*'` scoped by
target project (§1 has the working rule).

## 8. Checklist for implementing teams

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
- [ ] Private `run.app` zone points at the **restricted** VIP
      (`199.36.153.4-7`) — **not** the private VIP (`199.36.153.8-11`), which
      the tenant cannot route to at all (§4.1)
- [ ] All three checks run against the project owning the Apigee
      `authorizedNetwork` — under Shared VPC that is the **host** project, not
      the Apigee org's project (§9)
- [ ] A negative test that proves denial of out-of-perimeter access
- [ ] Time budgeted for enforcement propagation (hours, pessimistically)
- [ ] Teardown tested — perimeters, policies, peered DNS domains and route
      exports all need explicit reversal

---

## 9. Differential diagnosis: telling the failure modes apart

Everything below was reproduced live on 2026-09-04 by breaking one thing at a
time on a working stack and reverting it, on the PoC's single-project
topology.

### Where to run the checks

Every check anchors on the Apigee org's `authorizedNetwork` — the VPC the
tenant peers to — and **the project that owns that VPC**. None of them are
about the workloads/Cloud Run project. Read the anchor first:

```bash
curl -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://apigee.googleapis.com/v1/organizations/<ORG>"   # eu-/us- per residency
```

The **format** of `authorizedNetwork` tells you which project to use:

| Value | Meaning | Run checks against |
|---|---|---|
| `my-vpc` (bare name) | VPC is in the Apigee org's own project | the Apigee org project |
| `projects/HOST/global/networks/my-vpc` | **Shared VPC** | the **host** project |

Under Shared VPC the `dns.peer` grant is a *cross-project* grant, and easy to
get wrong: the service agent is named for the **Apigee org project's** number,
but the binding must be applied on the **host** project that owns the network
and the DNS zone. (Documented structure — our PoC is single-project, so this
split is not something we exercised.)

### What each break looks like

| Broken | Path that breaks | HTTP | Signature | Time to fail |
|---|---|---|---|---|
| Peered DNS domain deleted | **Apigee only** | `503` | `messaging.adaptors.http.flow.ServiceUnavailable` / `reason: TARGET_CONNECT_TIMEOUT` | ~3.0 s |
| Zone points at private VIP (§4.1) | **Apigee only** | `503` | identical to above | ~3.0 s |
| Egress firewall deny to the VIP | **workloads only** | `000` | no response at all — silent drop, no RST, no ICMP | client timeout (30 s) |
| `restricted-vip` route deleted | neither | — | no effect (§4) | — |

Two things worth internalising:

- **`TARGET_CONNECT_TIMEOUT` fires in ~3 seconds, not 30.** It reads like a
  fast failure, which is why it gets misfiled as something other than a
  connectivity problem.
- **The DNS and firewall failures break *opposite* paths**, so one test
  discriminates: an authenticated `curl` to the Cloud Run URL from a VM in the
  Apigee-peered VPC. VM fine + Apigee timing out → tenant DNS/routing. VM also
  broken → your own egress path. They cannot both be true.

### Firewall rules are not in the Apigee path

Proved by construction: an egress `DENY tcp:443 → 199.36.153.4/30` in the
Apigee VPC killed the VM path stone dead (`HTTP 000`, 30 s, silent drop) while
the Apigee path was **unaffected** (`404` in 0.2 s — still reaching the front
end). Apigee southbound originates in the Google-owned tenant network; peering
firewall rules are non-transitive, and your hierarchical policies do not reach
that project either. Removing the rule restored the VM path in ~20 s.

So no firewall rule of yours can cause the Apigee→Cloud Run timeout. They
*can* cause an identical-looking timeout for your own workloads — GCP denies
drop silently — which is exactly why the two get confused. (Deny-by-default
egress orgs still need `tcp:443` to `199.36.153.4/30` for their own workloads;
just not for the Apigee leg.)

### "No logs on the Cloud Run side" proves nothing

Cloud Run request logs recorded **only** the VM-originated calls. Not one
Apigee-originated request appeared — including ones that demonstrably reached
Google's front end and came back `404` (debug trace: TLS handshake completed,
response returned). Front-end rejections never reach the service's request log.

Silence in Cloud Run is therefore equally consistent with:

| Reality | Apigee-side signal | Cloud Run logs |
|---|---|---|
| Never reached Google (DNS/routing) | `503 TARGET_CONNECT_TIMEOUT` | nothing |
| Reached the GFE, rejected there (Host mismatch, IAM, VPC-SC) | `404`/`403` propagated; `BadGateway` in trace | nothing |
| Reached the service | `2xx` or app error | logged |

The discriminator lives on the Apigee side, not the Cloud Run side.

### Read it from a debug session in one request

`POST .../apis/<proxy>/revisions/<rev>/debugsessions?timeout=<secs>`, send a
request, then `GET .../debugsessions/<id>/data/<txn>`:

| Working | Failing (no route) |
|---|---|
| `targetendpoint_default.resolvedAddress = 199.36.153.7` | **field absent** |
| `connectionStatus = CONNECTED` | **field absent** |
| `tlsHandshakeStatus = COMPLETED` | **field absent** |
| `error.class = …BadGateway` (a response came back) | `…ServiceUnavailableException` |
| `state = TARGET_RESP_FLOW` | `state = TARGET_REQ_FLOW` |

The connection fields do not merely show failure — they **do not exist**,
because no socket was created. Fastest "did we ever get a TCP connection?"
test available, and it costs one request.

Two gotchas: a debug session needs ~60 s to propagate to the message processor
before it captures anything (create it, wait, *then* send traffic), and an
active session appears to force a fresh connection (`isFromClientPool=false`),
so traced requests run slower than untraced ones — do not read latency
differences between traced and untraced runs as signal.

`target_info.header.*` in the trace is also where you catch a wrong outbound
`Host`: Apigee preserves the *inbound* `Host` (the env-group hostname) on the
target call unless you rewrite it, and Cloud Run's front end routes by `Host`,
so an unrewritten one returns a generic `404`. Fixed in
[`shared/lib/apigee-proxy.sh`](../scripts/shared/lib/apigee-proxy.sh) with a
`SetHostHeader` `AssignMessage`.

### Observed propagation, this run

| Change | Effect visible after | Recovery after revert |
|---|---|---|
| Peered DNS domain delete / create | ~1 min | ~70 s |
| DNS record repoint (TTL 60 s) | < 90 s | < 90 s |
| Firewall rule add / delete | < 20 s | ~20 s |
| Custom route delete | no effect at all (§4) | — |

Note how different these are from VPC-SC perimeter propagation (§5, 1–40 min
and non-monotonic). If you change DNS or a firewall rule and the symptom has
not moved within a couple of minutes, that change was not the cause.

---

## 10. Pointers

- Working scripts: [`scripts/option2b/`](../scripts/option2b/) (setup, test
  with real PASS/FAIL reporting, teardown)
- Architecture reference: [option-b-pga.md](option-b-pga.md)
- DNS background: [dns-guide.md](dns-guide.md) (restricted vs private VIP)
- Apigee VPC-SC docs: <https://cloud.google.com/apigee/docs/api-platform/security/vpc-sc>
- Peered DNS domains: <https://cloud.google.com/sdk/gcloud/reference/services/peered-dns-domains>
