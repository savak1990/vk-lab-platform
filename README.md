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

The four targets below are not equally far along: `aws` is complete, `civo`
(ADR 0027) is complete through its first milestone, and `local` (ADR 0038)
brings up Argo CD, the operators, the Gateway, Postgres and observability —
see [Running locally on kind](#running-locally-on-kind) and spec LOCAL-022.

`hetzner` (ADR 0036, ADR 0037) is in progress. `make full-up` brings up the
k3s cluster, the cloud controller manager, the CSI driver, Argo CD, the
identity chain, Postgres, observability and the ingress: an Envoy Gateway
behind an hcloud `lb11` that forwards to the nodes over the private
network, with a Let's Encrypt wildcard certificate and Route 53 records
that follow the load balancer's address (spec HETZ-060). The address is
new on every `make up`, because this target reserves none.

Measured on 2026-09-22 with the default shape, three `cx33` in `fsn1`: a cold
`make full-up` from an empty account took 12m50s, and a full teardown took
about 20 minutes.

`make full-down` does not finish in one run on this target. Argo CD deletes the
PersistentVolumeClaims, but the CSI driver needs longer than
`ARGO_DOWN_PVC_WAIT_TIMEOUT` (180s) to detach and delete the volumes behind
them. `cluster-down` then finds a volume that outlived the cluster, deletes it,
and exits non-zero on purpose, which stops `make` before `persistent-down` and
`bootstrap-down` run. Run those two yourself afterwards, or raise
`ARGO_DOWN_PVC_WAIT_TIMEOUT`. Spec HETZ-047 owns the fix.

## Usage

The platform is built as four independent lifecycle layers, each with its
own Terraform/Terragrunt state, created in order and destroyed in reverse.
Later layers depend on earlier ones already existing; `make <layer>-up`
does not create the layers below it for you (it fails fast, naming the
command to run first, instead).

### Choosing a target

`PROVIDER` selects which cloud a command acts on. It defaults to `aws`, and
every other variable defaults to that provider's own value, so an unset
variable never changes behaviour.

```sh
PROVIDER=aws      # EKS on AWS (the default)
PROVIDER=civo     # managed Kubernetes on Civo
PROVIDER=hetzner  # self-managed k3s on Hetzner Cloud
PROVIDER=local    # one kind cluster on this machine; owns no cloud resources
```

### Lifecycle commands

Four independent layers, created in order and destroyed in reverse. A
`*-up` target never creates the layer below it — it fails fast and names the
command to run first.

| Command | Does | Frequency |
|---|---|---|
| `make account-up` | Account-global: its own state bucket, the shared secrets KMS key, GitHub OIDC, `lab-role`, `eks-access-identity`. Also sets `lab.yml`'s `vars.AWS_ROLE_ARN` | once per AWS account |
| `make bootstrap-up` | This project's state bucket, its `<subdomain>.<root-domain>` zone and certificate | once per project |
| `make persistent-up` | VPC, Secrets Manager, backups. Generates any missing project secrets | occasional |
| `make up` | The disposable cluster, then Argo CD and everything it manages | frequent |
| `make down` | Destroys the disposable layer only | frequent |
| `make persistent-down` | Destroys the VPC, every secret and every retained volume. Guarded | rare |
| `make bootstrap-down` | Destroys the zone, the certificate, then this project's state bucket. Guarded | rare |
| `make account-down` | Destroys the shared role, KMS key and OIDC provider — **every project in the account at once**. Guarded | essentially never |

Compositions, which change no individual command's own guards:

| Command | Equivalent to |
|---|---|
| `make platform-up` / `platform-down` | `persistent-up` → `up`, onto an existing Bootstrap layer, and the reverse |
| `make full-up` / `full-down` | `bootstrap-up` → `persistent-up` → `up`, and the exact reverse |

Layer commands can also be run on their own: `state-up`, `state-down`,
`cluster-up`, `cluster-down`, `argo-up`, `argo-down`.

What the table does not say about each layer:

- **Account** lives in its own state bucket, so no project's `bootstrap-down`
  can reach it. It applies in `eu-west-1` like every other layer, which is what
  keeps the shared KMS key reachable (ADR 0024).
- **Bootstrap** takes `CONFIRM_DESTROY=<PROJECT_NAME>` to destroy. The shared
  role has no per-project IAM scoping, so this guard is the only one.
- **Persistent** generates any missing password and never overwrites one that
  exists. `root-domain` is the exception: it names a real external domain, so
  `bootstrap-up` requires it to exist already.
- **Disposable** is `cluster-up` then `argo-up`, and `argo-down` then
  `cluster-down`. Argo CD's cascade must finish before the cluster goes (ADR
  0012).

