---
id: "SHARED-049"
title: "A scoped deploy credential for the Ahorro pipeline, republished to SSM on every bring-up"
status: "IN_PROGRESS"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strong"
model_rationale: "An IAM grant and a cluster credential: the blast radius is the whole lab if the RBAC or the ARN pattern is wrong, and the fast-path call site is easy to get subtly wrong"
effort_estimate: "One session (3-4 h) plus a civo cycle"
estimate_confidence: "medium"
depends_on: ["SHARED-023"]
blocked_by: []
supersedes: []
created: "2026-10-06"
updated: "2026-10-06"
---

# SHARED-049 — The Ahorro deploy credential

## 1. Outcome and rationale

The Ahorro application's pipeline can `helm upgrade` into namespaces
`ahorro-dev` and `ahorro-pr`, and cannot touch namespace `ahorro`. It obtains
that access by assuming `ahorro-ci-role` and reading three SSM parameters this
repository writes during every bring-up.

Recorded in
[ADR 0045](../../../docs/adr/0045-the-ahorro-pipeline-deploys-to-its-own-namespaces.md),
which amends one bullet of ADR 0015. The application's side is its own ADR
0009 and ADR 0010, and its specs `deploy/060` and `deploy/070`.

## 2. The problem

The application has three environments. Namespace `ahorro` holds a released
version and is driven by the pointer, as ADR 0015 and ADR 0043 describe.
`ahorro-dev` tracks the application's `main`; `ahorro-pr` holds one Helm
release per labeled pull request.

Neither of the last two can be driven by a commit. No `Application` watches
them, and one per pull request would need an `ApplicationSet` with a
pull-request generator and a GitHub token living in the cluster.

They also cannot share namespace `ahorro`. Argo applies rendered manifests and
creates no Helm release, so Helm refuses to adopt objects Argo created and a
shared namespace fails with `invalid ownership metadata`.

Only the credential is missing. The API server is already reachable from a
runner on every target. `ahorro-ci-role` holds one `ssm:GetParameter`, and
`lab-role`'s trust is scoped to this repository, which the application's token
never matches.

## 3. Scope and non-goals

In scope: the ServiceAccount and its RBAC, the two namespaces, the SSM
publication, the IAM grants, and the pointer's `selfHeal`.

**Non-goals.** The pipeline itself, which is the application repository's
`deploy/060` and `deploy/070`. Any grant in namespace `ahorro`. An
`ApplicationSet` pull-request generator. Fixing the two latent defects ADR 0045
records beside this work — `backup_publish_server_name`'s fast-path skip and
its unguarded write — which are one-line changes that do not belong in a
credential change. Pinning the application's revision in the cloud lifecycle
jobs, which only `kind-integration` does today.

## 4. Requirements

