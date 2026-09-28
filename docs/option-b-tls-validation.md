# Option B/2b: TLS from Apigee to Cloud Run over PGA — is the certificate actually validated?

**Verified live 2026-09-28** on a fresh option 2b stack (see
[§6 Test environment](#6-test-environment) for what "2b" meant on this run).
Reproduce with
[`scripts/option2b/experiment-tls-validation.sh`](../scripts/option2b/experiment-tls-validation.sh).
Tracking issue: #100.

## 1. The question

Apigee reaches Cloud Run on option 2/2b by resolving the service's
`*.run.app` name to the **restricted VIP** (`199.36.153.4/30`) and making an
HTTPS call to it. Two things need to be true for that to be real TLS:

1. The handshake has to complete — TLS works at all on this path.
2. Apigee has to **validate** what it is shown — a trusted chain, and a
   certificate that actually names the host it dialled — without
   `<IgnoreValidationErrors>true</IgnoreValidationErrors>` (the "SSL disabled"
   setting).

The second point matters because the option 2 proxy
([`shared/lib/apigee-proxy.sh`](../scripts/shared/lib/apigee-proxy.sh)) has
**no `<SSLInfo>` block at all**. It never sets `IgnoreValidationErrors`, but
Apigee's documentation only *promises* to fail a bad certificate when
`<Enforce>true</Enforce>` is set:

> **Enforce** — Enforces strict SSL between Apigee and the target backend. If
> set to true, connections will fail for targets with invalid certs, expired
> certs, self-signed certs, certs with a hostname mismatch, and certs with an
> untrusted root. [...] If unset, or set to false, the result of connections to
> target backends with problematic certs depends upon the setting of
> `<IgnoreValidationErrors>`.
>
> — [API proxy configuration reference, `<SSLInfo>`](https://docs.cloud.google.com/apigee/docs/api-platform/reference/api-proxy-configuration-reference), accessed 2026-09-28

The docs say nothing about which trust anchors apply when no `<TrustStore>` is
given. So "TLS works today" did not yet establish "the certificate is being
checked". This experiment establishes it, with negative controls.

## 2. Answer

**TLS works on this path with full validation and no `IgnoreValidationErrors`
— but only once `<Enforce>true</Enforce>` (or a `<TrustStore>`) is set.
Today's option 2 config validates the hostname and not the chain.**

- Apigee → restricted VIP → Cloud Run negotiates **TLS 1.3**
  (`TLS_AES_256_GCM_SHA384`) against Google's `*.a.run.app` certificate, and
  the handshake completes under strict validation: `<Enforce>true</Enforce>`
  (p2), and a truststore holding **only** the Google Trust Services roots
  (p3).
- With `Enforce`, every bad certificate is refused at the handshake — wrong
  hostname (n2), untrusted chain (n1, n6), and a **self-signed certificate
  whose name matches** (n8).
- **Without any `<SSLInfo>` — the option 2 proxy as shipped — Apigee checks
  the hostname but not the chain.** It rejects a certificate for the wrong name
  (n3, n5), but it **accepted a self-signed certificate for a matching name and
  returned `200`** (n7) — exactly what the `IgnoreValidationErrors=true`
  control did (c1). It does not use the "SSL disabled" setting, and it still
  behaves like it for anyone who can present a certificate with the right
  name.
- That is not hypothetical on this pattern. The fixture for n7 was built with
  nothing more than **one A record in the private `run.app` zone** in the
  customer VPC, which the Apigee tenant resolves through (peered DNS domain).
  Whoever can write to that zone can redirect Apigee to their own endpoint; with
  the default config the TLS layer will not object. With `Enforce` it does (n8).
- One thing this run could not show is an end-to-end `200` from Cloud Run
  itself: without a VPC-SC
  perimeter (which the sandbox identity could not create) the front end
  answers the Apigee tenant with a `404` for the `--ingress=internal` service —
  **after** the TLS handshake. That is the admission behaviour already
  documented in [field notes §4.2](option-b-vpcsc-field-notes.md#42-vpc-sc-redirects-dns-to-restrictedgoogleapiscom-so-you-dont-need-the-peering),
  and it is independent of TLS: see [§5](#5-why-the-positives-are-404-not-200).

## 3. Results

Each probe is its own proxy, all on the same path (Apigee tenant → peered DNS
→ restricted VIP → Google Front End), differing only in the `<SSLInfo>` block
or in the name dialled. Every probe carries a Google ID token for `cr-hello`
and rewrites `Host` to the service's host, exactly as the option 2 proxy does.

| Probe | Target | `<SSLInfo>` | HTTP | Outcome | Apigee's reason |
|---|---|---|---|---|---|
| **p1** | `cr-hello-…a.run.app` | *none* (today's option 2 config) | 404 from GFE | **Handshake OK** | — |
| **p2** | `cr-hello-…a.run.app` | `Enforce=true` | 404 from GFE | **Handshake OK** | — |
| **p3** | `cr-hello-…a.run.app` | `Enforce=true` + `TrustStore` = GTS Root R1–R4 only | 404 from GFE | **Handshake OK** | — |
| **n1** | `cr-hello-…a.run.app` | `Enforce=true` + `TrustStore` = unrelated self-signed CA | 503 | **Rejected** | `SunCertPathBuilderException: unable to find valid certification path to requested target` |
| **n2** | `nomatch.cr-hello-…a.run.app` | `Enforce=true` | 503 | **Rejected** | `CertificateException: No subject alternative DNS name matching nomatch.cr-hello-…a.run.app found.` |
| **n3** | `nomatch.cr-hello-…a.run.app` | *none* | 503 | **Rejected** | `CertificateException: No subject alternative DNS name matching nomatch.cr-hello-…a.run.app found.` |
| **n4** | `cr-hello-…a.run.app` | `TrustStore` = unrelated CA, **no** `Enforce` | 503 | **Rejected** | `SunCertPathBuilderException: unable to find valid certification path to requested target` |
| **n5** | `199.36.153.5` (raw VIP) | *none* | 503 | **Rejected** | `CertificateException: No subject alternative names matching IP address 199.36.153.5 found` |
| **n6** | `199.36.153.5` (raw VIP) | `Enforce=true` | 503 | **Rejected** | `SunCertPathBuilderException: unable to find valid certification path to requested target` |
| **n7** | `tls-selfsigned-probe.run.app` → `vm-test` | *none* | **200** | **ACCEPTED** | — (self-signed chain, matching name: not checked) |
| **n8** | `tls-selfsigned-probe.run.app` → `vm-test` | `Enforce=true` | 503 | **Rejected** | `SunCertPathBuilderException: unable to find valid certification path to requested target` |
| **n9** | `tls-selfsigned-probe.run.app` → `vm-test` | `TrustStore` = GTS roots, **no** `Enforce` | 503 | **Rejected** | `SunCertPathBuilderException: unable to find valid certification path to requested target` |
| *c1* | `tls-selfsigned-probe.run.app` → `vm-test` | `IgnoreValidationErrors=true` (**control only**) | 200 | Accepted | — |

Every rejection carries `errorcode: messaging.adaptors.http.flow.SslHandshakeFailed`
and returns in ~150–250 ms — the handshake is refused, no request is sent.

What each `<SSLInfo>` configuration actually checks, read off the table:

| Configuration | Hostname | Chain | Deciding probes |
|---|---|---|---|
| *none* (option 2 as shipped) | **checked** | **not checked** | n3, n5 rejected; **n7 accepted** |
| `<TrustStore>`, no `Enforce` | checked | checked against the truststore | n4, n9 rejected |
| `<Enforce>true</Enforce>` | checked | checked against platform trust | n2, n6, n8 rejected; p2 accepted |
| `<Enforce>` + `<TrustStore>` (GTS R1–R4) | checked | checked against the truststore | n1 rejected; p3 accepted |

How to read the controls:

- **n7 / n8 / c1** are the decisive trio: the **same** self-signed target, whose
  CN and SAN both match the name dialled, so only chain validation can reject
  it. The default accepts it; `Enforce` refuses it; `IgnoreValidationErrors`
  (c1) proves the fixture is reachable — so n8's refusal is validation, not
  connectivity. The fixture is `vm-test` serving a certificate from
  `openssl req -x509`, published as an A record in the `run-app-pga` zone —
  the zone the Apigee tenant resolves `run.app` through.
- **n1 vs p3** differ only in the truststore's contents, so n1 proves chain
  validation is live under `Enforce` and p3 proves the GTS roots suffice.
- **n2 / n3** dial a name that resolves through the same `*.run.app` wildcard
  to the same VIP, but is one label deeper than any wildcard SAN on the
  certificate; Google's front end falls back to its `*.googleapis.com`
  certificate for the unknown SNI (observed with `openssl`, §4). Only hostname
  validation can fail it — and it does, with *and* without `Enforce`.
- **n4 / n9** show a `<TrustStore>` switches chain validation on even without
  `Enforce`. The documentation's "depends upon `IgnoreValidationErrors`" is
  therefore only half the story: with no truststore and no `Enforce`, the chain
  is not checked even though `IgnoreValidationErrors` defaults to `false`.

### Debug-session trace of the positive path (p1)

`POST .../debugsessions`, one request, then the trace. The relevant fields:

```text
target.url                                 = https://cr-hello-vuoyppegva-ma.a.run.app/
target_info.header.host                    = cr-hello-vuoyppegva-ma.a.run.app
targetendpoint_default.resolvedAddress     = 199.36.153.5          # restricted VIP
targetendpoint_default.connectionStatus    = CONNECTED
targetendpoint_default.isTlsEnabled        = true
targetendpoint_default.tlsHandshakeStatus  = COMPLETED
targetendpoint_default.actualTargetTlsProtocol   = TLSv1.3
targetendpoint_default.actualTargetCipherSuite   = TLS_AES_256_GCM_SHA384
response                                   = 404 Not Found, server: Google Frontend
error.class                                = com.apigee.errors.http.server.BadGateway   # "a response came back"
```

The same trace for the two validating variants — the handshake completes
under `Enforce=true`, and under a truststore holding **only** the GTS roots:

| Field | p2 (`Enforce=true`) | p3 (`Enforce` + GTS-only truststore) |
|---|---|---|
| `resolvedAddress` | `199.36.153.5` | `199.36.153.6` |
| `connectionStatus` | `CONNECTED` | `CONNECTED` |
| `tlsHandshakeStatus` | **`COMPLETED`** | **`COMPLETED`** |
| `actualTargetTlsProtocol` | `TLSv1.3` | `TLSv1.3` |
| `actualTargetCipherSuite` | `TLS_AES_256_GCM_SHA384` | `TLS_AES_256_GCM_SHA384` |
| response | `404`, `Google Frontend` | `404`, `Google Frontend` |

## 4. What the restricted VIP presents

From `vm-test` in `apigee-vpc` (same VIP, same DNS), via
`experiment-tls-validation.sh observe`:

| SNI | Certificate served | Chain | `openssl` verdict |
|---|---|---|---|
| `cr-hello-vuoyppegva-ma.a.run.app` | `CN=*.a.run.app`, SANs `*.a.run.app`, `run.app`, `*.<region>.run.app`… | `WE2` → `GTS Root R4` → (cross-signed by `GlobalSign Root CA`) | TLS 1.3, `Verify return code: 0 (ok)` |
| `nomatch.cr-hello-vuoyppegva-ma.a.run.app` | `CN=*.googleapis.com` | `WR2` → `GTS Root R1` → (`GlobalSign Root CA`) | `Verify return code: 62 (hostname mismatch)` |

And by address, which is what n5/n6 dial. Apigee's Java client sends **no
SNI** for an IP-literal URL, so the relevant row is the first:

| SNI | Certificate served | `openssl` verdict |
|---|---|---|
| *(none)* | self-signed `CN=invalid2.invalid`, `OU=No SNI provided - please fix your client.` | `Verify return code: 18 (self-signed certificate)` |
| `199.36.153.5` (IP literal) | `CN=*.googleapis.com` (`WR2` → `GTS Root R1`) | chain OK; no IP SAN |

That explains the two different n5/n6 messages: both reject the same
self-signed placeholder — the default path reports the hostname check first
(the placeholder has no SANs at all), `Enforce` reports the chain check first.

Two practical consequences:

- **Google serves both RSA and ECDSA chains**, anchored in different roots
  (`WR2 → GTS Root R1`, `WE2 → GTS Root R4`), chosen per handshake. A
  `<TrustStore>` pinned to a single root would work on some handshakes and
  fail on others. If you pin, pin **all four** GTS roots (R1–R4), as p3 does —
  or rely on `Enforce`'s platform trust, which p2 shows already trusts them.
- The certificate names the **service**, not the VIP. Everything that makes
  this path validate depends on DNS putting the `run.app` name into SNI while
  the packets go to `199.36.153.x` — which is the peered DNS domain's job.

## 5. Why the positives are `404`, not `200`

The positives reach Google's front end, complete the handshake, send the
request, and get `404 Not Found` with `server: Google Frontend`. That is not a
TLS or routing failure:

- The stock option 2 proxy (`/hello`) returns the same `404` on this stack;
  `vm-test` calling the same URL through the same VIP gets `200 OK` from
  `cr-hello`.
- `cr-hello` is deployed `--ingress=internal`. Field notes §4.2 proved by A/B/A
  on the same path that the Apigee tenant gets exactly this `404` against an
  internal-ingress service, and `200` with ingress `all`, with DNS, routes and
  TLS unchanged — and that earlier runs *with* a VPC-SC perimeter reached `200`
  against the internal-ingress service.
- This run had **no perimeter** (below), so it lands on the `404` side of that
  finding.

The A/B flip to `--ingress=all` was not repeated here: the change was held for
explicit approval, since it widens the service's network exposure (IAM still
requires an ID token). Nothing in the TLS result depends on it — a response
from the front end is only possible *after* the handshake has completed and
passed that probe's validation, and the negative probes show exactly where
validation stops a bad certificate.

## 6. Test environment

| Item | Value |
|---|---|
| Stack | `shared/setup-iam` + `setup-base` + `setup-slow` + `option2/setup.sh` + option 2b tenant plumbing |
| Apigee | PAYG org, VPC-peering provisioning, runtime `1-18-0-apigee-5`, instance in **europe-west1** (`APIGEE_INSTANCE_REGION`; europe-north2 was out of capacity) |
| Cloud Run | `cr-hello`, europe-north2, `--ingress=internal`, IAM-closed (ID token required) |
| Tenant path | `enable-vpc-service-controls` on the servicenetworking peering (verified `enabled: true`), `dns.peer` grant, custom route export, peered DNS domain `run.app.`, `run-app-pga` zone → `199.36.153.4/30`, restricted-VIP route |
| Self-signed fixture (n7–n9, c1) | `vm-test` (`10.0.0.2`) serving HTTPS with an `openssl req -x509` certificate for `tls-selfsigned-probe.run.app`; A record in `run-app-pga`; reachable from the tenant over the peering (`allow-internal-apigee` admits `10.0.0.0/8`). Removed by `teardown` |
| **Not present** | The VPC-SC **perimeter**: creating it needs org-level `roles/accesscontextmanager.policyAdmin`, which the sandbox identity did not have |

Why the missing perimeter does not weaken the TLS result: the perimeter is an
*authorization* decision taken by Google's front end on a request it has
already received over TLS. It does not change which certificate is served, the
tenant's DNS, or how Apigee validates the chain — the tenant-side restricted-VIP
path is created by `enable-vpc-service-controls` on the peering, which *was*
in place.

## 7. Recommendations

1. **Set `<Enforce>true</Enforce>` on every Cloud Run target.** It is the
   single change that turns "hostname checked" into "hostname and chain
   checked" (n7 → n8), and Google's certificate passes it cleanly (p2). The
   minimal block:

   ```xml
   <HTTPTargetConnection>
     <URL>https://my-service-xyz-ew.a.run.app/</URL>
     <SSLInfo>
       <Enabled>true</Enabled>
       <Enforce>true</Enforce>
     </SSLInfo>
     ...
   </HTTPTargetConnection>
   ```

   `Enforce` also overrides any `IgnoreValidationErrors` someone adds later.
   To apply it to every proxy in an environment at once, set the
   environment property `features.SSLInfo.Enforce=true` — note that the
   documented API call replaces the whole `properties` list, so re-specify
   existing properties when setting it. (The environment flag was not
   exercised in this run; the per-target element was.)
2. **Never use `IgnoreValidationErrors` for Cloud Run targets.** It is not
   needed on this path — the certificate validates under the strictest
   setting tested.
3. **Optionally pin the Google Trust Services roots** with a `<TrustStore>`
   (p3). If you do, include **GTS Root R1–R4**, not one root (§4).
4. **Treat the private `run.app` zone as security-relevant.** It decides where
   Apigee's southbound traffic goes; `Enforce` is what stops a bad record from
   also being a successful impersonation.
5. **Never target the VIP by IP.** It fails validation (n5/n6) — and even
   with validation disabled it would put the IP into SNI, which the front end
   cannot route (field notes §4.1).
6. **Treat a `404` from `Google Frontend` as "TLS fine, admission refused"**,
   not a connectivity or certificate problem; a certificate problem is a
   `503` with `SslHandshakeFailed` and a precise reason string.

## 8. Correction to field notes §4.1

Field notes §4.1 records a no-`<SSLInfo>` target of
`https://199.36.153.5/` returning `403 "The service you are trying to access is
not available on Google's Restricted VIPs"` — i.e. a completed handshake
against a certificate that cannot name an IP. **That did not reproduce on
2026-09-28** (runtime `1-18-0-apigee-5`): the same target fails the handshake
with `No subject alternative names matching IP address 199.36.153.5 found`
(n5): the default config checks hostnames, and with no SNI the front end
serves a self-signed placeholder with no SANs at all (§4). The §4.1 conclusion — targeting the VIP by IP is not a workaround —
stands, for a stronger reason. Whether the earlier observation reflected an
older runtime default or a different target configuration cannot be
determined from the notes.

## 9. Reproduce

```bash
export PROJECT_ID=<your-project>
# stack: setup-iam, setup-base, setup-slow, option2/setup.sh, option2b (early+finish)

./scripts/option2b/experiment-tls-validation.sh all        # setup + observe + test
./scripts/option2b/experiment-tls-validation.sh teardown   # probes + truststores only
```

Where IAP SSH is unavailable, prefix with `VM_CHANNEL=metadata` (see
`shared/lib/vm-exec.sh`). Raw transcripts from this run:
[`repro/evidence/20260928T1250Z-tls-*`](repro/evidence/README.md#tls-validation-run-2026-09-28).