`docs/architecture.md` sections 22–23 have the full startup and shutdown
sequence.

### Setup, secrets and inspection

| Command | Does |
|---|---|
| `make ca-init` | Generates the Roles Anywhere CA for a non-AWS target. `PROVIDER=civo\|hetzner`, `ROTATE=1` for a candidate |
| `make ssh-key-init` | Generates the Hetzner node SSH key. `PROVIDER=hetzner`, `ROTATE=1` for a candidate |
| `make secret-encrypt` / `secret-decrypt` | One value in or out of `secrets/`, through the shared KMS key |
| `make generate-secrets` | Throwaway secrets for a CI project. **Writes the publicly known password `test`** — never for a real lab |
| `make kubeconfig` / `test-kubeconfig` | The only commands that touch your own kubectl context |
| `make status` | Which layers currently hold state, for this `PROJECT_NAME` |
| `make clusters` | Every platform cluster live in the account, across all projects |
| `make clear-cache` | Clears every `.terragrunt-cache`. Run when switching projects |

### Checks

All offline, none need credentials: `make specs-check`, `make gitops-check`,
`make scripts-check`, `make test`.

`make scripts-check` is the shell layer's gate: `bash -n` parses every script,
`shellcheck -x -S warning` lints it, and every `tests/scripts/*-test.sh` runs.
Those tests keep their own targets for running one at a time —
`make secrets-check`, `make argo-watch-check`, `make node-config-check`,
`make pr-gate-check`.

### Environment variables

| Variable | Default | Accepted values |
|---|---|---|
| `PROVIDER` | `aws` | `aws` `civo` `hetzner` `local` |
| `PROJECT_NAME` | per provider | lowercase letters, digits and hyphens, at most 23 characters |
| `SUBDOMAIN` | per provider | must differ per project |
| `REGION` | `LON1` / `nbg1` | `civo` and `hetzner` only, see below; matched case-insensitively. Refused on `aws` |
| `NODE_TYPE` | `t4g.medium` / `g4s.kube.medium` / `cx33` | see below |
| `NODE_COUNT` | `1` / `3` / `3` | a positive integer |
| `CONFIRM_DESTROY` | unset | must equal `PROJECT_NAME`, on guarded targets |
| `ROTATE` | unset | `1`, on `ca-init` and `ssh-key-init` |
| `ROOT_DOMAIN` | unset | only used to seed `secrets/root-domain.enc` when missing |
| `FIXED_TEST_PASSWORDS` | unset | `true` for CI only |

Defaults are listed `aws` / `civo` / `hetzner`. `PROVIDER=local` owns no cloud
resources, so it **ignores** `REGION`, `NODE_TYPE` and `NODE_COUNT` — leaving
them exported while switching targets is harmless.

**`REGION` does not apply to `aws`.** Every AWS resource this platform creates
lives in `eu-west-1`, including a Civo or Hetzner project's state bucket, SSM
parameters and Roles Anywhere chain. `PROVIDER=aws` with any other region is
refused rather than ignored, because a typed region is a statement of intent
the platform cannot honor. See ADR 0024 and ADR 0040.

`REGION`, `NODE_TYPE` and `NODE_COUNT` are validated **before any cloud call
and without credentials**, so a typo fails in under a second rather than part
way through an apply. The allowed shapes, and why each is on the list, are in
`scripts/lib/catalog.sh` — it is a deliberately short cost guardrail, not a
copy of each cloud's catalogue.

| `PROVIDER` | `REGION` | `NODE_TYPE` allowed there |
|---|---|---|
| `aws` | fixed at `eu-west-1`, not an input | `t4g.medium`, `t4g.large`, `m6g.large` |
| `civo` | `LON1` `NYC1` `FRA1` `MUM1` | `g4s.kube.medium` `g4s.kube.large` `g4m.kube.small` `g4p.kube.small` |
| `hetzner` | `nbg1` | `cx23` `cx33` `cx43` `cx53` `cpx32` `cpx42` |
| `hetzner` | `hel1` | `cx23` `cx33` `cpx32` `cpx42` |
| `hetzner` | `fsn1` | `cx23` `cx33` `cx43` `cpx32` `cpx42` |