1. `gitops/templates/platform/shared/rbac/ahorro-deploy.yaml` MUST create namespaces `ahorro-dev` and `ahorro-pr` at sync-wave 1, a `ahorro-deploy` ServiceAccount, and one `Role` and `RoleBinding` per namespace at wave 2. The namespaces are created here, not by `helm --create-namespace`, because a `RoleBinding` whose namespace is missing fails the apply and `SkipDryRunOnMissingResource` covers the dry run only.
2. The grant MUST be two `Role` objects, never one `ClusterRole` bound twice, so it cannot be bound into namespace `ahorro` by a later edit. It MUST NOT use a wildcard verb or resource. It MUST grant nothing in namespace `ahorro`.
3. The ServiceAccount MUST be able to `get` and `list` namespaces cluster-wide, so a `helm` failure reports a clear error rather than a permission denial. That is the only cluster-scoped grant.
4. `scripts/lib/ahorro-deploy.sh` MUST mint a token for that ServiceAccount, read the API endpoint and certificate authority from the admin kubeconfig, and write `/<project>/cluster/ahorro-deploy/{token,ca,endpoint}`. The token MUST be a `SecureString`; the other two are plain strings. The token MUST be masked when `GITHUB_ACTIONS` is set.
4a. It MUST also write `/<project>/cluster/ahorro-deploy/fqdn`, as a plain string, from the `LAB_FQDN` the script already resolved. The pipeline builds its own hostnames and cannot read `/<project>/bootstrap/route53/fqdn` or the `subdomain` it is composed from, so it has nothing to compose from. Copying it under this prefix costs no new IAM, because requirement 10's grant is a wildcard over the whole prefix. The value MUST NOT be echoed, here or anywhere (ADR 0023).
5. A token request MUST be used, not a `kubernetes.io/service-account-token` Secret. The Secret never expires, but the token controller writes into an object Argo would manage, and an object Argo diffs against a manifest that no longer matches is what wedged the local target once already.
6. The requested duration MUST exceed any lab cluster's life. The API server caps it at its own maximum, so the script MUST echo what it requested rather than claim what it was granted.
7. `argo-up.sh` MUST call the publication from **both** arms — the fast path at the idempotency guard, and the end of the script. The fast path exits roughly four hundred lines early, so a run that synced but died before publishing would otherwise leave the parameters missing behind a healthy-looking cluster.
8. The `put-parameter` MUST be guarded in the shape `export_tls_secret` uses. Under `set -euo pipefail` an unguarded write turns a transient SSM failure into a failed bring-up, and the next `argo-up` republishes anyway. The call site MUST NOT fail the bring-up.
9. Publication MUST be skipped on the local target, which no pipeline deploys to.
9a. `argo-down.sh` MUST delete all four parameters after the Argo cascade. A credential that outlives its cluster is worse than a missing one: the pipeline builds a kubeconfig that looks valid and then waits out a TCP timeout against an endpoint nobody answers, which reads as a pipeline bug. Absent fails in a second and names the cause. The delete MUST be guarded and MUST NOT fail the teardown.
10. `ahorro-ci-role` MUST gain read on `/*/cluster/ahorro-deploy/*` and on the four Cognito identifiers the client needs. It MUST NOT be granted the enclosing Cognito prefix, which also holds `test_user_password`.
10a. It MUST also gain `kms:Decrypt` on the `alias/lab-secrets` key. The token is a `SecureString`, so the parameter grant alone is not enough and the read fails as `AccessDenied` - verified with `simulate-principal-policy`, which returned `implicitDeny`. The grant MUST name the key's **underlying ARN**: an alias ARN in a resource element grants nothing. It MUST carry a `kms:EncryptionContext:PARAMETER_ARN` condition scoping it to the token parameter alone, because the same key encrypts other projects' secrets and this project's `test_user_password`. `StringLike`, not `StringEquals`, because the project segment is a wildcard.
11. The pointer MUST set `selfHeal: true`, by the application's own ADR 0009. ADR 0043 recorded `false` and recorded that the choice is the application's.
12. The eight new objects MUST join `REQUIRED_OBJECTS` in `scripts/gitops-render-check.sh`, and the aws golden MUST be regenerated in the same commit.

## 5. Implementation hints

`terraform/modules/external-secrets-pod-identity/main.tf` already pairs
`kms:Decrypt` with an `EncryptionContext` condition; copy that shape.
`terraform/modules/lab-role/main.tf` carries the note about alias ARNs.

The admin kubeconfig is already current when `argo-up.sh` runs, so
`kubectl config current-context` is enough — no provider branch is needed to
find the cluster entry.

`configure_test_kubeconfig` in `scripts/lib/provider.sh` is the existing
`kubectl create token` call to copy. It takes the cluster entry from the admin
context rather than rebuilding it; this script needs the server and CA
explicitly, because the consumer has no kubeconfig to start from.

`make account-up` is the only thing that applies `terraform/live/account/`,
and it is deliberately in no composite target. The IAM statements do not
exist until it is re-run from a workstation.

## 6. Testing / acceptance criteria

1. `./scripts/gitops-render-check.sh` green for civo, hetzner, local and the aws golden.
2. `make scripts-check` green, including shellcheck over the new library.
3. `terraform validate` and `terraform fmt -check` green for the module.
4. On a live cluster, `aws ssm get-parameters` returns all four parameters, and a kubeconfig built from them runs `helm -n ahorro-dev list` successfully.
5. That same kubeconfig is **refused** by `kubectl -n ahorro get deploy`. *(Verified 2026-10-07 on the hetzner lab, against a token minted for the ServiceAccount: `helm -n ahorro-dev list` succeeded and `kubectl -n ahorro get deploy` returned `Forbidden`, naming `system:serviceaccount:ahorro-dev:ahorro-deploy`. Twenty-four `kubectl auth can-i` probes also behaved as designed, including refusal on `argocd`, `kube-system`, `envoy`, nodes, ClusterRoleBindings and namespace deletion.)*
5a. After `make down`, none of the four parameters exists, so a pipeline run reports the cluster gone rather than timing out.
6. `make argo-up` twice: the second run takes the fast path and the parameters are still refreshed.
7. Deleting the token parameter and re-running `make argo-up` on an already-healthy cluster restores it — the case requirement 7 exists for.
8. `make down` then `make up`: the parameters carry a new token and the pipeline still deploys.

## 7. Status history

- 2026-10-06 — created, IN_PROGRESS.
