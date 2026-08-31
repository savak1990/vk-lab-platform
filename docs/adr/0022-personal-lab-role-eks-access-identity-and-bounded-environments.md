# ADR 0022: Personal-lab OIDC role, EKS access identity, and bounded-environment lifecycle workflows

## Status

Accepted

## Context

Spec 015 (ADR 0021) created the account-global GitHub OIDC provider. Spec 016
was next: an IAM role trusting that provider, plus `lab-up.yml`/`lab-down.yml`
workflows. Three problems surfaced while designing it, each with real
consequences if solved the naive way.

### 1. Kubernetes access follows whoever ran `apply`, not a deliberate grant

`terraform/modules/eks` set `enable_cluster_creator_admin_permissions = true`.
Whichever principal runs `terraform apply` on `disposable/eks` becomes the
cluster's sole Kubernetes admin. The operator's workstation and GitHub's role
are two different IAM principals; whichever one *didn't* create the cluster
this time has no access at all - breaking architecture.md §34's workstation/
GitHub equivalence in exactly the case it exists to guarantee.

A shared IAM role, assumed by both the operator and GitHub for everything, was
considered. Walked through concretely: operator runs `make up` under their own
default identity -> GitHub runs `lab-down.yml` (a different principal) -> GitHub's
`argo-down` has no cluster access; and the reverse. The shared-role model only
holds if every local invocation deliberately assumes the shared role instead
of the operator's default identity - which doesn't match actual usage.

### 2. IAM policies can't template a runtime input

The user wanted `lab-up.yml`/`lab-down.yml` to accept `PROJECT_NAME`/
`SUBDOMAIN`/`REGION` as workflow inputs, plus a depth selector reaching
`full-up`/`full-down`, so the same mechanism can later drive a disposable CI
project. Free-text inputs were rejected: an IAM policy's resource ARNs are
static strings baked in at Terraform-apply time, so a policy can't expand to
match an arbitrary runtime value without either staying narrow (input becomes
decorative) or broadening to match anything.

Rewriting the policy at runtime, keyed off the input, was also considered and
rejected: it requires the role to hold `iam:PutRolePolicy` on itself - a
textbook privilege-escalation pattern (a role that can rewrite its own
permissions can grant itself anything) - and it breaks the property that
motivated hand-enumeration in the first place, since the live policy would
diverge from what's committed the moment a run modifies it.

### 3. `full-down`'s guard scripts have no non-interactive path, and one universal cap is wrong for the future case

`bootstrap-down.sh`/`state-down.sh` have real interactive confirmations
(`state-down.sh`'s `read -r -p`; `bootstrap-down.sh`'s deferral to Terraform's
own `destroy` prompt) - deliberately, per spec 001 requirement 8 and ADR 0005.
Piping a canned answer (`echo y | make full-down`) was considered and
rejected: mechanically fragile (the two prompts expect different tokens), and
more fundamentally, it automates past a human-confirmation guard rather than
providing the confirmation the guard exists to require.

Capping the workflow's teardown depth at `persistent-down` universally was
also considered and rejected. `vk-lab-platform` genuinely should never reach
`bootstrap-down`/`state-down` from a workflow - but a future ephemeral
project (e.g. `vk-lab-ci`) is *meant* to be fully disposable; leaving nothing
behind, KMS key and state bucket included, is the actual point of tearing one
down, not a risk to guard against. A universal cap would block that
legitimate future case along with the one that should stay blocked.

## Decision

### Two roles, split by what they actually authorize

**`personal-lab-role`** (`terraform/live/bootstrap/personal-lab-role/`,
Bootstrap-lifecycle, per-project) does the AWS-API work: create/destroy the
disposable EKS cluster and, at `full-up`/`down-through-persistent` depth, the
Persistent layer (Route53 zone/record, ACM certificate, Secrets Manager). Its
permission policy is a hand-enumerated allow-list, no service wildcards,
scoped to exactly one registered `PROJECT_NAME`/`REGION` combination
(`vk-lab-platform`/`eu-west-1` today). Its trust policy's `sub` condition
scopes which GitHub repo can assume it - not which environment a given run
targets; that's enforced entirely by the resource ARNs in the permission
policy, which are fixed to this one combination. Adding a second combination
means adding its own set of ARNs to the policy, deliberately, at deploy time -
never accepting an arbitrary value at workflow-dispatch time.