Node types are listed per region because availability differs: `cx43` sells in
`nbg1` and `fsn1` but not `hel1`. All four Civo sizes sell in all four Civo
regions, checked against `civo size ls` per region on 2026-09-22.

Some of the Hetzner and Civo types are above the lab's cost ceiling on a
monthly basis and are allowed anyway. The Hetzner limit is on server count
rather than spend, so when it binds, fewer and bigger is the only shape that
fits. And a run that lives 25 minutes costs cents at any of these prices — the
monthly figure is the wrong metric for a cluster destroyed before the hour is
out.

### Approximate cost

Prices below are per node per month. They come from `scripts/lib/catalog.sh`,
which records each figure with its source and date — the AWS Pricing API and
the Hetzner API on 2026-09-21, Civo from <https://www.civo.com/pricing> on
2026-09-22. AWS and Civo are USD on demand. Hetzner is gross, VAT included
at 21 percent. `GET /v1/pricing` reports `currency: USD` for this account,
although Hetzner's public price list is in EUR; the amounts agree, so only
the label is in doubt. See `specs/hetzner/research.md`.

| `PROVIDER` | `NODE_TYPE` | vCPU / RAM | Per node, per month |
|---|---|---|---|
| `aws` | `t4g.medium` *(default)* | 2 / 4 GiB | USD 26.86 |
| `aws` | `t4g.large` | 2 / 8 GiB | USD 53.73 |
| `aws` | `m6g.large` | 2 / 8 GiB | USD 62.78 |
| `civo` | `g4s.kube.medium` *(default)* | 2 / 4 GiB | USD 21.73 |
| `civo` | `g4s.kube.large` | 4 / 8 GiB | USD 43.45 |
| `civo` | `g4m.kube.small` | 2 / 16 GiB | USD 78.21 |
| `civo` | `g4p.kube.small` | 4 / 16 GiB | USD 86.91 |
| `hetzner` | `cx23` | 2 / 4 GiB | USD 7.85 |
| `hetzner` | `cx33` *(default)* | 4 / 8 GiB | USD 12.09 |
| `hetzner` | `cx43` | 8 / 16 GiB | USD 22.37 |
| `hetzner` | `cx53` | 16 / 32 GiB | USD 42.34 |
| `hetzner` | `cpx32` | 4 / 8 GiB | USD 50.81 |
| `hetzner` | `cpx42` | 8 / 16 GiB | USD 99.21 |

`m6g.large` costs 17% more than `t4g.large` for identical specs and is kept on
purpose: `t4g` is burstable and throttles to a 20% baseline once its CPU
credits run out. It is insurance, never the default.

Civo's ladder reads differently. `g4s.kube.large` doubles both dimensions for
double the price, so cost per unit is flat. Above it the two axes separate:
`g4m.kube.small` buys four times the memory of the default without adding a
core, and `g4p.kube.small` buys the same memory with four cores. Pick `g4m` for
a workload that runs out of memory first, `g4p` for one that runs out of CPU.

**A lab left running for a month**, at each provider's default shape:

| `PROVIDER` | Default shape | Nodes | Control plane | Total |
|---|---|---|---|---|
| `aws` | 1 × `t4g.medium` | USD 26.86 | USD 73.00 | **~USD 100** |
| `civo` | 3 × `g4s.kube.medium` | USD 65.19 | free | **~USD 65** |
| `hetzner` | 3 × `cx33` | USD 36.27 | — | **~USD 49** |

EKS charges USD 0.10 per cluster per hour whatever the node count, which is
why the smallest AWS lab still costs more than the largest Civo one. Civo
gives the k3s control plane away. Hetzner sells no managed Kubernetes, so its
control plane *is* the first of the three nodes and is already counted — see
`NODE_COUNT` above. Two things the Hetzner total includes and the per-node
table above does not: one primary IPv4 for each node at USD 0.726 gross per
month, and the `lb11` at USD 10.27 gross. All Hetzner figures are gross,
VAT included at 21 percent, read from `GET /v1/pricing` on 2026-09-22.

**Not in those totals**, and unavoidable on any target:

- The load balancer — an AWS NLB, or a Civo load balancer at USD 10.86 per
  month. The Hetzner `lb11` is USD 10.27 gross per month, billed hourly,
  and is counted in the Hetzner total below rather than left out here.
- Block storage for Postgres — Civo charges USD 0.11 per GB per month.
- The AWS-side resources every target keeps in `eu-west-1`: the Route 53 zone,
  the state and backup S3 buckets, SSM parameters and the shared KMS key. Tens
  of cents per month, and they survive `make down` by design.
