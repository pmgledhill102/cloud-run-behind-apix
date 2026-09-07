# Evidence pack

Raw transcripts and manifests from the runs cited in
[`../dns-peering.md`](../dns-peering.md). These exist so a reader who will not
re-run the experiment can still check the claim against the run that produced
it, rather than against a summary of it.

## What lands here

| File | Contents |
|---|---|
| `<stamp>-phase-<phase>.log` | Full stdout/stderr of one phase: state dump, both probes, timings, and the debug-session trace when `TRACE=1` |
| `<stamp>-phase-<phase>.manifest.txt` | Provenance — project, Apigee org/instance/runtime IP, Cloud Run URL and ingress, gcloud version, capture time |

The manifest is what lets a reader tell whether two phases came from the same
stack. A transcript without it is an anecdote.

## Producing them

```bash
PROJECT_ID=<your-project> \
EVIDENCE_DIR=docs/repro/evidence \
EVIDENCE_REDACT=1 \
TRACE=1 \
  ./scripts/option2b/experiment-tenant-dns.sh omit
```

Run `omit` → `dns` → `full` in order; each phase writes its own pair.

## Redaction

This repository is public and the sandbox projects it runs in are ephemeral,
but project ids and numbers are still identifiers. `EVIDENCE_REDACT=1`
substitutes both on the way out, in the transcript and the manifest.

Redact before committing unless there is a reason not to. Transcripts also carry
the Apigee runtime IP and the Cloud Run service URL, which are not secrets but
are not interesting to a reader either — if a future run needs them masked too,
extend the substitution list in the capture block at the top of
`experiment-tenant-dns.sh` rather than editing files by hand after the fact.

## What's here now

### The 2026-09-07 scope map (`dns-peering.md` §6.4)

Four transcripts from one greenfield stack, in order. All four carry
`phase: after` in the filename except the first, because the *phase argument* to
the script is `after` for every state that measures — what distinguishes them is
the network state at capture time, which the filename cannot express. Read them
in this order:

| File | State captured | The row that matters |
|---|---|---|
| `20260907T112556Z-scope-before.log` | 1 — VPC-SC **off** | all five probes connect; establishes the fixtures work |
| `20260907T113942Z-scope-after.log` | 2 — VPC-SC **on** | `run.app` and `www.google.com` both `NO SOCKET`; the three DOC-NAMED domains still `200`/`401` |
| `20260907T114316Z-scope-after.log` | 2, with `TRACE=1` | `resolvedAddress` = `199.36.153.x` for googleapis/pkg.dev/gcr.io, **ABSENT** for `run.app` |
| `20260907T115930Z-scope-after.log` | 3 — **+ peered DNS domain**, `TRACE=1` | `run.app` restored at `resolvedAddress = 199.36.153.4`, **while `www.google.com` stays `NO SOCKET`** |

The last file is the one to read if you only read one. It is what shows the
peered DNS domain to be a name-scoped DNS fix rather than a restoration of
internet egress — the tenant still has no default route after it is applied.

Redacted with `EVIDENCE_REDACT=1` (the `before` transcript was captured without
`EVIDENCE_DIR` and redacted with the same substitutions afterwards).

### Other

| File | From |
|---|---|
| `20260905T115110Z-perimeter-propagation.log` | Enforcement-arrival measurement for a freshly created perimeter, 2026-09-05. Independently reproduces the flap documented in [field notes §5](../../option-b-vpcsc-field-notes.md#5-waiting-observed-propagation-and-provisioning-times): first `403` at ~24 min after create, back to `200`, stable from ~28 min, confirmed at ~30 min. A probe loop that stopped at the first denial would have declared victory ~6 minutes early, while the perimeter was still intermittently open — which is why `CONFIRM=3` exists |

## Status

The 2026-09-07 scope-map transcripts above are from a live greenfield run and
are complete.

The `experiment-tenant-dns.sh` phase transcripts are still pending a live run. The results quoted in `../dns-peering.md` are from the
2026-09-04 greenfield run, recorded in
[field notes §4.2](../../option-b-vpcsc-field-notes.md#42-vpc-sc-redirects-dns-to-restrictedgoogleapiscom-so-you-dont-need-the-peering)
and on [issue #81](https://github.com/pmgledhill102/cloud-run-behind-apix/issues/81);
that run predates this capture mechanism, so its transcripts were not retained.