Deliberately absent from this policy: `kms:ScheduleKeyDeletion`/`DeleteAlias`,
`s3:DeleteBucket`, or any other action that would delete the Bootstrap KMS key
or the State-layer bucket. `vk-lab-platform`'s role is IAM-incapable of what
`bootstrap-down`/`state-down` do, regardless of any script-level check - not
merely discouraged from it.

**`eks-access-identity`** (`terraform/live/account/eks-access-identity/`,
account-global, applied by `make account-up`) exists only to authenticate to
Kubernetes. Its trust policy has two statements: the operator's own IAM
identity via plain `sts:AssumeRole`, and the OIDC provider via
`sts:AssumeRoleWithWebIdentity` (same `aud`/`sub` conditions as
`personal-lab-role`). It carries **no permission policy** - tracing the actual
call path, `aws eks update-kubeconfig --role-arn <this>` calls
`eks:DescribeCluster` using the *caller's* current credentials, not this
role's, just to embed the ARN in the resulting kubeconfig; every later
`kubectl`/`helm` call triggers `aws eks get-token --role-arn <this>`, which
performs only `sts:AssumeRole` (checked by the trust policy above) and signs a
token locally - no other AWS API call happens on this role's behalf. What it
can do *inside* a cluster is the `aws_eks_access_entry`/
`aws_eks_access_policy_association` pair, attached to the cluster resource in
`disposable/eks`, not to this role.

`terraform/modules/eks` looks this role up by its fixed name
(`data "aws_iam_role" { name = "eks-access-identity" }`), never via a
Terragrunt `dependency` block - a `dependency` re-resolves its target's S3
backend using the *current* `PROJECT_NAME`, so under a second registered
combination it would look for the account layer's state in the wrong bucket.
The same reasoning applies to `personal-lab-role`'s own lookup of the OIDC
provider: `data "aws_iam_openid_connect_provider" { url = "..." }`, a live
lookup by fixed URL, not a dependency on whichever bucket happened to run
`account-up` first.

`enable_cluster_creator_admin_permissions` is now `false`. `disposable/eks`
grants `eks-access-identity` one unconditional `AmazonEKSClusterAdminPolicy`
access entry, created in the same `apply` that creates the cluster - so
there's never a window where the cluster exists but nothing can reach it, and
access no longer depends on which of the two principals happened to create it.
`Makefile`'s `eks-kubeconfig` target and `argo-up.sh`'s `update-kubeconfig`
call both gained `--role-arn <eks-access-identity ARN>`.

### Bounded environment choices, not free text, not runtime policy rewrites

`lab-up.yml`/`lab-down.yml` take `project_name`/`subdomain`/`region` as
`workflow_dispatch` `type: choice` inputs. Exactly one option exists in each
today (`vk-lab-platform`/`lab`/`eu-west-1`); registering a second combination
means adding a dropdown option and the matching IAM ARNs together. The
dropdown never changes what the policy's shape looks like - it only selects
among values the policy was already written to allow.

### `full-down` is available from day one, gated per environment, not capped universally

`down-through-persistent` (new Makefile target: `clear-cache argo-down
cluster-down persistent-down`) is available to every combination without
extra gating - it never touches Bootstrap/State. `full-down` (literal, all
the way down) is a separate `depth` option, but its guard is calibrated per
registered combination in two independent places, both built now even though
nothing is registered as ephemeral yet:

1. **IAM**: as above, `personal-lab-role` simply has no action that could
   delete the KMS key or state bucket. A future ephemeral combination's own
   role would get those actions, since destroying them is its actual job.
2. **Script-level allow-list**: `scripts/lib/ephemeral-confirm.sh`'s
   `EPHEMERAL_PROJECTS` (empty today) gates `bootstrap-down.sh`/
   `state-down.sh`'s non-interactive path. Not on the list -> the existing
   interactive prompt, unconditionally, exactly as before this ADR. On the
   list -> a `CONFIRM_DESTROY` env var, checked for an *exact* match against
   `PROJECT_NAME` (not "yes"/"y" - an unset or copy-pasted value then can't
   accidentally confirm the wrong project).

