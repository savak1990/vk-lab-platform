# ADR 0045: The Ahorro pipeline deploys to its own two namespaces, with a token this repository republishes

## Status

Accepted

Amends one bullet of [ADR 0015](0015-business-app-gitops-topology.md): "CD
handoff is a git commit, not a live cluster call." It still holds for the
namespace Argo owns. It no longer holds for the two namespaces the
application's pipeline owns, which did not exist when 0015 was written. Every
other decision in 0015 stands, including the pointer topology
[ADR 0043](0043-the-first-business-application-pointer.md) implements.

Carries the application's own ADR 0009 (three environments, a semver per
component) and ADR 0010 (the pipeline deploys) into this repository.

## Context

ADR 0015 chose a commit as the handoff for a good reason, stated there: a push
and a commit both succeed against a destroyed cluster, and Argo catches up once
`make up` brings it back. Nothing about that has become wrong.

What changed is that the application now has three environments rather than
one. Its ADR 0009 splits them by owner: namespace `ahorro` holds a released
version and is driven by the pointer, exactly as 0015 and 0043 describe;
`ahorro-dev` tracks the application's `main`; and `ahorro-pr` holds one Helm
release per pull request carrying a label.

The two new ones cannot be driven by a commit. No `Application` watches them,
and creating one per pull request would need an `ApplicationSet` with a
pull-request generator, which wants a GitHub token living in the cluster. That
is a larger exception than this one, and ADR 0015's own ApplicationSet
reasoning argues against it for a single operator.

The split is also not a preference. Argo applies rendered manifests and creates
no Helm release, so Helm refuses to adopt objects Argo created and a shared
namespace fails with `invalid ownership metadata`. Separate namespaces are what
let the two owners coexist at all.

Only the credential stood in the way. The API server is already reachable from
a runner on every target: 6443 is open to `0.0.0.0/0` on civo and hetzner — by
a firewall comment that names GitHub Actions as the reason — and EKS sets
`endpoint_public_access = true`. But `ahorro-ci-role` held one permission,
`ssm:GetParameter` on `/account/root_domain`, and `lab-role`'s trust is scoped
to `repo:savak1990/vk-lab-platform:*`, which a token from the application's
repository never matches.

## Decision

### 1. A ServiceAccount that reaches two namespaces and not the third

`gitops/templates/platform/shared/rbac/ahorro-deploy.yaml` creates namespaces
`ahorro-dev` and `ahorro-pr` at wave 1, a `ahorro-deploy` ServiceAccount, and
one `Role` and `RoleBinding` per namespace at wave 2. It grants nothing in
namespace `ahorro`.

That boundary is RBAC, not convention. A fault in the pipeline — a wrong
version, a wrong namespace argument, a bad chart — cannot reach the released
environment, because the token it holds is not permitted there.

The namespaces are created here rather than left to `helm --create-namespace`
for the reason `Namespace/ahorro` already is: a `RoleBinding` whose namespace
does not exist fails the apply, and `SkipDryRunOnMissingResource` covers the
dry run only.

Two `Role` objects rather than one `ClusterRole` bound twice, so this grant can
never be bound into namespace `ahorro` by a later edit. The verbs are what Helm
needs and no wildcard: the application's charts render four kinds, Secrets
carry Helm's own release history, and Pods and ReplicaSets are what `--wait`
polls. One small `ClusterRole` grants `get` and `list` on namespaces, which is
what makes a `helm` failure report a clear error rather than a permission
denial.

### 2. The credential is republished on every bring-up

`scripts/lib/ahorro-deploy.sh` mints a token for that ServiceAccount, reads the
API endpoint and the certificate authority from the admin kubeconfig, and
writes three parameters under `/<project>/cluster/ahorro-deploy/`. The token is
a `SecureString`; the other two are plain.

Republishing is the whole point. The cluster is disposable, so every `make up`
mints a new certificate authority and new tokens. A kubeconfig stored in a
GitHub secret would break at the first rebuild and stay broken, with a failed
deployment as the only signal. SSM is the one store both sides already reach,
and `ahorro-ci-role` gains `ssm:GetParameter` on that prefix and on the four
Cognito identifiers the client needs.

A token request, not a `kubernetes.io/service-account-token` Secret. The Secret
never expires, which is attractive, but the token controller writes into an
object Argo would then manage, and an object Argo diffs against a manifest that
no longer matches is the defect that wedged the local target once already. The
requested duration is longer than any lab cluster lives; the API server caps it
at its own maximum, so the script echoes what it asked for rather than claiming
what it got.

### 3. Called from both arms of `argo-up.sh`

`argo-up.sh` has a fast path: when the root `Application` is already
`Synced/Healthy` on a cloud target, it confirms DNS and exits, roughly four
hundred lines before the end of the script. A publish appended at the bottom
would be skipped on every re-run.

In the steady state that is harmless, because the value has not changed. The
case it is not harmless in is the one that matters: a run that synced but died
before publishing, or a parameter someone deleted. The next run takes the fast
path, skips the publish, and the parameter stays missing behind a cluster that
looks healthy. So the call sits in both arms.

The write is guarded, in the shape `export_tls_secret` uses rather than
`backup_publish_server_name`'s. Under `set -euo pipefail` an unguarded
`put-parameter` turns a transient SSM failure into a failed bring-up, and a
deploy credential is not worth failing a platform for — the next `argo-up`
republishes.

## Consequences

`make account-up` must be re-run once from a workstation for the new IAM
statements to exist. It is deliberately in no composite target, so nothing else
will apply them.

The application's pointer now sets `selfHeal: true`, which
[ADR 0043](0043-the-first-business-application-pointer.md) recorded as `false`
and as the application's call. It still is: hand installs moved to
`ahorro-dev`, so drift in namespace `ahorro` is now always a mistake. Drift
there is corrected within about three minutes, and `kubectl edit` in that
namespace no longer sticks.

A deploy attempted while the cluster is down fails at the kubeconfig rather
than succeeding as a commit would. That is correct, and it is louder than what
ADR 0015 chose. The reason 0015 gave still protects namespace `ahorro`, which
a commit continues to drive.

Two latent defects were found in the code this change sits beside, and neither
is fixed here. `backup_publish_server_name` is on the far side of the same fast
path, so its SSM write is skipped on every fast-path re-run; and its
`put-parameter` is unguarded, so a transient failure fails the bring-up at the
last line. Both are one-line fixes that do not belong in a credential change.

Separately, only the `kind-integration` job pins the application's revision to
a SHA. The civo, hetzner and aws lifecycle jobs resolve `main` at sync time, so
the mid-run-merge hazard that pin exists to prevent still applies to them.

Eight objects join the structural object set on every target, and the aws
golden render gains them and the `selfHeal` flip.
