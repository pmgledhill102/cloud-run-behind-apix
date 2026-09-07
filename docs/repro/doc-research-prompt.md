# Prompt: gather Google documentation references for the VPC-SC / `run.app` question

**Why this file exists.** The agent sandbox this PoC runs in blocks
`docs.cloud.google.com` at the egress proxy, so a session there cannot read
Google's documentation directly — it can only reach the `gcloud` CLI's built-in
help text and web-search snippets. Everything documentary in
[`dns-peering.md`](dns-peering.md) therefore needs confirming from a session with
unrestricted internet access.

Paste the block below into such a session. It is written to be self-contained.

---

## The prompt

> I need you to gather and quote Google Cloud documentation to settle a specific
> technical dispute. Accuracy of quotation matters more than analysis — I need
> **verbatim text with URLs**, because this is going to a Google Cloud support
> engineer and any paraphrase will be challenged.
>
> ### The dispute
>
> A Google support agent claimed:
>
> > "The peered DNS domain and the network routes aren't required if VPC Service
> > Controls is enabled, because enabling it redirects the DNS to
> > `restricted.googleapis.com` anyway."
>
> This is about **Apigee X provisioned with the VPC Peering model** (not PSC),
> calling a **Cloud Run** service at its `*.run.app` URL.
>
> Our position is that `gcloud services vpc-peerings enable-vpc-service-controls`
> creates producer-side DNS zones covering `*.googleapis.com` and friends but
> **not `run.app`**, and separately removes the tenant's default internet route —
> so enabling VPC-SC is what *creates* the need for a peered DNS domain, not what
> removes it.
>
> ### What I need, page by page
>
> For each of these, quote the relevant passages **verbatim**, give the exact
> URL, and note the date you accessed it. If a page does *not* mention something
> I ask about, say so explicitly — an absence is a finding here, not a gap.
>
> 1. **`gcloud services vpc-peerings enable-vpc-service-controls` reference**
>    <https://cloud.google.com/sdk/gcloud/reference/services/vpc-peerings/enable-vpc-service-controls>
>    - The full DESCRIPTION section verbatim.
>    - Confirm whether the phrase is exactly *"The zones include googleapis.com,
>      pkg.dev, gcr.io, and other necessary domains or host names for Google APIs
>      and services that are compatible with VPC Service Controls."*
>    - Does the word `run.app` appear anywhere on the page?
>
> 2. **The fuller zone list.** Somewhere in Google's docs a longer list appears,
>    naming `googleapis.com`, `gcr.io`, `pkg.dev`, `notebooks.cloud.google.com`,
>    `kernels.googleusercontent.com`, `backupdr.cloud.google.com` and
>    `backupdr.googleusercontent.com`. **Find the canonical page(s) that carry
>    it.** Candidates: the Backup and DR VPC-SC configuration page, the Service
>    Networking "enable VPC Service Controls" docs, the VPC-SC private
>    connectivity page. I need the exact URL and the exact list as published.
>    **Critically: is `run.app` in that list, on any page?**
>
> 3. **Configure Private Google Access**
>    <https://cloud.google.com/vpc/docs/configure-private-google-access>
>    - The section on configuring DNS for additional domains.
>    - Quote exactly what it says about `run.app` — I believe it instructs you to
>      create your own private zone for `run.app` with a `*.run.app` CNAME to
>      `restricted.googleapis.com`. Confirm or correct that, verbatim.
>
> 4. **Private networking and Cloud Run**
>    <https://cloud.google.com/run/docs/securing/private-networking>
>    - What it says about resolving `run.app` privately, and about
>      `restricted.googleapis.com` vs `private.googleapis.com`.
>
> 5. **Using VPC Service Controls with Apigee**
>    <https://cloud.google.com/apigee/docs/api-platform/security/vpc-sc>
>    - Everything it says about the peered connection, about the tenant project's
>      routing, and about reaching non-`googleapis.com` targets.
>    - Does it warn anywhere that the default internet route is removed from the
>      tenant? Does it mention `run.app` or peered DNS domains?
>
> 6. **Apigee peered DNS domains**
>    - Find the page documenting
>      `gcloud services peered-dns-domains create` in the Apigee context (the
>      "configure DNS peering" / "northbound and southbound networking" docs).
>    - Quote what it says about when this is required.
>    - Does any page connect it to VPC Service Controls being enabled?
>
> 7. **Service Networking API reference for `dnsZones.list`**
>    <https://cloud.google.com/service-infrastructure/docs/service-networking/reference/rest/v1/services.projects.global.networks.dnsZones/list>
>    - Quote the IAM permission it requires.
>    - I need to confirm `servicenetworking.services.listDnsZones` is
>      producer-side only and cannot be held by a consumer. Check the IAM
>      permissions reference
>      (<https://cloud.google.com/iam/docs/permissions-reference>) for which
>      predefined roles, if any, contain it.
>
> 8. **VPC Service Controls supported products**
>    <https://cloud.google.com/vpc-service-controls/docs/supported-products>
>    - Is Cloud Run a VPC-SC supported service? Quote the entry.
>    - Note: this is a *different question* from whether `run.app` gets a DNS
>      zone, and I want to be able to state the distinction precisely, because
>      conflating the two is probably the origin of the support agent's claim.
>
> ### Output format
>
> A markdown document with one section per numbered item above. In each:
> the URL, the access date, the verbatim quote in a blockquote, and one line on
> what it establishes. Finish with a short table:
>
> | Claim | Supported / Refuted / Not addressed | Source |
> |---|---|---|
>
> Do not soften or editorialise the quotes. If Google's docs contradict our
> position anywhere, I need to know that clearly and early rather than have it
> surface in front of the support engineer.

---

## What to do with the output

Fold it into [`dns-peering.md`](dns-peering.md):

- §6.3 (the customer cannot enumerate the zone set) — item 7 backs the
  permission claim from Google's own IAM reference rather than only from a live
  `PERMISSION_DENIED`.
- §8 ask 1 (publish the list) — item 2 decides whether the fuller list is
  already published somewhere canonical, which changes the ask from "publish
  this" to "publish it *on the command's own reference page*, where the person
  configuring the peering will actually see it".
- A new documentary column alongside the live probe results: item 8 lets us say
  "Cloud Run is a VPC-SC supported product **and** `run.app` still has no
  producer-side DNS zone", which is the precise shape of the trap.
