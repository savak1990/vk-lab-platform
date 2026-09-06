# ADR 0024: Hardcode `eu-west-1` as the platform's single AWS region

## Status

Accepted

## Context

The platform carries a two-axis region model. `ACCOUNT_MAIN_REGION` is where the
account layer applies — the shared secrets KMS key `alias/lab-secrets`, `lab-role`,
the GitHub OIDC provider, and `root-domain`. `PROJECT_REGION` is where a given
project's own units apply — its state bucket, Route 53 zone, ACM certificate, EKS
cluster, and NLB. The two are independent env-var-driven values, threaded through
`terraform/live/root.hcl`, `scripts/lib/region.sh`, the `Makefile`,
`.github/workflows/lab.yml`, and `gitops/`.

Both have always defaulted to `eu-west-1`. Nothing has ever run against anything
else.

Three things make maintaining that configurability the wrong call.

**It does not work.** ADR 0023 records a *Known limitation, deferred*: the two
ESO-consumed passwords are `SecureString` parameters written in `PROJECT_REGION`
but encrypted with `alias/lab-secrets`, which exists only in
`ACCOUNT_MAIN_REGION`. AWS requires an SSM `SecureString`'s KMS key to live in the
same region as the parameter, so `persistent-up` fails on those two creates:

```
InvalidKeyId: The security token included in the request is invalid.
(the KMS key alias/lab-secrets does not exist in this region)
```

Region portability has therefore never been exercisable end to end, only
partially wired.

**It was already decaying.** ADR 0023 also describes `scripts/lib/region.sh`
discovering `ACCOUNT_MAIN_REGION` by reading `/account/main_account_region` from
SSM, falling back to the env var on `ParameterNotFound` and aborting loudly on any
other AWS error. That mechanism no longer exists — `scripts/lib/region.sh` states
the opposite, that neither region self-discovers and both are plain env-var
defaults. It was reverted without the ADR being updated, and
`aws_ssm_parameter.main_account_region` has had zero readers since. The
configurability was not being maintained; it was rotting quietly behind
documentation that claimed otherwise.

The circularity that killed the mechanism is worth preserving as a finding rather
than as code: a parameter recording a region necessarily lives *in* that region, so
querying it at a guessed region returns `ParameterNotFound` — indistinguishable
from "not written yet," which silently confirms a wrong guess instead of catching
it. ADR 0023 reached that conclusion for `PROJECT_REGION` and applied it to
`ACCOUNT_MAIN_REGION` too, just without saying so.

**The platform is heading off AWS.** Spec 027 explores alternative cloud targets.
Paying ongoing complexity for a second *AWS* region, in a disposable educational
lab whose stated direction is away from AWS entirely, is the wrong investment.

This ADR is also the §13.2/§13.3 record of a direct conflict with the
constitution. §19 requires a fork to run with zero source-code changes and contains
an explicit MUST against hardcoding an AWS region; `docs/architecture.md` §24a and
invariant 23 repeat it. The constitution and architecture edits land alongside this
ADR, before implementation, per §13.4.

## Decision

**One region, `eu-west-1`, for every layer and every lifecycle class.** The
account/project region distinction is deleted. The account layer and every
project's layers apply in the same region.

**One constant per layer, never derived.** No cross-language constant is possible
without generating one file from another, which is more machinery than this repo
warrants. Five declarations is the floor:

| Layer | Constant | File |
|---|---|---|
| Terragrunt | `locals.aws_region` | `terraform/live/root.hcl` |
| Shell | `LAB_REGION` | `scripts/lib/region.sh` |
| GitOps | `region` | `gitops/values.yaml` |
| Make | `REGION` | `Makefile` |
| CI | literal | `.github/workflows/lab.yml` |

The property this preserves is not "one line in the repository" — it is **no
derived declaration**. A sixth site that recomputes the region is prohibited: no
`get_env` default, no `?=`, no workflow input, no reliance on ambient
`AWS_REGION`/`AWS_DEFAULT_REGION` or an operator's AWS profile.

**The shell constant is `LAB_REGION`, unexported.** Naming it `AWS_REGION` and
exporting it would satisfy the letter of the rule while restoring exactly the
ambient CLI resolution being removed, and would collide with an operator's
`AWS_PROFILE` default. `scripts/lib/region.sh` survives as a one-variable file so
its 16 sourcing scripts keep a single chokepoint instead of ~30 inlined literals.
The old names both implied a scope that no longer varies.

**Terraform modules never write the literal.** Where a module needs the region it
reads `data "aws_region" "current"`, which resolves from the single generated
provider block in `root.hcl` and therefore from that layer's one constant.

**GitOps keeps one Helm value; the pipe is cut.** The AWS Load Balancer Controller
and the ExternalSecrets `ClusterSecretStore` genuinely need a region string in
their config, so `gitops/values.yaml` keeps `region`. What goes is the chain that
made it configurable: `scripts/argo-up.sh`'s `--set region=`,
`gitops/bootstrap/values.yaml`'s copy, and the `region` Helm parameter in
`gitops/bootstrap/templates/root-application.yaml`. Verified: the child chart
renders byte-identical before and after, because the parameter was only overriding
`values.yaml` with the same value.

