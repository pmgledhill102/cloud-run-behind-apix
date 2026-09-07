# Documentation citations for the DNS-peering finding

**For:** a Google Customer Engineer or support engineer checking the claims in
[`dns-peering.md`](dns-peering.md) against Google's own published documentation.
**Companion to:** [`dns-peering.md`](dns-peering.md) — that page carries the live
evidence, this one carries the paper trail.
**All sources accessed:** 2026-09-07.

Every quotation below is verbatim, taken from the raw page rather than
transcribed from memory, with the exact URL alongside. Where a page is silent on
something, this page says so explicitly — for this argument an **absence is a
finding**, not a gap in the research.

---

## 0. Read this first — where our position is weakest

Two things a reviewer will find on their own. Better that we name them.

**The fuller zone list (§2) is not on a `cloud.google.com` page.** It is
Google-authored — it originates in the API resource description that flows
through magic-modules into the provider documentation — but it is hosted by
HashiCorp and Pulumi. A support engineer may fairly decline it as "not our
documentation". It is quoted here because it is the longest enumeration Google's
tooling publishes anywhere and `run.app` is still absent from it, but it should
be offered as corroboration, never as the load-bearing citation.

**No Google page connects peered DNS domains to VPC Service Controls.** In
either direction, on any page checked. The Apigee VPC-SC guide addresses only the
*routing* half of the problem and does not discuss DNS at all. The specific
remedy this repository documents — a servicenetworking peered DNS domain for
`run.app`, resolving through a consumer-side zone that points at the restricted
VIP — appears in no Google document. That is an absence rather than a
contradiction, and it cuts both ways: the support agent has no citation for the
inverse claim either. But a reviewer may treat our combination as unsupported
rather than as refuted, and we should not be surprised by that.

Beyond these two, **nothing in Google's documentation supports the claim in
[`dns-peering.md`](dns-peering.md) §1.** No page, anywhere, states that enabling
VPC Service Controls redirects `run.app`.

---

## 1. `gcloud services vpc-peerings enable-vpc-service-controls`

**URL:** <https://cloud.google.com/sdk/gcloud/reference/services/vpc-peerings/enable-vpc-service-controls>
(redirects to `docs.cloud.google.com`) · Page footer: "Last updated 2026-05-27 UTC."

The `DESCRIPTION` section in full:

> This command configures IPv4 routes and DNS zones applicable to a service producer VPC network (for example, servicenetworking). The route and DNS configuration match those recommended for using the restricted.googleapis.com VIP:
>
> When enabled, Google Cloud makes the following route configuration changes in the service producer VPC network: Google Cloud removes the IPv4 default route (destination 0.0.0.0/0, next hop default internet gateway). Google Cloud then creates an IPv4 route for destination 199.36.153.4/30 using the default internet gateway next hop.
>
> When enabled, Google Cloud also creates Cloud DNS managed private zones and authorizes those zones for the service producer VPC network. The zones include googleapis.com, pkg.dev, gcr.io, and other necessary domains or host names for Google APIs and services that are compatible with VPC Service Controls. Record data in the zones resolves all host names to 199.36.153.4, 199.36.153.5, 199.36.153.6, and 199.36.153.7.
>
> When disabled, Google Cloud makes the following route configuration changes in the service producer VPC network: Google Cloud restores a default route (destination 0.0.0.0/0, next hop default internet gateway). Google Cloud also deletes the Cloud DNS managed private zones that provided the host name overrides.
>
> While enabled, the service producer VPC network can still import static and dynamic routes from the peered customer network if you enable custom route export. These custom routes can include a default route. For this reason, this command is not to be used solely as a means for preventing access to the internet.