`lab-down.yml`'s `full-down` depth runs as its own job, gated by a GitHub
Environment (`ephemeral-teardown`) with required reviewers - GitHub's own
built-in mechanism for a genuinely separate confirmation step, a distinct
approval action after dispatch, auditable in the Actions UI. That approval is
the actual confirmation spec 001 requirement 8 asks for; `CONFIRM_DESTROY`
just verifies the approved run targets the project it claims to.

### `ROOT_DOMAIN` via GitHub secret, not KMS decrypt

`full-up` reaches `persistent-up` -> `require-unique-subdomain.sh`, which
previously always called `secret-decrypt.sh` (`aws kms decrypt`) for
`ROOT_DOMAIN`. Granting this role KMS decrypt would reverse ADR 0007
alternative (c)'s explicit rejection of exactly that, for exactly the same
reason: widening IAM scope to learn a non-secret hostname. Fixed instead:
`require-unique-subdomain.sh` now uses `$ROOT_DOMAIN` if already set in the
environment, decrypting only if not (`generate-secrets.sh` already had this
branch). `lab-up.yml` supplies it from a GitHub secret, matching the existing
delivery path for `AWS_ROLE_ARN`/`AWS_REGION` (constitution §19).
`route53:ListHostedZonesByName` and the S3 state read in that script are
unrelated to where `ROOT_DOMAIN` comes from and remain unchanged.

## Flagged, not resolved by this ADR

`terraform/live/persistent/vpc` already exists as a real, wired-in module,
even though CLAUDE.md and architecture.md describe VPC creation as deferred
to spec 021 ("the AWS account's default VPC is used until then"). Found
during this work's research; out of scope to reconcile here.

## Consequences

- Spec 016's scope amendment documents the dashboard/bounded-environment/
  depth-selector expansion past its original text (a personal-lab-role plus
  two thin-wrapper workflows).
- Registering a second combination (e.g. `vk-lab-ci`) later means: a second
  `type: choice` option in both workflows, that combination's own set of ARNs
  (including the destructive ones) in its own role's policy, and adding its
  `PROJECT_NAME` to `EPHEMERAL_PROJECTS` - three deliberate, reviewed changes,
  never one runtime input.
- `eks:AccessKubernetesApi` (whether `authentication_mode = "API"` needs it
  beyond the access-entry grant) and the pinned EKS module's
  `create_cloudwatch_log_group` default are both flagged in
  `personal-lab-role`'s policy as needing empirical verification against a
  real cluster, not encoded on a guess.
- `eks-access-identity`'s trust policy names whichever IAM identity ran
  `make account-up` at apply time (`data "aws_caller_identity"`, not a
  manually-supplied ARN) - always the operator, since that command never runs
  from CI. If the operator later authenticates differently (an IAM user
  switching to SSO, or vice versa; an SSO permission set being reprovisioned
  under a new name), the recorded principal goes stale: `kubectl` starts
  failing with `Unauthorized` even though the cluster's access entry is still
  correct. The failure mode doesn't point at the cause - it looks identical to
  a missing/deleted access entry - and the fix is re-running `make account-up`
  under the new identity, not touching the cluster.
- The operator's ARN is resolved via `data "aws_iam_session_context"`
  (`.issuer_arn`), not a hand-rolled regex on the caller-identity ARN - an
  earlier version stripped an SSO session ARN down to `role/<name>`, silently
  dropping the IAM path AWS Identity Center roles actually live under, which
  would have broken the workstation trust statement for any SSO-authenticated
  operator. Caught by a follow-up code review, not by the original empirical
  test (which only exercised a plain-IAM-user session).
- `personal-lab-role`'s policy also grants read access to its own IAM role
  ARN and to `eks-access-identity`'s (needed to plan/refresh itself, and for
  `terraform/modules/eks`'s data-source lookup / `argo-up.sh`'s `aws iam
  get-role` to succeed when run as this role from GitHub Actions), plus
  `iam:PassRole` and the EKS pod-identity-association actions (needed to
  create the cluster/node-group roles and every `*-pod-identity` module's
  association) - both gaps the original hand-enumerated policy missed.
