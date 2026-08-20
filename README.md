# vk-lab-platform

A disposable AWS/EKS learning platform. This repository holds platform
infrastructure only. It does not hold business application code.

See [`docs/architecture.md`](docs/architecture.md) for the target
architecture and [`specs/`](specs/) for implementation specifications.

This is a second iteration. Three earlier repositories
([bg-tf-bootstrap](https://github.com/savak1990/bg-tf-bootstrap),
[bg-tf-app](https://github.com/savak1990/bg-tf-app),
[bg-argocd-gitops](https://github.com/savak1990/bg-argocd-gitops)) covered
similar ground and left gaps. See
[`docs/adr/0001-lessons-from-prior-attempts.md`](docs/adr/0001-lessons-from-prior-attempts.md)
for what went wrong and how this platform fixes it.

## Status

State (spec 001), Bootstrap (spec 001), and Persistent (spec 002) are
implemented. Disposable (EKS, Argo CD, workloads — spec 003 onward, wired
up behind `make up`/`make down` in spec 014) is not yet built.

## Usage

The platform is built as four independent lifecycle layers, each with its
own Terraform/Terragrunt state, created in order and destroyed in reverse.
Later layers depend on earlier ones already existing; `make <layer>-up`
does not create the layers below it for you.

```bash
make state-up          # once, ever: remote state bucket + locking
make bootstrap-up      # rare: KMS key, GitHub OIDC, foundational IAM
make persistent-up     # occasional: lab.<root-domain> zone + cert, secrets
make up                # frequent: EKS, Argo CD, workloads (not yet implemented)

make down               # frequent: destroy the disposable stack only
make persistent-down    # rare, guarded: destroys the zone/cert/secrets
make bootstrap-down     # rare, guarded: destroys KMS/IAM
make state-down         # essentially never: destroys remote state itself
```

- **State** — the S3 backend and lock table Terraform/Terragrunt need to
  run at all. Expected to be created once and never destroyed for real.
- **Bootstrap** — the KMS key used to encrypt `secrets/*.enc`, plus
  foundational IAM. Long-lived; destroying it is rare and guarded.
- **Persistent** — the delegated `lab.<root-domain>` DNS zone (and its
  parent-zone NS delegation), its ACM certificate, and Secrets Manager.
  Survives `make down`. You'll run `persistent-up`/`persistent-down` more
  often than bootstrap/state, but still far less often than `up`/`down` —
  see [`terraform/live/persistent/README.md`](terraform/live/persistent/README.md)
  for required configuration (`PROJECT_NAME`/`REGION`/`SUBDOMAIN` env vars,
  plus the `root-domain`/`postgres-admin-password` secrets).
- **Disposable** — EKS, Karpenter, Argo CD, and everything it manages.
  Created by `make up`, destroyed by `make down`. This is the layer meant
  to be torn down and recreated routinely to control cost.

`make status` reports which layers currently have state in the shared
bucket. See `docs/architecture.md` sections 22–23 for the full startup
and shutdown sequence once the disposable layer exists.

## Next step

Read `docs/architecture.md` and `specs/000-constitution/spec.md` before
writing the first spec under `specs/001-...`.
