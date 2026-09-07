# ADR 0027: Civo as a second execution target under a separate project

## Status

Accepted

## Context

`architecture.md` §10a describes two Argo CD execution targets, `aws` and
`local`. Neither is a real second cloud provider — `local` is AWS-free by
design (minikube/kind, spec 022) and is not a candidate for hosting
anything durable.

`specs/027-alt-cloud-targets/spec.md` researched adding Civo or
DigitalOcean as a genuine second cloud target and proposed a `TARGET`
input to select between them. That spec is research-only, has four open
questions, and never reached an accepted design.

The Civo planning package (`specs/civo/`) settled the open questions:
Civo managed Kubernetes, region LON1, project `vk-civo-lab`, subdomain
`civo.<root-domain>`, selected by a `PROVIDER` operator input (spec
CIVO-010) rather than the `TARGET` name spec 027 proposed. This ADR
records that decision so later specs (025 onward) do not each re-derive
it, and so constitution §20 has something to cite.

## Decision

**`PROVIDER` selects the execution target; `aws` remains the default.**
`PROVIDER=civo` selects Civo managed Kubernetes as the second real
(non-`local`) target. `PROVIDER` is orthogonal to the existing `target`
value in `gitops/` (`aws`/`local`) — a Civo cluster still renders with
`target=aws` gitops values, since Civo hosts the same AWS-integrated
platform components (ESO reading SSM, ExternalDNS writing Route 53,
Roles Anywhere-backed backups to S3), just reached through a different
identity mechanism (ADR 0029) instead of EKS Pod Identity.

**The Civo project is `vk-civo-lab`, a separate AWS project from the
personal AWS/EKS lab.** State, DNS, and secrets are isolated: a separate
Terraform state bucket, a separate delegated subdomain
(`civo.<root-domain>`), and separate KMS-encrypted secret files under
`secrets/vk-civo-lab/`. The account layer (`terraform/live/account/`,
GitHub OIDC provider, `eks-access-identity`) is shared — it is
Bootstrap-lifecycle and scoped to the AWS account, not the project (ADR
0021).

**The stage model is identical to AWS's**, mapped onto new stack
directories: `terraform/live/persistent-civo/` (Civo network, reserved
IP — both free-tier, Persistent-lifecycle) and `terraform/live/cluster-civo/`
(cluster firewall, k3s cluster — Disposable-lifecycle). The existing
`terraform/live/persistent/` stack still runs for the Civo target, but
only its `secrets` unit applies — the `vpc` unit is AWS-only and is
excluded.

**Lifecycle classification (constitution §3) applies unchanged to the
Civo cluster: Disposable.** The Civo cluster, its k3s node pool, Argo
CD, and every Kubernetes workload on it follow the same create/destroy
discipline as the AWS Disposable class — `make up`/`make down`
semantics, not a separate lifecycle taxonomy.

**This supersedes the `TARGET` proposal of `specs/027-alt-cloud-targets/spec.md`.**
That spec is marked Superseded, with a pointer to `specs/civo/`.

## Consequences

- A `PROVIDER=civo` run never touches AWS/EKS resources, and a
  `PROVIDER=aws` run never touches Civo resources — the two targets share
  only the account layer and the `gitops/` tree's rendered manifests.
- Every later Civo spec (025 onward) can cite this ADR instead of
  re-justifying why a second project, rather than a second region or a
  second cluster in the same AWS account, was chosen.
- DigitalOcean, the other candidate spec 027 researched, is not pursued.
  Reviving it would need a new ADR, not a reopening of this one.
- Cost and blast-radius isolation between `vk-lab-platform` (AWS) and
  `vk-civo-lab` (Civo) is structural, not a convention to remember to
  follow — a leaked Civo credential cannot reach the AWS project's state
  or secrets, and vice versa, except through the shared account layer
  (GitHub OIDC provider, `eks-access-identity`), which has no AWS
  permission policy (ADR 0022).