- `github-oidc-trust` (`terraform/modules/github-oidc-trust`) factors out the
  GitHub-OIDC trust statement shared by `personal-lab-role` and
  `eks-access-identity`, merged into the latter's additional operator
  statement via `source_policy_documents` - avoids maintaining the same
  `aud`/`sub` condition block in two places.
- `persistent-down.sh` detects a non-interactive shell (`[ -t 0 ]`) and passes
  `--non-interactive -auto-approve` to terragrunt automatically - both flags,
  not just the first: `--non-interactive` alone still left Terraform's own
  "Do you want to perform these actions?" prompt in place (confirmed live,
  against `account-up.sh`'s equivalent single-unit `apply` calls, which had
  the same gap); `-auto-approve` is Terraform's own flag and the one that
  actually suppresses it. Unlike `bootstrap-down.sh`/`state-down.sh`,
  `persistent-down.sh` isn't gated by the ephemeral allow-list, since
  `down-through-persistent` is meant to run ungated for every registered
  combination; dispatching that workflow run is itself the confirmation step.

## Amendment: hand-enumeration replaced with broad Allow + explicit Deny

`personal-lab-role`'s permission policy was originally hand-enumerated
per-action, per the "Two roles" section above. Live use against a real
account surfaced one missing action per apply attempt in a row -
`iam:PassRole` and the EKS pod-identity-association actions, then
`ssm:GetParameter` (the EKS-optimized-AMI lookup), then `logs:DescribeLogGroups`
and a `iam:CreateRole` naming mismatch (the upstream module's default node-group
role name doesn't start with `cluster_name`, fixed via an explicit
`iam_role_name` override) - each only discoverable by actually running
`apply` against AWS, never by reading the Terraform config.

Replaced with: broad per-service `Allow` (`eks:*`, `ec2:*`, `acm:*`,
`secretsmanager:*`, `logs:*`, `s3:*` on this project's own state bucket,
`kms:*` scoped to the one secrets key) for every service where the
enumerated-action approach was the actual source of repeated live failures,
paired with explicit `Deny` statements covering exactly the actions that
would destroy Bootstrap/State (`s3:DeleteBucket` and bucket-reconfiguration
actions on the state bucket; `kms:ScheduleKeyDeletion`/`DisableKey`/
`DeleteImportedKeyMaterial` on the secrets key; `kms:DeleteAlias` globally).
An explicit Deny always overrides any Allow, so the "this role cannot
destroy Bootstrap/State" guarantee is now structurally stronger than before -
it no longer depends on nobody ever adding a missing action to a hand-written
list; it depends on nobody removing a Deny statement, a categorically
different (and more visible) kind of mistake.

**Kept narrow, deliberately not broadened:**
- **IAM** (`PlatformIamRoles`/`SelfAndAccessIdentityIamRolesReadOnly`) -
  broad `iam:*` would let this role modify its own permissions or create
  arbitrary roles/policies, a privilege-escalation surface distinct from the
  "missing a Describe action" problem the other services had.
- **Route53** - a service-level wildcard would grant `DeleteHostedZone` on
  *any* zone, including the parent/root zone, violating the constitution's
  hard invariant that this platform must never manage that zone. The
  read-any-zone / own-zone-only-write split stays exactly as originally
  designed.

## Alternatives considered

**a. Shared IAM role for both the operator and GitHub.** Rejected - see
Context §1. Only holds if every local invocation deliberately assumes the
shared role instead of the operator's default identity.

**b. Runtime IAM policy rewriting keyed off workflow input.** Rejected - see
Context §2. Requires `iam:PutRolePolicy` on self (privilege escalation), and
breaks the committed-policy-matches-live-policy property hand-enumeration
exists to provide.

**c. Capping the workflow's "full" teardown at `persistent-down` universally.**
Rejected - see Context §3. Blocks the legitimate future ephemeral-project case
along with the personal-lab case that should stay blocked.

**d. `echo y | make full-down` / piping a canned answer into the existing
interactive prompts.** Rejected - mechanically fragile (two different prompts
expect different tokens), and automates past a human-confirmation guard
rather than providing the confirmation it exists to require.

**e. Granting this role `kms:Decrypt` for `ROOT_DOMAIN`.** Rejected - reverses
ADR 0007 alternative (c) for the same reason it was rejected there.
