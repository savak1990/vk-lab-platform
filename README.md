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

## Status: spec stage

Only the architecture, constitution, and ADR exist today. No Terraform,
GitOps config, or CI workflows are in this repository yet.

## Planned usage

Not runnable yet. Once built, the platform starts and stops with:

```bash
make up    # create the disposable stack (EKS, Argo CD, workloads)
make down  # destroy the disposable stack; persistent AWS state stays
```

See `docs/architecture.md` sections 22–23 for the full startup and
shutdown sequence.

## Next step

Read `docs/architecture.md` and `specs/000-constitution/spec.md` before
writing the first spec under `specs/001-...`.
