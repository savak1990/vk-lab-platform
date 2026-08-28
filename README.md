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

State, Bootstrap, and Persistent (specs 001–002) and the full Disposable
stack — EKS, Karpenter, Argo CD, Envoy Gateway, NLB, Postgres, Kafka, and
observability (specs 003–014, 024) — are implemented and wired up behind
`make up`/`make down`. GitHub Actions-driven lifecycle automation (spec
015 onward) is not yet built, so the platform is currently
workstation-invoked only.

## Usage

The platform is built as four independent lifecycle layers, each with its
own Terraform/Terragrunt state, created in order and destroyed in reverse.
Later layers depend on earlier ones already existing; `make <layer>-up`
does not create the layers below it for you (it fails fast, naming the
command to run first, instead).

```bash
make state-up          # once, ever: remote state bucket + locking
make bootstrap-up      # rare: KMS key, GitHub OIDC, foundational IAM
make persistent-up     # occasional: lab.<root-domain> zone + cert, secrets
make up                # frequent: EKS cluster + Argo CD + everything it manages

make down               # frequent: destroy the disposable stack only
make persistent-down    # rare, guarded: destroys the zone/cert/secrets
make bootstrap-down     # rare, guarded: destroys KMS/IAM
make state-down         # essentially never: destroys remote state itself

make full-up            # from nothing: state-up -> bootstrap-up -> persistent-up -> up
make full-down          # the exact reverse of full-up (rarely used - each
                         # step keeps its own guard/confirmation)

make status             # reports which layers currently have state in the shared bucket
```

- **State** — the S3 backend and lock table Terraform/Terragrunt need to
  run at all. Expected to be created once and never destroyed for real.
- **Bootstrap** — the KMS key used to encrypt `secrets/<project>/*.enc`,
  plus foundational IAM. Long-lived; destroying it is rare and guarded,
  and deletes those `.enc` files (for the current `PROJECT_NAME` only)
  once the key is gone.
- **Persistent** — the delegated `lab.<root-domain>` DNS zone (and its
  parent-zone NS delegation), its ACM certificate, and Secrets Manager.
  Survives `make down`. You'll run `persistent-up`/`persistent-down` more
  often than bootstrap/state, but still far less often than `up`/`down` —
  see [`terraform/live/persistent/README.md`](terraform/live/persistent/README.md)
  for required configuration (`PROJECT_NAME`/`REGION`/`SUBDOMAIN` env vars).
  `persistent-up` auto-generates any missing password
  (`postgres-app-password`, `grafana-admin-password`,
  `argocd-admin-password`) — it never overwrites one that already exists.
  `root-domain` is the one exception: it's a real external domain, so it's
  only filled in from `$ROOT_DOMAIN` when set, and otherwise must already
  exist under `secrets/<project>/root-domain.enc`
  (`make secret-encrypt NAME=root-domain VALUE=<domain>`).
- **Disposable** — EKS, Karpenter, Argo CD, and everything it manages
  (Postgres, Kafka, Envoy Gateway, NLB, observability). Created by
  `make up` (`cluster-up` then `argo-up` under the hood), destroyed by
  `make down` (`argo-down` then `cluster-down` — Argo's cascade must
  finish before the cluster comes down, see ADR 0012). This is the layer
  meant to be torn down and recreated routinely to control cost.

Other targets:

```bash
make eks-kubeconfig                            # points kubectl at the disposable cluster
make clear-cache                               # clears .terragrunt-cache after switching PROJECT_NAME/REGION/SUBDOMAIN
make secret-encrypt NAME=<name> VALUE=<value>  # encrypts one secrets/<project>/<name>.enc
make secret-decrypt NAME=<name>                # prints one secret's plaintext to stdout
PROJECT_NAME=vk-lab-ci ROOT_DOMAIN=<domain> make generate-secrets  # throwaway CI secrets (fixed "test" passwords)
```

See `docs/architecture.md` sections 22–23 for the full startup and
shutdown sequence.

## Next step

Read `docs/architecture.md` and `specs/000-constitution/spec.md` before
writing a new spec under `specs/`. See [`specs/`](specs/) for what's
already implemented (001–014, 024) and what's next (015 onward: GitHub
Actions-driven lifecycle).
