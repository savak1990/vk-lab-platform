# ADR 0029: IAM Roles Anywhere with an offline CA

## Status

Accepted

## Context

Constitution §5 says Kubernetes workloads should use EKS Pod Identity or
an equivalent workload identity mechanism, so that no AWS credential is
ever stored at rest in the cluster. EKS Pod Identity itself is not
available on Civo — Civo's k3s cluster is not EKS, and has no AWS-managed
identity binding.

AWS IAM Roles Anywhere lets non-AWS compute authenticate to AWS by
presenting an X.509 client certificate that chains to a trust anchor IAM
trusts, and exchanging it for temporary credentials — the same shape of
guarantee Pod Identity gives (short-lived, no static key at rest), reached
by a different mechanism. Civo workloads that need AWS access (External
Secrets reading SSM, ExternalDNS writing Route 53, the S3 backup job) use
this instead.

ADR 0022 already established the pattern this platform uses for
identity design: split roles by what they actually authorize, and state
the blast radius of a compromise explicitly rather than assuming it away.
This ADR applies that same discipline to Roles Anywhere.

## Decision

**M1 uses a single offline CA as the Roles Anywhere trust anchor.** The
CA is generated and held outside AWS (an offline ceremony, spec
CIVO-080), not an AWS Private CA — avoiding a recurring AWS cost for a
capability a single self-signed root serves adequately at this scale.

**Trust policies are CN-conditioned, not blanket.** Each IAM role's trust
policy restricts which certificate Common Name may assume it, so a
certificate minted for one workload's CN cannot be used to assume a
different workload's role.

**A helper sidecar provides credentials to each pod** — it holds the
workload's client certificate, performs the Roles Anywhere
`CreateSession` exchange, and exposes the resulting temporary credentials
to the workload's main container via `credential_process` (spec
CIVO-090). No AWS static key is ever written to a Secret or a pod's
filesystem.

**The blast radius is stated explicitly, not assumed away:**
`lab-role` holds `kms:*` on `alias/lab-secrets`. `CIVO_TOKEN`
(ADR 0030) grants cluster-admin on the Civo k3s cluster. Cluster-admin
can read the Kubernetes Secret holding the CA's private key. Holding the
CA private key means minting a certificate for *any* CN, which — because
trust policies are CN-conditioned but not CN-*restricted-in-issuance* —
means a `CIVO_TOKEN` compromise can, transitively, mint a certificate for
every role's CN and reach every role's AWS permissions, including
`lab-role`'s `kms:*`. **A `CIVO_TOKEN` compromise is therefore
equivalent, in the worst case, to a `lab-role` compromise.**

**This blast radius is reachable one hop earlier than `CIVO_TOKEN`
compromise, too:** cluster-admin is not required to read the CA Secret —
any controller whose ClusterRole already grants cluster-wide Secret read
reaches it directly. `external-secrets-controller` (unrelated to this ADR,
already present in this repo) is a concrete example: its ClusterRole
grants cluster-wide `get`/`list`/`watch` on Secrets, so it can read the CA
private key and mint a certificate for any CN without `CIVO_TOKEN` ever
being compromised. CIVO-200's Certificate-approval policy does not close
this path — it gates approval, not Secret reads. Scoping that
controller's RBAC (ESO's chart-supported `scopedNamespace`/`scopedRBAC`
config) is a tracked, deferred follow-up, not implemented here.

**Mitigations**, none of which eliminate the above, all of which bound
it:

- Certificates are short-lived (24h), so a leaked certificate — as
  opposed to a leaked CA key — has a small, non-renewable window.
- Trust policies are CN-conditioned, so the *normal*-path blast radius of
  one workload's leaked certificate is that one role, not every role.
- A documented runbook exists to disable the trust anchor immediately
  (revokes every certificate's ability to authenticate, platform-wide,
  in one action) if CA-key compromise is suspected.
- An intermediate CA — so the offline root never has to be online or
  reachable from the cluster at all — is deferred to spec CIVO-200, not
  M1. M1 accepts the single-CA blast radius above as a stated, reviewed
  trade-off for a disposable educational lab, not a production system.

**Alternatives considered:**

a. **AWS Private CA as the trust anchor.** Rejected — recurring per-month
   cost for a capability an offline self-signed root serves adequately
   at this scale; revisit only if the platform's trust model outgrows a
   single lab.
b. **A short-lived-token exchange instead of certificates** (e.g. an
   OIDC-style federated identity from Civo). Rejected — Civo has no
   OIDC-issuer capability to federate from; Roles Anywhere's certificate
   model is the only AWS-native mechanism available to non-EKS compute.
c. **Per-workload CAs instead of one shared CA.** Rejected for M1 as
   unnecessary complexity given the CN-conditioned trust policies already
   bound blast radius per workload on the normal path; revisit alongside
   the intermediate-CA work in CIVO-200 if the single-CA risk proves too
   broad in practice.

## Consequences

- Compromise of `CIVO_TOKEN` must be treated with the same severity as
  compromise of `lab-role` itself, operationally — this is a stated risk
  acceptance for M1, not a residual unknown.
- The disable-trust-anchor runbook (spec CIVO-080/CIVO-082) is not
  optional documentation — it is the platform's actual incident response
  for this blast radius and must be kept current as roles are added.
- CIVO-200's intermediate-CA work is the agreed path to shrink this blast
  radius; it is deferred, not rejected, and should be prioritized ahead
  of onboarding this pattern to any less disposable environment.
- No AWS static credential is ever required by a Civo-hosted workload —
  constitution §5's workload-identity intent is met, by a different
  mechanism than Pod Identity, with its trade-offs stated rather than
  hidden.