The zone sentence, isolated because [#94](https://github.com/pmgledhill102/cloud-run-behind-apix/issues/94)
turns on its vagueness — note the ordering `pkg.dev, gcr.io`, which the fuller
list in §2 reverses:

> The zones include googleapis.com, pkg.dev, gcr.io, and other necessary domains or host names for Google APIs and services that are compatible with VPC Service Controls.

**Does `run.app` appear anywhere on this page? No — zero occurrences** in the raw
HTML of the whole page, not merely in the `DESCRIPTION`.

**Establishes:** Both halves of the mechanism in
[`dns-peering.md`](dns-peering.md) §6, in adjacent paragraphs of Google's own
reference — the default route is removed, and the compensating zones are
enumerated without Cloud Run.

---

## 2. The fuller zone list

**Finding: this list does not appear on any `cloud.google.com` page.** An
exact-phrase search returns the Terraform Registry as the only literal match. The
candidate Google pages were checked individually and ruled out:

| Page | URL | Carries the list? |
|---|---|---|
| Backup and DR VPC-SC config | `docs.cloud.google.com/backup-disaster-recovery/docs/configuration/vpc-sc` | **No** — instructs the reader to create `*.googleapis.com`, `*.backupdr.cloud.google.com` and `*.backupdr.googleusercontent.com` zones *manually* |
| VPC-SC private connectivity | `docs.cloud.google.com/vpc-service-controls/docs/set-up-private-connectivity` | **No** — no `backupdr`, `kernels`, `notebooks` or `run.app` at all |
| Service Networking REST, `enableVpcServiceControls` | `docs.cloud.google.com/service-infrastructure/docs/service-networking/reference/rest/v1/services/enableVpcServiceControls` | **No** — carries no zone list |
| Configure private services access | `docs.cloud.google.com/vpc/docs/configure-private-services-access` | **No** |

The canonical carrier is the provider documentation, generated from Google's own
API resource description:

**URL:** <https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/service_networking_vpc_service_controls>
**Source text:** <https://raw.githubusercontent.com/hashicorp/terraform-provider-google/main/website/docs/r/service_networking_vpc_service_controls.html.markdown>
**Mirrored:** <https://www.pulumi.com/registry/packages/gcp/api-docs/servicenetworking/vpcservicecontrols/>

> When enabled, Google Cloud makes the following
> route configuration changes in the service producer VPC network:
>
> - Removes the IPv4 default route (destination 0.0.0.0/0,
>   next hop default internet gateway), Google Cloud then creates an
>   IPv4 route for destination 199.36.153.4/30 using the default
>   internet gateway next hop.
> - Creates Cloud DNS managed private zones and authorizes those zones
>   for the service producer VPC network. The zones include
>   googleapis.com, gcr.io, pkg.dev, notebooks.cloud.google.com,
>   kernels.googleusercontent.com, backupdr.cloud.google.com, and
>   backupdr.googleusercontent.com as necessary domains or host names
>   for Google APIs and services that are compatible with VPC Service
>   Controls. Record data in the zones resolves all host names to
>   199.36.153.4, 199.36.153.5, 199.36.153.6, and 199.36.153.7.

**Is `run.app` in that list, on any page? No.**

**Establishes:** The strongest available form of the omission, subject to the
hosting caveat in §0. Where the gcloud reference says "and other necessary
domains", this spells out what "other" means: seven domains, including two
obscure Backup-and-DR hosts, and Cloud Run is not among them.

---

## 3. Configure Private Google Access — additional domains

**URL:** <https://cloud.google.com/vpc/docs/configure-private-google-access>

From **"Configure DNS for other domains"**:

> Some Google APIs and services are provided using additional domain names, including `*.gcr.io`, `*.gstatic.com`, `*.pkg.dev`, `pki.goog`, `*.run.app`, and `*.gke.goog`. Refer to the *domain and IP address ranges table* in Domain options to determine if the additional domain's services can be accessed using `private.googleapis.com` or `restricted.googleapis.com`. Then, for each of the additional domains:
>
> 1. Create a DNS zone for `DOMAIN` (for example, `gcr.io`). If you're using Cloud DNS, make sure this zone is located in the same project as your `googleapis.com` private zone.
>
> 2. In this DNS zone, create the following private DNS records for *either* `private.googleapis.com` or `restricted.googleapis.com`, depending on which domain you've chosen to use.
>
>     - For `restricted.googleapis.com`:
>
>       1. Create an `A` record for `DOMAIN` pointing to the following IP addresses: `199.36.153.4`, `199.36.153.5`, `199.36.153.6`, `199.36.153.7`.
>
> 3. In the `DOMAIN` zone, create a `CNAME` record for `*.``DOMAIN` that points to `DOMAIN`. For example, create a `CNAME` record for `*.gcr.io` that points to `gcr.io`.

And from the DNS configuration summary:

> If you use services that have other domain names, see Configure DNS for other domains. For example, if you use Google Kubernetes Engine (GKE), you also need to configure `*.gcr.io` and `*.pkg.dev`, or if you use Cloud Run, you need to configure `*.run.app`.

**A nuance on the same page, which a reviewer may raise.** In the *Domain
options* table, `*.run.app` is enumerated in the **`private.googleapis.com`**
row's list of supported domain names. The `restricted.googleapis.com` row
enumerates no domains at all, saying only:

> Enables API access to Google APIs and services that are supported by VPC Service Controls.

So the table never explicitly lists `run.app` under `restricted`; it resolves by
reference to the supported-products page, where Cloud Run is GA (§8). This does
not weaken our position — §4b shows Google itself mapping `*.run.app` to the
restricted VIP — but it is the kind of detail worth having an answer ready for.

**Establishes:** Google classifies `run.app` as an *additional* domain that the
customer must create a zone for. That is the opposite of something enablement
provides automatically.

---

## 4. Private networking and Cloud Run

**URL:** <https://cloud.google.com/run/docs/securing/private-networking>

> - The most direct path is to enable Private Google Access on the subnets that host your resources. When Private Google Access is enabled, resources on the subnets can access your Cloud Run resources at the default `run.app` URL. Traffic from your VPC network to Cloud Run stays in Google's network.
> - If you need your Cloud Run resource (together with other Google APIs) to be accessible through an internal IP address in your VPC network, consider creating a Private Service Connect endpoint and configuring a private DNS zone for `run.app`. With this configuration, resources in the VPC network can access Cloud Run resources at the default `run.app` URL through the Private Service Connect endpoint IP address.

On the choice of VIP:

> - Enable Private Google Access on the subnet associated with the *source* resource and configure DNS to resolve `run.app` URLs to the `private.googleapis.com` (`199.36.153.8/30`) or `restricted.googleapis.com` (`199.36.153.4/30`) ranges. Requests to these ranges are routed through the VPC network.

Relevant to the peered topology, and to the `--ingress=internal` finding in
[`dns-peering.md`](dns-peering.md) §6.1:

> Peering with a VPC network that is outside of your project doesn't allow traffic to be recognized as "internal."

**Establishes:** Resolving `run.app` privately is always an explicit
"configure DNS" action by the customer. Both VIPs are offered, and neither is
automatic — which is also the documentary backdrop to the private-VIP trap in
[`dns-peering.md`](dns-peering.md) §6.2.

### 4b. Cloud Run's own VPC Service Controls guide — the decisive citation

**URL:** <https://docs.cloud.google.com/run/docs/securing/using-vpc-service-controls>

This is the page the VPC-SC supported-products entry (§8) sends the reader to for
"additional setup". Under **Set up your project to support VPC Service
Controls → Configure VPC networks**, steps 4 and 5 are *separate* steps:

> 4. Add a rule to the response policy to resolve `*.googleapis.com` to `restricted.googleapis.com`. The IP address range for `restricted.googleapis.com` is `199.36.153.4/30`.
>
> 5. Add a rule to the response policy to resolve `*.run.app` (or `*.cloudfunctions.net` if you created your function using `gcloud functions deploy`) to the `restricted.googleapis.com`. The IP address range for `restricted.googleapis.com` is `199.36.153.4/30`.

**Establishes:** The cleanest refutation available on paper. Google's own VPC-SC
setup guide for Cloud Run requires the operator to add a
`*.run.app` → `restricted.googleapis.com` rule as a distinct manual step, *after*
the `*.googleapis.com` rule. If enabling VPC-SC redirected `run.app`
automatically, step 5 would not exist. It also settles the §3 nuance: `run.app`
does belong on the restricted VIP, and putting it there is the customer's job.

Note the scope difference when citing this: these steps configure the
**consumer** VPC network, not the Apigee tenant. The Apigee tenant is not
customer-configurable, which is exactly why the peered DNS domain is the only
lever available there.

---

## 5. Using VPC Service Controls with Apigee

**URL:** <https://cloud.google.com/apigee/docs/api-platform/security/vpc-sc>
("Using VPC Service Controls with Apigee and Apigee hybrid")

**Does it warn that the default internet route is removed?** It states the
consequence rather than naming the route object. Section **"Impact on internet
connectivity"**, in full — this is the entire section:

> When VPC Service Controls are enabled, access to the internet is disabled: the Apigee runtime will no longer communicate with any public internet target. You have to route traffic to your VPC by establishing custom routes. See Importing and exporting custom routes.

The setup step:

> 1. Enable VPC Service Controls for the peered connection from your network to Apigee by executing the following command:
>
>     `gcloud services vpc-peerings enable-vpc-service-controls --network=SHARED_VPC_NETWORK --project=PROJECT_ID`

And on the provisioning model, which decides the whole question:

> **Note**: VPC Service Controls are not supported for the non-VPC peering Apigee setup.

**Does it mention `run.app`? No — zero occurrences on the entire page.**
**Does it mention peered DNS domains? No — zero occurrences of "peered DNS",
"peered-dns-domains", or any DNS-peering concept. The page does not discuss DNS
at all.**

**Establishes:** In the Apigee context specifically, Google confirms that
enabling VPC-SC *disables* the runtime's reachability to public targets and that
the customer must add configuration to restore it. That is the direct inverse of
"VPC-SC removes the need for configuration" — the causality in the claim is
inverted, in Google's own words.

The silence is the other half of the finding, and it is the basis for
[`dns-peering.md`](dns-peering.md) §8 ask 4: the page's only stated remedy is
custom routes, so a reader following it exactly will fix the routing and still
have no `run.app` resolution.

---

## 6. Apigee peered DNS domains

There is no single Apigee page for this. The requirement is spread across four.

**6a. Command reference** —
<https://cloud.google.com/sdk/gcloud/reference/services/peered-dns-domains/create>

> This command creates a peered DNS domain for a private service connection which sends requests for records in a given namespace originating in the service producer VPC network to the consumer VPC network to be resolved.

**6b. Configure private services access**, "Share private DNS zones with service
producers" — <https://docs.cloud.google.com/vpc/docs/configure-private-services-access>

> Cloud DNS private zones are private to your VPC network. If you want to let a service producer network resolve names from your private zone, you can configure DNS peering between the two networks.
>
> When you configure DNS peering, you provide a VPC network and a DNS suffix. If the service producer needs to resolve an address with that DNS suffix, the service producer forwards those queries to your VPC network to be resolved.

**6c. Apigee troubleshooting playbook** —
<https://docs.cloud.google.com/apigee/docs/api-platform/troubleshoot/playbooks/runtime/target-connect-host-not-reachable>

From the "Possible Causes" table:

> | DNS peering is not configured | This issue could occur when Apigee is not able to resolve the domain name if DNS peering is not configured in Apigee deployments. | Apigee |

From the Resolution:

> 1. Make a note of the DNS suffix, project ID, and network in which the target endpoint is hosted.
> 2. Create a peered DNS domain for the DNS suffix.
>
>     If your organization is VPC peering enabled, use the `peered-dns-domains create` gcloud command. Note that the DNS suffix should contain a trailing dot at the end of the DNS suffix:
>
>     `gcloud services peered-dns-domains create NAME --network=NETWORK --dns-suffix=DNS-SUFFIX. --project=PROJECT-ID`

**6d. Southbound networking patterns** —
<https://docs.cloud.google.com/apigee/docs/api-platform/architecture/southbound-networking-patterns-endpoints>

> To do its job, Apigee needs to connect to backend targets that you manage. These targets may be resolvable through a public or private DNS. If the target is publicly resolvable, then there's no problem, the Apigee backend target points to the public address of the service. Private endpoints can be static IP addresses or resolvable DNS names that you host and manage. To resolve private target endpoints, it is common to maintain a private DNS zone hosted in your Google Cloud project. By default, these private DNS names cannot be resolved by Apigee.

**When is it required?** Google frames it consistently as: when Apigee must
resolve a name that is not publicly resolvable.

**Does any page connect it to VPC-SC being enabled? No.** This is the gap named
in §0. It also means the support agent has no citation for the inverse.

It is worth noting *why* Google's framing does not reach our case on its own.
`run.app` **is** publicly resolvable — so by 6d's logic a peered DNS domain
should be unnecessary. It becomes necessary only because
`enable-vpc-service-controls` removed the route to those public addresses (§1),
which is a fact documented on a different page that never mentions DNS. The two
halves of the argument live in two documents that do not reference each other.
That is the documentation defect, stated precisely.

---

## 7. `servicenetworking.services.listDnsZones`

**Permission confirmed** —
<https://docs.cloud.google.com/service-infrastructure/docs/service-networking/reference/rest/v1/services.projects.global.networks.dnsZones/list>

> Authorization requires the following IAM permission on the specified resource `parent`:
>
> - `servicenetworking.services.listDnsZones`

**Predefined roles** —
<https://docs.cloud.google.com/iam/docs/roles-permissions/servicenetworking>

The page lists five roles. Every `servicenetworking.services.*` permission
rendered anywhere on it:

`addDnsRecordSet`, `addDnsZone`, `addPeering`, `addSubnetwork`,
`createPeeredDnsDomain`, `deleteConnection`, `deletePeeredDnsDomain`,
`disableVpcServiceControls`, `enableVpcServiceControls`, `get`,
`getConsumerConfig`, `getVpcServiceControls`, `listPeeredDnsDomains`,
`removeDnsRecordSet`, `removeDnsZone`, `updateConsumerConfig`,
`updateDnsRecordSet`, `use`

`listDnsZones` does not appear — zero occurrences on the page. The near-neighbour
`listPeeredDnsDomains` **is** present in all four non-agent roles, so this is a
specific omission rather than a rendering failure.

**State this precisely, because there is a wildcard.**
`roles/servicenetworking.admin` and `roles/servicenetworking.networksAdmin` are
rendered with a `servicenetworking.*` entry alongside their explicit lists. Read
literally, such a wildcard would encompass `listDnsZones`. The live check
recorded in [#94](https://github.com/pmgledhill102/cloud-run-behind-apix/issues/94)
is the authoritative result — the permission is not testable on a consumer
project and the call returns `PERMISSION_DENIED` — so treat the wildcard as a
display artefact of the roles page. The accurate claim is: **not enumerated in
any predefined role, and empirically not grantable consumer-side.**

**Establishes:** Enumerating the producer-side zones — the one move that would
settle whether a `run.app` zone exists — is not available to the customer. This
is why [`dns-peering.md`](dns-peering.md) infers the zone set from probe
behaviour instead of reading it, and why #94 exists.

---

## 8. VPC Service Controls supported products — Cloud Run

**URL:** <https://cloud.google.com/vpc-service-controls/docs/supported-products>

The Cloud Run entry:

> **Cloud Run**
>
> **Status:** GA. This product integration is fully supported by VPC Service Controls.
>
> **Protect with perimeters?** Yes. You can configure your perimeters to protect this service.
>
> **Service name:** `run.googleapis.com`
>
> **Details:** Additional setup for Cloud Run is required. Follow the instructions at the Cloud Run VPC Service Controls documentation page.

From the same entry's Limitations:

> - Enforcement of VPC Service Controls egress policy is only guaranteed when using the restricted virtual IP (VIP) address.

**Establishes — and this is the section that makes the brief diagnostic rather
than merely contradictory.** Cloud Run is a GA, fully supported VPC-SC product.
That is almost certainly the true premise the support agent reasoned from, and
conflating it with DNS coverage is the likeliest origin of the claim. The entry
draws the distinction itself: support is a property of the **service**
`run.googleapis.com` — it can be placed in a perimeter, and the restricted VIP
will carry its traffic. A producer-side DNS zone is a property of the
**hostname** `run.app`. `enable-vpc-service-controls` provisions zones for the
second category, and Cloud Run is not among them.

The entry's own "Additional setup for Cloud Run is required" links to §4b, whose
step 5 is the manual `*.run.app` mapping.

The one-line form, for an escalation: **supported product, and still no
producer-side DNS zone for `run.app`.**

The final Limitations bullet is also worth carrying across to
[`dns-peering.md`](dns-peering.md) §6.2 — it is Google stating that the private
VIP does not guarantee egress enforcement, which is the documentary counterpart
to the compliance consequence recorded there.

---

## 9. Summary

| Claim | Verdict | Source |
|---|---|---|
| `enable-vpc-service-controls` creates producer-side DNS zones for `googleapis.com`, `pkg.dev`, `gcr.io` and others | **Supported** | §1 |
| Those zones do **not** include `run.app` | **Supported** — absent from the gcloud page entirely, and from the 7-domain fuller list | §1, §2 |
| `enable-vpc-service-controls` removes the tenant's default internet route | **Supported**, verbatim | §1, §5 |
| Enabling VPC-SC redirects DNS to `restricted.googleapis.com`, so a peered DNS domain is not required *(the claim)* | **Refuted** — the redirect covers only the enumerated zones, and Google's own Cloud Run VPC-SC guide requires a manual `*.run.app` rule | §1, §2, §4b |
| Enabling VPC-SC removes the need for network routes *(the claim)* | **Refuted** — "access to the internet is disabled… You have to route traffic to your VPC by establishing custom routes" | §5 |
| Reaching Cloud Run privately requires the customer to configure `run.app` DNS themselves | **Supported** — `run.app` is an "additional domain" needing a self-created zone | §3, §4, §4b |
| Cloud Run is a VPC-SC supported product | **Supported** — GA, `run.googleapis.com` | §8 |
| Supported-product status implies a producer-side `run.app` DNS zone | **Refuted** — the entry itself states "Additional setup for Cloud Run is required" | §8, §4b |
| `dnsZones.list` requires `servicenetworking.services.listDnsZones` | **Supported**, verbatim | §7 |
| That permission is available in a predefined role | **Not addressed / omitted** — not enumerated in any of the five roles; see the wildcard caveat and [#94](https://github.com/pmgledhill102/cloud-run-behind-apix/issues/94) | §7 |
| The fuller zone list appears on a `cloud.google.com` page | **Refuted** — provider docs only; absent from all four candidate Google pages | §2 |
| Any Google page connects peered DNS domains to VPC-SC being enabled | **Not addressed** — no such statement in either direction, on any page checked | §0, §5, §6 |

## 10. Method

Each page was fetched as raw HTML with `curl` and converted with `pandoc`, then
quoted from the converted text, so the wording here is the page's own rather
than a summary of it. Absence claims ("zero occurrences") were checked by
grepping the raw HTML of the whole page, not the rendered article body, so
navigation, footnotes and collapsed sections are included in the check.

Sixteen pages were retrieved in total; the twelve that carry a citation appear
above. The four ruled out for §2 are listed in that section's table, since a
negative result there is part of the finding.
