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
