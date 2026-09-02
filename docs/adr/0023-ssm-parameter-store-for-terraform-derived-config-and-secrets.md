# ADR 0023: SSM Parameter Store for Terraform-derived config and secrets

## Status

Accepted

## Context

Config Terraform produces (`fqdn`, `vpc_id`, `node_subnet_id`,
`acm_certificate_arn`, `root_domain`) reached Kubernetes/Helm only via
`terragrunt output` inside `scripts/argo-up.sh`, threaded through Helm
`--set` flags into the `root-application` chart's `helm.parameters`. That
path only works from inside this repo, with this repo's Terraform state on
disk — it breaks the moment a value needs to reach a consumer outside this
repo/state. The motivating case: a future, separate app repo (e.g. a Flutter
build) needing to read Cognito IDs and similar platform config at build time,
with no access to this repo's Terraform state and no interest in
script-threading.

Separately, `root_domain` was decrypted and validated independently inside
every project's own `bootstrap/route53` unit, even though it isn't actually
project-scoped data — one AWS account delegates from exactly one root
domain; `SUBDOMAIN` is what lets multiple projects/environments coexist
under it. And two operator inputs, `SUBDOMAIN` and `ACCOUNT_MAIN_REGION`,
were re-read fresh from env vars on every apply/script run with no
persistence: a forgotten re-export of a non-default value silently reverts
to the default, which for `SUBDOMAIN` risks Terraform planning to move the
entire delegated zone/certificate to a different fqdn. `PROJECT_REGION` has
the same env-var-only shape but a materially different risk profile — see
below for why it's deliberately left unpersisted.

