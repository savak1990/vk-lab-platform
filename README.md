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
stack — EKS, Karpenter, Argo CD, Envoy Gateway, NLB, Postgres, and
observability — are implemented and wired up behind `make up`/`make down`.
Kafka is deferred (ADR 0017). The GitHub OIDC provider and `lab.yml` are
also implemented — the platform can be started/stopped from GitHub
Actions, not just a workstation.

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
                        # lab.yml's vars.AWS_ROLE_ARN
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

make status             # reports which layers currently have state, for THIS PROJECT_NAME
make clusters           # lists every platform cluster live in the account, ALL projects
```

### Running more than one lab

`PROJECT_NAME` and `SUBDOMAIN` are the only two identity variables; everything
else is derived (`<project>-tf-state`, `<project>-eks`, `secrets/<project>/`,
`/<project>/...` SSM paths, `<subdomain>.<root-domain>`). Both are free-form
inputs on `lab.yml` and plain env vars locally, so a second lab is:

```sh
PROJECT_NAME=vk-lab-two SUBDOMAIN=two make full-up
```

That is the whole sequence — `bootstrap-up` creates the new project's state
bucket and generates its secrets (real random passwords) before anything needs
them. Do **not** run `make generate-secrets` first: that target forces
`FIXED_TEST_PASSWORDS=true` and writes publicly-known `"test"` passwords, and is
only for throwaway CI environments.

No IAM change is needed — `lab-role` is shared and scopes by naming convention.
Two rules the tooling enforces for you:

- **`PROJECT_NAME`**: lowercase letters, digits and hyphens, starting and ending
  alphanumeric, at most 23 characters. The charset is S3's (via
  `<project>-tf-state`); the length is what IAM's 64-char role-name cap leaves
  after the EKS module's `<cluster>-system-ng-` prefix and the provider's
  26-char suffix. `scripts/lib/require-valid-project-name.sh` refuses anything
  else before a single resource is created. Note `<project>-tf-state` must also
  be unique across *all* AWS accounts, which cannot be checked ahead of time.
- **`SUBDOMAIN`**: must differ per project. Two projects sharing one would
  contend for the same Route 53 zone; `scripts/require-unique-subdomain.sh`
  refuses before any apply.

Run `make clear-cache` when switching between projects in one checkout — every
composite target already does.

- **Account** — the shared secrets KMS key (`alias/lab-secrets`), the
  shared `lab-role` every project's GitHub Actions run assumes (scoped by
  naming convention, not per-project), the GitHub OIDC provider, and
  `eks-access-identity`. Applied once per AWS account, in its own dedicated
  state bucket so no project's `bootstrap-down` can ever affect it.
  Destroying it (`account-down`) affects every project in the account at
  once — expected to run essentially never. Applies in the platform's single
  region, `eu-west-1`, the same one every project's own layers use, so the
  shared KMS key is always reachable from them (ADR 0024).
- **Bootstrap** — this project's own state bucket, plus the delegated
  `lab.<root-domain>` DNS zone (and its parent-zone NS delegation) and its
  ACM certificate. Destroying it (`bootstrap-down`) requires
  `CONFIRM_DESTROY=<PROJECT_NAME>` to match exactly — the shared role has
  no per-project IAM scoping to fall back on, so this is the only guard.
- **Persistent** — the VPC and Secrets Manager. Survives `make down`. See
  [`terraform/live/persistent/README.md`](terraform/live/persistent/README.md)
  for required configuration (the `PROJECT_NAME` env var).
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
make clear-cache                               # clears .terragrunt-cache after switching PROJECT_NAME/SUBDOMAIN
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