**The `region` workflow input is deleted outright**, not narrowed. A one-option
`type: choice` still presents region as an operator knob; GitHub offers no
read-only input. `aws-region: eu-west-1` is written literally at both
`configure-aws-credentials` steps — that action requires a region and CI runners
have no `~/.aws/config` to fall back on.

**Deleted:** `aws_ssm_parameter.main_account_region` (`/account/main_account_region`)
and its module variable; the `account_main_region`/`main_account_region` variables
in `terraform/modules/route53-zone`, `terraform/modules/external-secrets-pod-identity`,
and `terraform/modules/root-domain`; the explicit `region =` arguments on the
cross-region SSM and KMS-alias data sources in the first two; the `region`
workflow_dispatch input and its `PROJECT_REGION` job env entry.

**Supersedes** the region half of ADR 0007's fork-configurability section and ADR
0022's restatement of it: `AWS_ROLE_ARN` remains a GitHub repository variable,
`AWS_REGION` is no longer one. That variable was in any case already dead —
`.github/workflows/lab.yml` never read `vars.AWS_REGION`, and
`scripts/account-up.sh` sets only `AWS_ROLE_ARN`.

**`lab-role`'s region wildcards stay.** Narrowing `arn:aws:eks:*` and
`arn:aws:ssm:*` to `eu-west-1` was considered and rejected — see Consequences.

## Consequences

- Forking is zero-source-change **within `eu-west-1`**. A fork owner in another
  region edits five constants. This is a real reduction in fork-configurability,
  not a footnote, and constitution §19 is amended to say so rather than to be
  quietly worked around.
- **ADR 0023's "Known limitation, deferred" is closed by policy, not by fix.** The
  `SecureString`/KMS co-region failure cannot occur once both axes are the same
  value. It is not solved — if region portability is ever revived it returns
  unchanged. Spec 031 adopts it so the deferral keeps an owner.
- ADR 0023's description of SSM-based region self-discovery is corrected to record
  that the mechanism was reverted before this change, and the parameter it wrote is
  now deleted. Leaving that stale is how the drift this ADR responds to happened.
- `/account/main_account_region` is removed. **Verified:** zero code readers
  repo-wide at the time of this decision, including by-path reads — the string
  survives only as an IAM action grant in `terraform/modules/lab-role`.
  **Expected, pending a credentialed run:** the next `make account-up` plans
  exactly one destroy, needing no `terraform state rm` and no targeted destroy.
  `make account-down` must not be used for it — it would also destroy the shared
  KMS key, `lab-role`, both access identities and the OIDC provider.
- Remote-state identity was **verified** credential-free: `terragrunt render`
  on the account, account-state, state, persistent and cluster units returns the
  same bucket, key and region as before the change, and the account-vs-project
  bucket split is intact.
- Remote state does not move. The region *value* is unchanged at every layer, so
  the generated backend configuration is byte-identical and no state is orphaned.
- **`lab-role` IAM narrowing was considered and rejected.** It is safe — every
  region-less AWS call this platform makes (`iam`, `sts`, `route53`) uses a global
  endpoint and is unaffected — but it buys nothing: `ec2:*`, `logs:*`, `acm:*` and
  `secretsmanager:GetRandomPassword` are granted on `Resource "*"`, so narrowing
  three ARN sets gives no regional containment while being the only change able to
  lock CI out of the entire platform. The wildcards and their in-code rationale
  stay accurate.
- **Do not "fix" that by adding a region Deny.** Real containment would need an
  account-wide `Deny` on `StringNotEquals aws:RequestedRegion eu-west-1`. That
  condition key is absent from requests to global services, so such a Deny fires on
  IAM, STS and Route 53 and bricks the role.
- `configure-aws-credentials` exports `AWS_REGION`/`AWS_DEFAULT_REGION` into the CI
  job. "No ambient region" is therefore true on a workstation and false in CI. This
  is harmless after this change — every consumer takes its region from an explicit
  constant — but the claim should not be overstated.
- `tests/manual/016-lab-up-down.md`'s region-portability phase is deleted; it tested
  the capability this ADR removes and could no longer pass.
- Constitution §5's "the OIDC provider is account-level and region-agnostic" and
  §14's "the ACM certificate MUST be created in the same AWS region as the NLB" are
  unchanged and still correct. §14's "unless a later ADR changes this decision" is
  not exercised here.
- **Known limitation, deferred:** running a disposable cluster in a region other
  than the account's is now unsupported by design. Spec 031 records the concrete
  blockers — the single-region KMS key, the per-region ACM certificate, the
  retained-EBS availability-zone pin, and the deleted cross-region lookups — so the
  work is designed and costed rather than merely lost.
