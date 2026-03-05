# Apigee Eval Org: Cost & Feasibility Notes

Investigation into whether to include a real Apigee X instance in the Option C PoC.

> **Update:** Pay-as-you-go pricing ($0.50/hr) makes testing feasible without a subscription. See [Provisioning Decision](apigee-provisioning-decision.md) for full cost analysis.

## Billing

- **Apigee eval org itself is free** — no license charges for 60 days
- **Underlying GCP resources do cost money**:
  - HTTPS load balancer (~$18/month)
  - Managed instance group (Apigee runtime)
  - PSC / VPC peering networking
  - Internet egress
- Community reports suggest **~$2–5/day** for a minimal eval setup
- Eval orgs **cannot be converted** to paid orgs

## Provisioning & Deletion

- Provisioning takes **30–60 minutes**
- Deletion is immediate for eval orgs:
  ```bash
  gcloud alpha apigee organizations delete ORG_NAME --retention=MINIMUM
  ```
- `--retention=MINIMUM` permanently deletes in 24 hours (billing stops at soft-delete)
- A 3–4 hour test window is feasible but you lose a chunk to provisioning/teardown

## What the Current PoC Already Proves

The VM-based test validates the same network path Apigee would use:
- DNS resolves `*.run.app` to the PSC endpoint IP (not public)
- HTTPS traffic flows through PSC over Google's backbone to Cloud Run
- Apigee in the same VPC (via peering or PSC endpoint attachment) would resolve DNS and route traffic identically

## What a Real Apigee Test Would Add

- End-to-end proof: API client → Apigee proxy → PSC → Cloud Run
- Validation that Apigee's DNS resolution respects the private zone
- Confidence that `--ingress=internal` on Cloud Run accepts Apigee-originated traffic

## Decision

Deferred for now. If needed later, add an optional `setup-apigee.sh` script with:
1. Apigee eval org provisioning
2. Simple pass-through proxy deployment targeting the Cloud Run service URL
3. End-to-end test
4. Cleanup with `--retention=MINIMUM`

## References

- [Compare eval and paid organizations](https://docs.google.com/apigee/docs/api-platform/get-started/compare-paid-eval)
- [Does Apigee X eval org charge anything?](https://discuss.google.dev/t/does-apigee-x-eval-org-charges-anything/160937)
- [organizations.delete API](https://docs.google.com/apigee/docs/reference/apis/apigee/rest/v1/organizations/delete)
- [gcloud alpha apigee organizations delete](https://cloud.google.com/sdk/gcloud/reference/alpha/apigee/organizations/delete)