- Karpenter workload capacity on AWS, capped at roughly two medium nodes.

**The monthly figure is the wrong one to plan against.** This platform is
built to be destroyed: `make down` removes everything disposable and leaves
only the cheap persistent tail. The measured number that matters is the
lifecycle run — about 55 minutes across both clouds for a little under one US
dollar.

### Worked examples

```sh
# The defaults. Identical to running with nothing set.
make full-up

# Civo, in Frankfurt instead of London.
PROVIDER=civo REGION=FRA1 make full-up

# Hetzner: three cx33 for the lab, in Helsinki rather than Nuremberg.
PROVIDER=hetzner REGION=hel1 NODE_COUNT=3 make full-up

# A bigger AWS system node group. AWS takes no REGION.
PROVIDER=aws NODE_TYPE=t4g.large make up

# One kind cluster locally. No cloud, no credentials.
PROVIDER=local make up
```

On Hetzner the server limit is **per account, not per project**, and defaults
to 5. A three-node lab plus a two-node CI run is exactly that limit, so
`NODE_COUNT` is how the two are kept from colliding.

### Running locally on kind

`PROVIDER=local` runs the same `gitops/` content on a kind cluster on your own
machine. It makes no cloud API call and needs no credentials.

```sh
PROVIDER=local make up       # ~8 min: kind, Argo CD, then the platform
PROVIDER=local make argo-up  # re-sync after you edit gitops/ - see below
PROVIDER=local make test     # ~10 s: the E2E suite, against this cluster
PROVIDER=local make down     # ~1 min: deletes the cluster and all its data
```

Needs `docker`, `kind`, `helm`, `kubectl`, `go` and the `argocd` CLI. Bootstrap
and Persistent own no cloud resources here, so `make full-up` does the same as
`make up`.

**What runs.** Argo CD, Envoy Gateway, PostgreSQL, Prometheus, Grafana, Loki,
Alloy and metrics-server — the same charts the cloud targets use, at laptop
scale.

**Testing it.** `make test` runs the same Go suite the cloud targets run, as a
read-only ServiceAccount rather than as admin. `make test-argocd`,
`make test-grafana` and `make test-postgres` run one service each. The suite
asks the cluster how to reach a service, so no test knows it is on kind.

**How to reach it.** `make up` prints one `kubectl port-forward` command that
serves every component on one port, by path: `/` is Argo CD and `/grafana` is
Grafana, both `admin` / `test`. A port-forward cannot present a Host header, so
this target matches routes by path where the cloud targets match by hostname.

**The edit loop is the point.** The root Application syncs from your working
tree. Edit anything under `gitops/`, run `PROVIDER=local make argo-up`, and the
change reconciles with **no commit and no push**. That is why
`syncPolicy.automated` is omitted on this target.

**Where the data goes.** Grafana keeps no volume. Prometheus and Loki take 1Gi
each and PostgreSQL 5Gi, all on `standard` — kind's own local-path provisioner,
which hands out a directory inside the node container instead of a disk:

```
/var/local-path-provisioner/pvc-<id>_<namespace>_<claim>
```

That directory enforces no size, so the limits that hold are the 6h retention
windows and Prometheus's `retentionSize`, not the claims. All three volumes
together measured under 100 MB.

`make down` deletes the node container, and every directory in it goes too: a
measured teardown left no cluster, no container and no Docker volume. Docker
does not give that space back to macOS by itself — `docker system prune` does.

**What it is not.** Throwaway data: no persistence guarantee, no
destroy/recreate proof, no backups. No load balancer, no DNS, no TLS.
Alertmanager and External Secrets stay off — [`specs/local/`](specs/local/)
names every omission. A green local run is never a substitute for the `aws`
lifecycle test.

### Running more than one lab

`PROJECT_NAME` and `SUBDOMAIN` are the only two identity variables; everything
else is derived (`<project>-<region>-tf-state`, `<project>-eks`,
`secrets/<project>/`, `/<project>/...` SSM paths, `<subdomain>.<root-domain>`).
The `<region>` in the bucket name is the *provider's* region, so the same
project in two Civo regions gets two buckets. Both variables are free-form
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
  `<project>-<region>-tf-state`); the length is what IAM's 64-char role-name cap
  leaves after the EKS module's `<cluster>-system-ng-` prefix and the provider's
  26-char suffix. `scripts/lib/require-valid-project-name.sh` refuses anything
  else before a single resource is created. Note the bucket name must also be
  unique across *all* AWS accounts, which cannot be checked ahead of time.
