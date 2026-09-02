# Account stack

Account-global resources: created once per AWS account and shared by every
project, every fork owner's lab, and every ephemeral CI environment in that
account.

## Why this is separate from `bootstrap/`

Both layers hold resources that are created once and essentially never
destroyed, so grouping them by lifecycle looks right. They differ on a second,
independent axis: **scope**.

Every resource here is account-global and shared: the secrets KMS key, the
`lab-role` every project's GitHub Actions run assumes, the GitHub OIDC
provider, `eks-access-identity`. `bootstrap/`'s own units (this project's
state bucket, the lab DNS zone + ACM cert) are per-project instead — a second
`PROJECT_NAME` gets its own, never shares.

Putting a per-project resource in this account-global layer breaks as soon as
a second project needs its own copy - AWS rejects a second `EntityAlreadyExists`
create, or worse, a second apply silently rescopes a shared resource away from
the first project. Since `make account-up`/`account-down` and `make
bootstrap-up`/`bootstrap-down` both discover units by listing the directory
they `cd` into, keeping each layer's units in its own directory makes the
wrong layer's resources unreachable to the other by construction.

## What belongs here

A unit belongs in this layer only if it is account-global: exactly one must
exist per AWS account regardless of how many projects or PR environments do.
Being long-lived is not sufficient on its own — a per-project resource that's
merely long-lived belongs in `bootstrap/` instead.

Qualifies: the secrets KMS key (`alias/lab-secrets` — shared by every
project's `secrets/<project>/*.enc`), `lab-role` (the shared role every
project's GitHub Actions run assumes; scoped by naming convention, not
per-project ARNs), the GitHub OIDC provider, `eks-access-identity` (a
Kubernetes-access-only identity with no AWS permission policy, reused across
every project's clusters), `eks-test-identity` (same shape as
`eks-access-identity` — no AWS permission policy — but mapped to a read-only
EKS access entry instead of `AmazonEKSClusterAdminPolicy`, so `make test`/the
CI test job never runs with cluster-admin access; see
`terraform/modules/eks/main.tf`). Does not qualify: this project's own state
bucket, the lab DNS zone + ACM cert (both per-project, in `bootstrap/`).

## Prerequisite: this layer's own dedicated state bucket

`terraform/live/account-state/` creates a state bucket dedicated to this
layer alone — never a project's own `${PROJECT_NAME}-tf-state`, so no
project's `bootstrap-down` can ever orphan this layer's Terraform state.
`scripts/account-up.sh` bootstraps it first (`scripts/account-state-up.sh`,
the same two-phase local-then-migrate dance `state-up.sh` uses), before
applying anything else — no separate manual step needed.

## Usage

```
make account-up       # run once per AWS account, from a workstation
make account-down     # guarded (CONFIRM_DESTROY=<PROJECT_NAME>), expected to run essentially never
```

This layer applies in `ACCOUNT_MAIN_REGION` (defaults `eu-west-1`,
`terraform/live/root.hcl`'s `account_main_region` local), independent of
whatever `PROJECT_REGION` any given project uses — the secrets KMS key created here
only exists in that one region. `scripts/secret-encrypt.sh`/`secret-decrypt.sh`
read the same variable directly (not `PROJECT_REGION`) for their `aws kms`
calls, so a project running under a different `PROJECT_REGION` still resolves the
same key. Only set `ACCOUNT_MAIN_REGION` explicitly if `account-up` was run
against a non-default region — every other command leaves it at the default.

`make account-up` also sets `lab.yml`'s `vars.AWS_ROLE_ARN` (from `lab-role`'s
own ARN — set once, ever, never per-project) and `secrets.ROOT_DOMAIN`
(decrypted locally from `secrets/$PROJECT_NAME/root-domain.enc`, never
something a GitHub Actions role does at runtime). Re-running is a no-op
per-resource: the script checks each one independently (not the whole layer
at once — a genuinely new unit still gets applied even after an older one
already exists) and exits without applying whatever it finds already present.

`eks-access-identity`'s trust policy names whichever IAM identity is running
`make account-up` at apply time — always you, since this command is never
run from CI. Resolved via `data "aws_caller_identity"` +
`data "aws_iam_session_context"` (not a manually-supplied ARN), so an SSO
session's ARN resolves to its underlying role ARN, path included, rather than
a hand-reconstructed one that would silently miss it. If you later
authenticate differently (switch from an IAM user to SSO, or vice versa),
that recorded principal goes stale: `kubectl` starts failing with
`Unauthorized` even though the access entry is still correct, and the fix is
to re-run `make account-up` under the new identity, not to touch the cluster.

`lab-role` (this layer) chains a plain `sts:AssumeRole` onto `eks-access-identity`
(also this layer) — trusted via the account root scoped down by a
`aws:PrincipalArn` condition naming `lab-role`'s fixed ARN, not a direct
principal reference, so ordering between the two units' first applies never
matters.

Neither target appears in a composite target: not `up`, not `full-up`, not
`bootstrap-up`/`bootstrap-down`.

`make account-down` destroys every project's ability to authenticate/decrypt
secrets at once — refuses while this project still has Bootstrap, Persistent,
or Disposable state, requires `CONFIRM_DESTROY=<PROJECT_NAME>`, then hands off
to terragrunt's own destroy, followed by this layer's own dedicated state
bucket deletion (`scripts/account-state-down.sh`). Note the limit of the
state-based guard: it can only see `${PROJECT_NAME}`'s own state bucket.
Another project or CI environment in the same account may still depend on
the shared role/KMS key, and there is no cheap way to enumerate them — so the
script warns and names the account rather than pretending to know.
