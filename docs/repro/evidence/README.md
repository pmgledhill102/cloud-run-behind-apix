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

## Status

Empty pending a live run. The results quoted in `../dns-peering.md` are from the
2026-09-04 greenfield run, recorded in
[field notes §4.2](../../option-b-vpcsc-field-notes.md#42-vpc-sc-redirects-dns-to-restrictedgoogleapiscom-so-you-dont-need-the-peering)
and on [issue #81](https://github.com/pmgledhill102/cloud-run-behind-apix/issues/81);
that run predates this capture mechanism, so its transcripts were not retained.