A research finding during planning matters for scope: `fqdn`, `vpc_id`,
`node_subnet_id`, `acm_certificate_arn` are consumed at Argo CD repo-server
render time (`helm template`, rendering `Application` objects — envoy-
gateway's `HTTPRoute`/`Gateway`, external-dns's `domainFilters`, aws-load-
balancer-controller's `vpcId`), which runs with no live-cluster access and no
kube client. An External Secrets Operator-materialized `ConfigMap` lives *in*
the cluster; it cannot feed a render that happens outside it — there is no
in-cluster runtime pod today that consumes these four values. The Postgres
app password and Grafana admin password are different: they *do* have a
real in-cluster runtime consumer (CNPG, Grafana), already flowing through
ESO from one bundled AWS Secrets Manager secret (ADR 0014, spec 007-2 — a
real bug fix: the password must stay byte-identical across a CNPG snapshot
recovery).

**Motivation, in order:** access topology first — SSM parameters are
addressable by path, readable by any IAM principal with a scoped grant, no
Terraform state access required. This is what the cross-repo case above
actually needs. Cost is a secondary, minor factor: SSM Standard parameters
are free, and the previous Secrets Manager bundling had already made cost a
non-issue (~$0.40/month total) — this change is not "SSM is generally a
better secrets store," it is "the render-time/cross-repo config didn't need
a secrets manager at all, and retiring Secrets Manager once no credential
still needs it removes one AWS service from the platform." For the
region/subdomain persistence: fixing the "forgotten env var silently reverts
to a wrong value" risk class, not a topology or cost argument. The config-
value migration alone does not reduce bash line count — three `terragrunt
output` helpers collapse into one `ssm_output()` helper, roughly a wash. The
honest benefit there is eliminating silent value drift, not concision. The
one piece that actually reduces duplicated bash is `scripts/lib/region.sh`,
which collapses ~15-17 scripts' repeated region-default lines into one
sourced file.

## Decision

**Naming scheme:** `/<project>/<unit-directory>/<component>/<key>`, where
`<unit-directory>` is the literal top-level name under `terraform/live/`
that creates the value — `account`, `bootstrap`, `persistent`, or `cluster`
— not a semantic relabeling of it. An earlier draft tried to encode this
repo's narrative lifecycle classification (e.g. calling Route53/ACM
"persistent" even though they live under the `bootstrap/` directory) and
then had to document a mismatch against the AWS resource tags, which
inherit the literal directory name (`terraform/live/root.hcl`'s
`lifecycle_class` lookup maps `bootstrap` to the AWS tag `Lifecycle=
bootstrap`, a pre-existing convention this ADR doesn't change). Binding the
SSM path to the literal directory instead removes that mismatch entirely: it
is exactly the same directory `make down`/`make up` operate on, so the path
segment tells you directly whether a parameter survives teardown.

| Value | Written by | SSM path |
|---|---|---|
| `root_domain` | `terraform/live/account/root-domain` | `/account/root_domain` |
| `main_account_region` | `terraform/live/account/root-domain` | `/account/main_account_region` |
| `subdomain` | `terraform/live/bootstrap/route53` | `/<project>/bootstrap/route53/subdomain` |
| `fqdn` | `terraform/live/bootstrap/route53` | `/<project>/bootstrap/route53/fqdn` |
| `acm_certificate_arn` | `terraform/live/bootstrap/acm` | `/<project>/bootstrap/acm/certificate_arn` |
| `vpc_id` | `terraform/live/persistent/vpc` | `/<project>/persistent/vpc/vpc_id` |
| `postgres_app_password` | `terraform/live/persistent/secrets` | `/<project>/persistent/postgres/app_password` |
| `grafana_admin_password` | `terraform/live/persistent/secrets` | `/<project>/persistent/grafana/admin_password` |
| `argocd_admin_password_bcrypt` | `terraform/live/persistent/secrets` | `/<project>/persistent/argocd/admin_password_bcrypt` |
| `node_subnet_id` | `terraform/live/cluster/eks` | `/<project>/cluster/eks/node_subnet_id` |

`root_domain`/`main_account_region` are the only two with no project
segment, matching their account-global scope — the same reasoning `kms`/
`lab-role` already use.

**`root_domain` moves to account-up.** A new `terraform/modules/root-domain`
module decrypts `secrets/<project>/root-domain.enc` (the committed file
stays under a project-named directory for convention/discoverability even
though the value is account-global — no account-level secrets convention
exists yet, and inventing one is out of scope here) and looks it up with
`data "aws_route53_zone" { name = local.root_domain, private_zone = false }`
— this data source failing *is* the existence check, moved from every
project's own `bootstrap/route53` apply to the one account-level apply, so
it fails at `make account-up` instead of much later inside `full-up`.
`terraform/modules/route53-zone` now reads `/account/root_domain` via
`data "aws_ssm_parameter"` instead of decrypting its own copy.

**`vpc_id` is written from `persistent/vpc`, not `cluster/eks`.**
`terraform/modules/eks`'s own `vpc_id` output was always a pass-through of
`persistent/vpc`'s value. Writing the parameter from `cluster/eks` would
delete/recreate a value that never changes on every `make up`/`make down`
cycle. `node_subnet_id`, in contrast, genuinely is disposable-lifecycle data
created in `cluster/eks` — the AZ pin is this disposable run's own choice
(`include.root.locals.postgres_az`), not a constant — and it's the only
parameter in this scheme that must vanish on `make down` and reappear on the
next `make up`.

**Postgres/Grafana passwords move off Secrets Manager to SSM
`SecureString`,** fully retiring Secrets Manager from the repo. The
`terraform/modules/secrets-manager-secret` module is deleted, replaced by
`terraform/modules/persistent-secrets`, which decrypts the same two `.enc`
files (no new decryption logic) and writes each directly as its own
`SecureString` parameter, plus the Argo CD admin bcrypt hash as a plain
`String` (it's a one-way hash, not a reversible credential — no KMS
decryption applied to it before or after this change; Terraform reads it
via `file()`). This **supersedes ADR 0014's backend choice** while
preserving its actual decision and rationale unchanged: the password must
stay byte-stable across a CNPG snapshot recovery, and it still flows
entirely in-cluster via ESO, into the same `lab-postgres-app`/
`grafana-admin-credentials` Kubernetes Secrets, in the same shapes
(`kubernetes.io/basic-auth` for Postgres). Only the backend `ClusterSecretStore`
points at changed: `service: SecretsManager` → `service: ParameterStore`.
No `target.manifest`, no `ConfigMap`, no alpha ESO flag anywhere in this
change — the passwords stay on ESO's existing, stable `Secret` target.

**The Argo CD admin bcrypt hash's inclusion doesn't touch ADR 0012's
mechanism** — the hash is still injected via `--set
configs.secret.argocdServerAdminPassword=...` before Argo CD (and therefore
ESO) exist. Only `scripts/argo-up.sh`'s read source changes, from a local
file to an `ssm_output()` call, for consistency with everything else here.

**`SUBDOMAIN`/`ACCOUNT_MAIN_REGION` are persisted; `PROJECT_REGION`
deliberately is not.** `terraform/live/bootstrap/route53/terragrunt.hcl` now
shells out (via `run_cmd`, at terragrunt-eval time, before any apply) to
read the recorded `subdomain` parameter — querying it in `project_region`,
where that parameter actually lives, since `project_region` is supplied by
the operator/Makefile, not itself being discovered — and prefers it over
`get_env("SUBDOMAIN", "lab")`, falling back to the env var only on the very
first apply. `ACCOUNT_MAIN_REGION` is needed by shell scripts, not other
Terraform modules, so `scripts/lib/region.sh` centralizes the same pattern:
read `/account/main_account_region` (querying it in the region it's assumed
to already live in — itself defaulted from the env var — since that
parameter is written by a unit that applies in `ACCOUNT_MAIN_REGION`), fall
back to the env var if `ParameterNotFound`, abort loudly on any other AWS
error (auth, throttling) — a blanket fallback would silently swallow those
too, and region is exactly the kind of value where a silent wrong answer is
worse than a loud failure.

`PROJECT_REGION` cannot be persisted the same way: a parameter recording it
would itself live in `PROJECT_REGION`, so discovering it via SSM is
circular — querying the wrong region for it returns `ParameterNotFound`,
indistinguishable from "not written yet," which would silently confirm a
wrong guess instead of catching it. `PROJECT_REGION` stays a plain env-var
default. This is an accepted asymmetry, not an oversight: a wrong
`PROJECT_REGION` guess already fails loudly elsewhere in the same script run
(the state-bucket lookup, the EKS describe, ...), so the drift risk that
justifies persisting `SUBDOMAIN`/`ACCOUNT_MAIN_REGION` never applied to
`PROJECT_REGION` the same way.

**IAM.** The GitHub OIDC `lab-role` (account-global, no `PROJECT_NAME` input
of its own — see `terraform/modules/lab-role`) gets one new statement scoped
by path *shape*, matching its existing naming-convention-wildcard pattern
(`*-eks`, `*-secrets*`) rather than a project variable it doesn't have:
`ssm:PutParameter`/`GetParameter`/`GetParametersByPath`/`DeleteParameter`/
tag actions on `parameter/*/bootstrap/*`, `parameter/*/persistent/*`,
`parameter/*/cluster/*`, and `parameter/account/*`. Its old `SecretsManager`
statement is removed (no longer used); `SecretsManagerRandomPassword` and
the `KmsSecretsKey`/deny statements stay (unrelated to the storage backend
this ADR changes). The ESO controller's Pod Identity role
(`terraform/modules/external-secrets-pod-identity`) swaps
`secretsmanager:GetSecretValue`/`DescribeSecret` for `ssm:GetParameter` on
the two password parameter ARNs, plus `kms:Decrypt` on `alias/lab-secrets`
(the same key that already decrypts the committed `.enc` files).

## Consequences

- Every config/secret value Terraform produces that a script, Terraform
  module, or ESO needs to read back now lives in SSM Parameter Store, under
  one consistent, directory-literal naming scheme. `values.yaml`'s static
  Helm chart config (no Terraform origin, no cross-repo consumer) is
  unaffected — this ADR does not migrate it, and nothing here should be read
  as inviting that.
- AWS Secrets Manager is fully retired from this repo. Nothing here uses it
  going forward.
- `root_domain` is validated exactly once, at `make account-up`, instead of
  redundantly inside every project's `bootstrap/route53` apply. A first
  `bootstrap-up` for any project now depends on `account-up` having already
  run — true today in practice (account-up is a one-time per-account step),
  made an explicit dependency by this change.
- The render-time config values' ConfigMap design (a `ParameterStore`-backed
  `ExternalSecret` with `target.manifest.Kind: ConfigMap`, requiring ESO's
  `--unsafe-allow-generic-targets` alpha flag) is an accepted, deliberately
  **deferred** design: recorded here so it doesn't need re-deciding the day
  a real in-cluster runtime consumer for `fqdn`/`vpc_id`/etc. appears, but
  not built now, since enabling an alpha, upstream-labeled-`unsafe`
  controller flag with zero current consumer would be pure unmanaged risk.
- Migration order matters on first apply after this change: `make
  account-up` (creates `root-domain`, including the existence check) before
  any project's `bootstrap/route53`, `bootstrap/acm`, `persistent/vpc`,
  `persistent/secrets`, or `cluster/eks` — each of those units now writes
  (and in route53's case, also reads) an SSM parameter that must exist for
  `scripts/argo-up.sh` to succeed.
- Explicitly out of scope, permanently, not just deferred: Argo CD's
  admin-password *mechanism* itself (ADR 0012 — pre-Argo CD/ESO,
  structurally can't change).
- **Known limitation, deferred:** `fqdn` and the two ESO-consumed passwords
  are SecureString parameters written in `PROJECT_REGION`, encrypted with
  `alias/lab-secrets`, which exists only in `ACCOUNT_MAIN_REGION` — AWS
  requires an SSM SecureString's KMS key to be in the same region as the
  parameter. Running a cluster with `PROJECT_REGION != ACCOUNT_MAIN_REGION`
  will fail those three `aws_ssm_parameter` creates. Not fixed here;
  candidate fixes (falling back to the region's own `alias/aws/ssm`, or
  a multi-region KMS replica key) are deferred until region portability is
  actually exercised.
