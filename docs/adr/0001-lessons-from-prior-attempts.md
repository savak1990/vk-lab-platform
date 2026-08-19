# ADR 0001: Design decisions carried over from prior attempts

## Status

Accepted

## Context

This platform is not the first attempt. Three earlier repositories covered
similar ground:

- [`bg-tf-app`](https://github.com/savak1990/bg-tf-app) — VPC, EKS, and an
  ArgoCD Helm release, all applied by raw Terraform.
- [`bg-tf-bootstrap`](https://github.com/savak1990/bg-tf-bootstrap) — S3 +
  DynamoDB remote state backend.
- [`bg-argocd-gitops`](https://github.com/savak1990/bg-argocd-gitops) — a
  separate GitOps repository with cluster add-ons and ArgoCD Applications.

Each repo worked on its own. Together they had gaps that this platform's
constitution and architecture now address on purpose. They also used EKS
IRSA for pod-level IAM rather than EKS Pod Identity — not a mistake, but a
mechanism this platform intentionally prefers going forward.

## What the prior attempts got wrong

1. **Terraform and Argo CD boundaries overlapped.** `bg-tf-app` applied the
   ArgoCD Helm release directly from Terraform (`live/dev/.../charts`),
   while `bg-argocd-gitops` also owned cluster add-ons through Argo. The
   split between the two owners was not consistent.
2. **No lifecycle separation.** Networking, compute, and state lived in one
   `live/dev/eu-west-1/` tree. Nothing marked which resources were safe to
   destroy and which held data. A routine teardown could destroy
   everything.
3. **No destroy/recreate test.** Nothing proved that a destroyed
   environment could come back with its data intact.
4. **Three repositories to keep in sync.** Bootstrap, infrastructure, and
   GitOps config lived in separate repos with no shared versioning, so a
   change that spanned all three had no atomic unit of review.

## Decision

Carry these lessons into this platform as binding rules, already reflected
in `docs/architecture.md` and `specs/000-constitution/spec.md`:

| Prior gap | Fix in this platform |
|---|---|
| Terraform/Argo boundary overlap | Terraform bootstraps Argo CD only; Argo CD owns every other Kubernetes resource ([constitution §2](../../specs/000-constitution/spec.md)) |
| No lifecycle separation | Explicit bootstrap / persistent / disposable classes ([architecture §6](../architecture.md)) |
| No destroy/recreate test | Full lifecycle CI test is mandatory for infrastructure-critical changes ([constitution §11](../../specs/000-constitution/spec.md)) |
| Three repos, no atomic review | One platform-only repository; application code stays external |
| IRSA used, Pod Identity not evaluated | Prefer EKS Pod Identity going forward; IRSA remains a permitted mechanism per [constitution §5](../../specs/000-constitution/spec.md) |

Kafka, PostgreSQL, CDC, Envoy Gateway, and the wider observability stack are
new scope, not a fix — they extend what the platform teaches beyond the
prior attempts.

## Consequences

- Specs under `specs/001-...` onward should treat the table above as
  settled; reopening one of these decisions needs a new ADR, not a
  one-off exception.
- The S3+DynamoDB state backend from `bg-tf-bootstrap` is not carried over
  as-is — the bootstrap spec should evaluate current Terraform state
  locking guidance before copying that pattern.