- **`SUBDOMAIN`**: must differ per project, and you MUST set it explicitly for
  a second lab. Its default is keyed on `PROVIDER`, not on `PROJECT_NAME`, so a
  second Civo project started without it inherits `SUBDOMAIN=civo` and contends
  for the same Route 53 zone. `scripts/require-unique-subdomain.sh` refuses
  before any apply, but only after a Route 53 call, not offline.

Run `make clear-cache` when switching between projects in one checkout — every
composite target already does.

### Running a lifecycle target from GitHub Actions

`lab.yml` is dispatched by hand (Actions → **lab** → *Run workflow*) and maps
1:1 onto a `make` target. These inputs shape the run:

- **`provider`** — `aws` or `civo`. Selects the whole stack, exactly like
  `PROVIDER=` locally.
- **`project_name`** / **`subdomain`** — leave both blank for that provider's
  own default (`vk-lab-platform`/`lab`, or `vk-civo-lab`/`civo`). A blank input
  is omitted rather than exported empty, so the Makefile stays the single place
  those defaults live. Give a custom project its own subdomain.
- **`region`** / **`node_type`** / **`node_count`** — leave blank for the
  provider's default (`LON1`/`g4s.kube.medium`/`3` on Civo,
  `nbg1`/`cx33`/`3` on Hetzner, `eu-west-1`/`t4g.medium`/`1` on AWS). They are free strings, not dropdowns:
  which node types sell depends on the provider *and* the region, and GitHub
  has no dependent dropdown. `make` refuses a bad combination offline in the
  job's first seconds. **`region` applies to Civo and Hetzner only** — on AWS
  the region is fixed at `eu-west-1` and a value here is refused, not ignored
  (ADR 0040).
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
| Only `.md` files — specs, docs, README | Secret scanning and the specs layout check, ~30 seconds | green, no cloud spend |
| Touches `terraform/`, `gitops/`, `scripts/`, `tests/`, `images/`, `Makefile`, `go.mod`, or a workflow | The static checks | red — add the label |
| …and carries the **`ci:lifecycle`** label | Every provider that has a job: a cluster is created, `make test` runs against it, and it is destroyed | green if all of that passed |
| …**plus `ci:aws` and/or `ci:civo`** | Only the selected providers | green if those passed; the run names the clouds it skipped |
| …and carries **`ci:skip-lifecycle`** instead | The static checks only | green, but the waiver is recorded — see below |

**`ci:lifecycle` is the trigger; the provider labels only narrow it.** A
provider label on its own starts nothing, so you can add two of them and then
fire one run — rather than two runs that cancel each other's validation. To run
Civo alone: add `ci:civo`, then add `ci:lifecycle`.

Pick the clouds the change actually needs. A Hetzner-only Terraform change does
not need an EKS cluster, and AWS is most of the 55 minutes. `ci:hetzner` and
`ci:local` name jobs that do not exist yet — selecting one fails the gate with a
message rather than quietly doing nothing.

A pull request is **documentation-only** when every changed file ends in `.md`.
It skips the four heavy checks — Terraform, GitOps, YAML and Actions lint — which
is the ~9 minutes of `validate-terraform` on every other pull request. Two checks
still run, because both matter for Markdown: `gitleaks`, since a token pasted into
a spec is exactly the leak it exists for, and `specs-check`, which catches a
broken spec link or a status letter that no longer matches. One non-Markdown file
anywhere in the pull request runs everything.

`validate-terraform` also skips when the pull request changes nothing under
`terraform/`, `secrets/` or `lifecycle-test.yml`. A `gitops/`-only change, for example,
saves those ~9 minutes. The lifecycle check still runs when labeled.

Adding the label starts the run immediately against the pull request's current
commit — no empty commit, no extra push. Removing and re-adding the label is how
you re-run it. A run takes about 55 minutes and costs a little under one US
dollar for both clouds.

Remove the label while you iterate. A push cancels the older run's static
checks, so the new commit's checks start at once. It never cancels a lifecycle
job: that would kill the teardown job and leave a cluster billing, so a second
lifecycle run queues behind the first instead.

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

## Next step

Read `docs/architecture.md` and `specs/shared/000-D-constitution/spec.md` before
you write a new spec under `specs/`. Each spec folder name carries a status
letter; [`specs/README.md`](specs/README.md) explains them.
