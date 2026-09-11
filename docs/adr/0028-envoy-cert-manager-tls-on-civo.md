# ADR 0028: Envoy-terminated TLS with cert-manager on Civo

## Status

Accepted

## Context

ADR 0011 decided AWS terminates TLS at the NLB using an ACM certificate,
explicitly rejecting cert-manager and Let's Encrypt for three reasons:
the Let's Encrypt duplicate-certificate rate limit colliding with this
platform's own `make up`/`make down` CI cycles; the fact that reusing one
certificate across a full EKS recreate needs unproven Secret-persistence
plumbing this repository had no precedent for; and ACM certificates being
structurally non-exportable, so they can only ever be attached to an
AWS-managed load balancer, never loaded into a pod.

Civo has none of the AWS-managed edge this decision relies on: no ACM, no
NLB with a TLS listener. A Civo load balancer is a plain TCP forwarder —
it cannot terminate TLS at all. Some component inside the cluster has to
own it, and Envoy Gateway is the only candidate (constitution §8: Envoy
already owns Gateway API routing, rate limiting, retries, timeouts).

## Decision

**TLS terminates at Envoy Gateway, using cert-manager and Let's Encrypt
HTTP-01 through the Gateway API.** The Civo load balancer forwards
plaintext to Envoy Gateway's Service, exactly as the NLB forwards
plaintext to Envoy on AWS (constitution §8) — only the TLS-termination
point moves, not the routing model.

This answers ADR 0011's three objections directly, for the Civo case
only:

- **ACM non-exportability** does not apply — Civo has no ACM. There is no
  AWS-managed certificate to fail to export; cert-manager issues and
  holds the certificate itself.
- **Unproven Secret-persistence plumbing** is now proven, deliberately,
  as part of this decision: the TLS Secret is written to AWS Secrets
  Manager as an SSM `SecureString` (following the pattern ADR 0023
  already established for other Terraform-derived config) before
  `make down`, and restored before cert-manager reconciles on the next
  `make up`. A Secret already present when cert-manager reconciles is
  adopted, not reissued — this is the round-trip ADR 0011 said this
  repository had no precedent for; this ADR is that precedent, scoped to
  Civo.
- **The duplicate-certificate rate limit** is mitigated two ways: the
  Secret-persistence above means a normal down/up cycle does not request
  a new certificate at all, and CI uses the Let's Encrypt **staging**
  environment, which has its own, much looser, rate limits, so repeated
  CI lifecycle runs never touch the production issuance limit.

*Amended 2026-09-11 (CIVO-070 verification).* **The stored certificate
deliberately outlives `full-down`.** The SSM parameter
`/<project>/persistent/civo/tls/platform-public` is written by `argo-down`
and read by `argo-up`, not created by Terraform, so `persistent-down` and
`bootstrap-down` do not delete it. This is the one per-project persistent
resource outside Terraform state, and it is an exception on purpose:

- Let's Encrypt allows **5 duplicate certificates per rolling week** for
  one name set. Tying the parameter's life to the persistent stack would
  make every `full-down`/`full-up` cycle a production order and cap full
  cycles at five a week — too small for how this lab is actually used.
  Kept outside Terraform, a `full-up` of the same project name and
  subdomain restores the certificate and orders nothing; only the first
  bootstrap of a new project or subdomain, and the 60-day renewal, order.
- The certificate is keyed by the wildcard pair (`<subdomain>.<root-domain>`
  and `*.<subdomain>.<root-domain>`), so any hostname under the subdomain
  matches. If the subdomain changes under the same project name,
  cert-manager sees a Secret that no longer matches the `Certificate` and
  reissues on its own; nothing needs manual repair.
- The cost of the exception is one Advanced-tier parameter per project
  (~0.05 USD/month) that survives a project's full teardown. Delete it by
  hand when a project is retired:
  `aws ssm delete-parameter --region eu-west-1 --name /<project>/persistent/civo/tls/platform-public`.
  CI projects on the staging issuer hold a worthless certificate; the civo
  CI workflow (CIVO-140) deletes theirs in its cleanup step.
- The parameter depends on the account-global `alias/lab-secrets` key; an
  `account-down` makes any surviving parameter undecryptable, which
  `argo-up` treats as "nothing stored".

*Amended 2026-09-11 (DNS-01 verification).* **The solver switched from
HTTP-01 to DNS-01, and the certificate switched from per-hostname to a
wildcard pair.** The CIVO-075 spec covers the full rationale; this amends
the Decision line above, which named HTTP-01 specifically. One
consequence worth recording here: DNS-01 answers Let's Encrypt's challenge
by creating a TXT record in the Civo subdomain's zone, which means Civo's TLS issuance
now depends on an AWS IAM identity (a Roles Anywhere Route53 role) to
write that record — a coupling this original decision did not need, since
HTTP-01 required nothing more than Envoy serving the challenge path over
the existing plaintext listener. This is a deliberate accepted tradeoff,
not a regression: DNS-01 is what makes wildcard issuance possible at all,
and it removes the reverse dependency HTTP-01 had on the HTTPRoutes whose
DNS the challenge needed to already resolve.

**ADR 0011 is unchanged for AWS.** This is a Civo-only variant, not a
replacement — the AWS target keeps NLB + ACM termination exactly as ADR
0011 specifies. Constitution §20 states this variant explicitly under its
§8 clause; invariant "no AWS-side host/path routing duplicated with
Envoy" (constitution §8) still holds on Civo — the Civo LB, like the NLB,
performs no host/path routing.

## Consequences

- Civo needs cert-manager installed (spec CIVO-065) as a platform
  component; AWS does not and must not gain it as a side effect of this
  ADR — cert-manager stays behind the same `target=aws`/Civo gating
  `architecture.md` §10a already uses for target-specific components.
- A cert-manager `Issuer`/`ClusterIssuer` pointed at Let's Encrypt
  staging is required in CI; production issuance is reserved for the
  operator's own long-running Civo cluster, not CI's disposable ones.
- If SSM `SecureString` persistence of the TLS Secret ever fails
  silently, the platform falls back to cert-manager re-issuing against
  the production Let's Encrypt endpoint — spec CIVO-070 must make this
  failure loud (a failed restore should not quietly re-trigger issuance
  and erode the rate-limit budget).
- This ADR does not give Civo an ACM equivalent or a managed edge
  certificate store — the certificate material lives only in the
  cluster's Secret and its SSM backup, which is a smaller trust boundary
  than AWS's ACM-managed one and should be treated accordingly (least
  privilege on who can read that SSM parameter).
