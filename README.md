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
`make up`/`make down`. The GitHub OIDC provider and `lab.yml` (specs
015–016) are also implemented — the platform can be started/stopped from
GitHub Actions, not just a workstation.

## Usage

The platform is built as four independent lifecycle layers, each with its
own Terraform/Terragrunt state, created in order and destroyed in reverse.
Later layers depend on earlier ones already existing; `make <layer>-up`
does not create the layers below it for you (it fails fast, naming the
command to run first, instead).

```bash
make account-up        # once per AWS account: its own state bucket, shared
                        # secrets KMS key, GitHub OIDC provider, shared
                        # lab-role, eks-access-identity - also wires
                        # lab.yml's vars.AWS_ROLE_ARN/secrets.ROOT_DOMAIN
make bootstrap-up      # per project: this project's own state bucket,
                        # lab.<root-domain> zone + cert
make persistent-up     # occasional: VPC, Secrets Manager
make up                # frequent: EKS cluster + Argo CD + everything it manages

make down               # frequent: destroy the disposable stack only
make persistent-down    # rare, guarded: destroys the VPC/secrets
make bootstrap-down     # rare, guarded (CONFIRM_DESTROY=<PROJECT_NAME>):
                         # destroys the zone/cert, then this project's own
                         # state bucket
make account-down       # essentially never, guarded (CONFIRM_DESTROY=<PROJECT_NAME>):
                         # destroys the shared role/KMS/OIDC provider and
                         # the account's own state bucket - affects EVERY
                         # project in the account at once

make platform-up        # persistent-up -> up, onto an existing Bootstrap layer
make platform-down      # down -> persistent-down, stopping before Bootstrap

make full-up            # from nothing: bootstrap-up -> persistent-up -> up
make full-down          # the exact reverse of full-up (rarely used - each
                         # step keeps its own guard/confirmation)

make status             # reports which layers currently have state in the shared bucket
```

- **Account** — the shared secrets KMS key (`alias/lab-secrets`), the
  shared `lab-role` every project's GitHub Actions run assumes (scoped by
  naming convention, not per-project), the GitHub OIDC provider, and
  `eks-access-identity`. Applied once per AWS account, in its own dedicated
  state bucket so no project's `bootstrap-down` can ever affect it.
  Destroying it (`account-down`) affects every project in the account at
  once — expected to run essentially never. Applies in `ACCOUNT_MAIN_REGION`
  (defaults `eu-west-1`), independent of any project's own `PROJECT_REGION` — the
  shared KMS key only exists in that one region, so
  `secret-encrypt`/`secret-decrypt`/`generate-secrets` also read
  `ACCOUNT_MAIN_REGION` for their KMS calls regardless of which `PROJECT_REGION`
  the current project uses.
- **Bootstrap** — this project's own state bucket, plus the delegated
  `lab.<root-domain>` DNS zone (and its parent-zone NS delegation) and its
  ACM certificate. Destroying it (`bootstrap-down`) requires
  `CONFIRM_DESTROY=<PROJECT_NAME>` to match exactly — the shared role has
  no per-project IAM scoping to fall back on, so this is the only guard.
- **Persistent** — the VPC and Secrets Manager. Survives `make down`. See
  [`terraform/live/persistent/README.md`](terraform/live/persistent/README.md)
  for required configuration (`PROJECT_NAME`/`PROJECT_REGION` env vars).
  `persistent-up` auto-generates any missing password
  (`postgres-app-password`, `grafana-admin-password`,
  `argocd-admin-password`) — it never overwrites one that already exists.
  `root-domain` is the one exception: it's a real external domain, so it's
  only filled in from `$ROOT_DOMAIN` when set, and otherwise must already
  exist under `secrets/<project>/root-domain.enc`
  (`make secret-encrypt NAME=root-domain VALUE=<domain>`) — `bootstrap-up`
  is what actually requires/decrypts it, since Route53 lives there now.
- **Disposable** — EKS, Karpenter, Argo CD, and everything it manages
  (Postgres, Kafka, Envoy Gateway, NLB, observability). Created by
  `make up` (`cluster-up` then `argo-up` under the hood), destroyed by
  `make down` (`argo-down` then `cluster-down` — Argo's cascade must
  finish before the cluster comes down, see ADR 0012). This is the layer
  meant to be torn down and recreated routinely to control cost.

Other targets:

```bash
make eks-kubeconfig                            # points kubectl at the disposable cluster
make clear-cache                               # clears .terragrunt-cache after switching PROJECT_NAME/PROJECT_REGION/SUBDOMAIN
make secret-encrypt NAME=<name> VALUE=<value>  # encrypts one secrets/<project>/<name>.enc
make secret-decrypt NAME=<name>                # prints one secret's plaintext to stdout
PROJECT_NAME=vk-lab-ci ROOT_DOMAIN=<domain> make generate-secrets  # throwaway CI secrets (fixed "test" passwords)
```

See `docs/architecture.md` sections 22–23 for the full startup and
shutdown sequence.

## Next step

Read `docs/architecture.md` and `specs/000-constitution/spec.md` before
writing a new spec under `specs/`. See [`specs/`](specs/) for what's
already implemented (001–016, 024) and what's next.
