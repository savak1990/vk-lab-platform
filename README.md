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

make gitops-check       # offline: renders gitops/ for target=aws/civo/local and
                         # checks it - aws against the committed golden baseline
                         # (tests/golden/gitops-aws), civo/local structurally
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

### Running a lifecycle target from GitHub Actions

`lab.yml` is dispatched by hand (Actions → **lab** → *Run workflow*) and maps
1:1 onto a `make` target. Four inputs shape the run:

- **`provider`** — `aws` or `civo`. Selects the whole stack, exactly like
  `PROVIDER=` locally.
- **`project_name`** / **`subdomain`** — leave both blank for that provider's
  own default (`vk-lab-platform`/`lab`, or `vk-civo-lab`/`civo`). A blank input
  is omitted rather than exported empty, so the Makefile stays the single place
  those defaults live. Give a custom project its own subdomain.
- **`production_tls`** — Civo only, ignored on AWS. Ticked orders a real
  Let's Encrypt certificate. Untick it for a throwaway project: the production
  duplicate-certificate quota is shared with the personal lab, and the staging
  issuer exercises the same code path. The `test` job then verifies endpoints
  without checking the chain.

**The branch selector works.** Whatever ref you pick in *Use workflow from* is
checked out for Terraform and the scripts, **and** is what Argo CD reconciles
`gitops/` from — the workflow passes it through as `TARGET_REVISION`. So a
branch run tests GitOps changes too, not only Terraform. Push the branch first;
Argo CD fetches it from GitHub, not from the runner.

No repository secret is involved. The run assumes `lab-role` through OIDC, and
the Civo API token is decrypted from `secrets/civo-token.enc` with that same
role, then masked in the log.

### The merge gate

`main` is protected: every change lands through a pull request, and squash is
the only merge method.

One status check, **`pr-gate`**, decides whether a pull request can merge. It
always reports, never sits pending, and it works out from the changed files
whether the expensive half is needed:

| Your pull request | What runs | `pr-gate` |
|---|---|---|
| Documentation or specs only | The static checks | green, no cloud spend |
| Touches `terraform/`, `gitops/`, `scripts/`, `tests/`, `images/`, `Makefile`, `go.mod`, or a workflow | The static checks | red — add the label |
| …and carries the **`ci:lifecycle`** label | One EKS cluster and one Civo cluster are created, `make test` runs against both, and both are destroyed | green if all of that passed |
| …and carries **`ci:skip-lifecycle`** instead | The static checks only | green, but the waiver is recorded — see below |

Adding the label starts the run immediately against the pull request's current
commit — no empty commit, no extra push. Removing and re-adding the label is how
you re-run it. A run takes about 55 minutes and costs a little under one US
dollar for both clouds.

Remove the label while you iterate. Pushing during a run does not cancel it:
cancelling would kill the teardown job and leave a cluster billing, so a second
run queues behind the first instead.

The two CI projects are `vk-lab-ci`/`awsci` on AWS and `vk-civo-ci`/`civoci`
on Civo, both fixed. The Civo leg uses Let's Encrypt **staging** on purpose, so
per-pull-request runs do not consume the production quota your personal lab
shares.

#### Waiving the check

`ci:skip-lifecycle` merges an infrastructure change without bringing up either
cluster. It exists for the cases where the hour is genuinely not worth it — a
revert, a typo in a comment, an urgent fix.

It waives only the two-cloud half. Static validation still has to pass.

The waiver is deliberately loud. `pr-gate` stays green but emits a warning and
writes a **Lifecycle check waived** block into the run summary, listing the
files that would otherwise have required the check. A waived merge and a
verified merge are indistinguishable in the commit history otherwise, and the
first question asked when `main` breaks is whether the change was ever tested —
that answer should be findable.

Carrying both labels is an error, not a precedence rule: `pr-gate` fails and
asks you to remove one, and neither cluster is started.

If you find yourself reaching for the waiver often, the path list is too broad
for what it is trying to protect. Narrow the list rather than routinely waiving
the check — a gate that is usually waived is not a gate.

#### When a teardown fails

Each provider tears itself down even when its bring-up failed, and
`scripts/verify-no-leaks.sh` then asserts that nothing survived.

A run that is **cancelled** is the case to know about. Terraform creates a
resource and only then records it in state; kill it in between and the resource
is live in AWS but absent from state. `require-unique-subdomain.sh` then refuses
every later run for that project, so the gate stays red for everyone.

A `full-down` does not fix this, and it is worth knowing why before you try it:
`terraform destroy` reads state, not your account, so an empty state produces an
empty destroy plan and the teardown reports success while deleting nothing.

Run this instead, once per affected provider:

```bash
CONFIRM_DESTROY=vk-lab-ci PROJECT_NAME=vk-lab-ci SUBDOMAIN=awsci \
  ./scripts/force-clean-ci.sh aws

CONFIRM_DESTROY=vk-civo-ci PROJECT_NAME=vk-civo-ci SUBDOMAIN=civoci \
  ./scripts/force-clean-ci.sh civo
```

It clears the stale state lock, deletes the orphaned zone, and deletes the
orphaned `/<project>/` SSM parameters. That last one is the trap: the parameters
are free, so nothing flags them, but the next `bootstrap-up` fails with
`ParameterAlreadyExists` for a reason that looks unrelated.

The script refuses if the project's own state still tracks the zone — there,
`full-down` really is the right tool — and refuses any zone holding a record
beyond its own NS and SOA. Then re-add the label.

One more non-obvious case: GitHub keeps at most one pending job per concurrency
group. Labelling a third pull request while two labelled runs are already in
flight cancels its lifecycle job rather than queueing it. Nothing has been
created at that point so nothing leaks, but `pr-gate` goes red — re-add the
label once a run finishes.

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
  (`make secret-encrypt NAME=root-domain VALUE=<domain> SCOPE=global`) — `bootstrap-up`
  is what actually requires/decrypts it, since Route53 lives there now.
- **Disposable** — EKS, Karpenter, Argo CD, and everything it manages
  (Postgres, Kafka, Envoy Gateway, NLB, observability). Created by
  `make up` (`cluster-up` then `argo-up` under the hood), destroyed by
  `make down` (`argo-down` then `cluster-down` — Argo's cascade must
  finish before the cluster comes down, see ADR 0012). This is the layer
  meant to be torn down and recreated routinely to control cost.

Other targets:

```bash
make kubeconfig                            # switches YOUR kubectl context to the disposable cluster
                                           # (every other target uses .kube/<project>.config instead,
                                           #  so a bring-up never moves your context - ADR 0034)
make clear-cache                               # clears .terragrunt-cache after switching PROJECT_NAME/SUBDOMAIN
make secret-encrypt NAME=<name> VALUE=<value>  # encrypts one secrets/<project>/<name>.enc
make secret-decrypt NAME=<name>                # prints one secret's plaintext to stdout
PROJECT_NAME=vk-lab-ci ROOT_DOMAIN=<domain> make generate-secrets  # throwaway CI secrets (fixed "test" passwords)
```

See `docs/architecture.md` sections 22–23 for the full startup and
shutdown sequence.

## Next step

Read `docs/architecture.md` and `specs/shared/000-D-constitution/spec.md` before
writing a new spec under `specs/`. See [`specs/`](specs/) for what's
already implemented (001–016, 024) and what's next.
