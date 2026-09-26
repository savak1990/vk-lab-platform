---
id: "AWS-036"
status: "IN_PROGRESS"
updated: "2026-09-26"
---
# 036 — The Ahorro pointer Application

**Status note:** Implemented; becomes DONE once a bring-up shows the
application Synced and Healthy against a real cluster.

**Complexity:** Small
**Risk:** Medium — a broken pointer wedges the `root` Application until its retry budget runs out, roughly sixteen minutes.
**Estimated cost:** ~0.5 day · AWS runtime cost: none. The objects are Disposable and live in the cluster `make up` already pays for.
**Recommended model:** Sonnet.
**Depends on:** 004-argocd-bootstrap, 035-ahorro-cognito, ADR 0015, ADR 0042, ADR 0043.
**Lifecycle class(es) touched:** Disposable.

## Scope

The two files ADR 0015 reserves for a business application, and the carrying
step spec 035 excluded: the Ahorro `AppProject` and pointer `Application`
under `gitops/templates/apps/vk-ahorro/`, plus the three Cognito identifiers
travelling from SSM to the pointer's Helm parameters.

Excludes: everything below the pointer, which is the `vk-ahorro` repository's
own spec 060; the pool itself (035); local target support, which is that
repository's spec 107.

## Requirements

1. `gitops/templates/apps/vk-ahorro/appproject.yaml` MUST render an
   `AppProject vk-ahorro` at sync-wave `4`, with `sourceRepos` naming the
   application repository and `ghcr.io/savak1990/vk-ahorro/charts`,
   destinations for namespaces `ahorro` and `argocd`, and
   `clusterResourceWhitelist` of `{group: "", kind: Namespace}` so the
   children's `CreateNamespace=true` works.
2. `gitops/templates/apps/vk-ahorro/application.yaml` MUST render an
   `Application vk-ahorro` at sync-wave `5`, `project: vk-ahorro`, source
   `repoURL` the application repository with `path: gitops` and
   `targetRevision: main`, destination namespace `argocd`,
   `automated {prune: true, selfHeal: false}`, the
   `resources-finalizer.argocd.argoproj.io` finalizer, and
   `syncOptions [ServerSideApply=true]`.
3. The project MUST be created before the pointer. An `Application` naming a
   project that does not exist is rejected outright rather than retried, so
   wave 4 before wave 5 is correctness, not neatness.
4. `/${PROJECT_NAME}/persistent/ahorro-cognito/{user_pool_id,client_id,issuer}`
   MUST travel the route `fqdn` already travels: `scripts/argo-up.sh`, `--set`
   onto `gitops/bootstrap`, `helm.parameters` on the root `Application`,
   defaults in both `gitops/values.yaml` files, and finally the pointer's own
   parameters. They MUST NOT be delivered by an `ExternalSecret`: they are
   public identifiers and that path would store public data as secret data
   (ADR 0042).
5. No region MUST be threaded. The issuer contains it, and
   `gitops/values.yaml` already carries `region: eu-west-1` as a fixed value.
6. `aws_resolve_inputs` goes from six SSM names to nine, against a
   `get-parameters` cap of ten. Its comments MUST be corrected, and the
   remaining headroom MUST be stated, so the next addition does not discover
   the cap by silent truncation.
7. No new `case "$PROVIDER"` block MUST be added to `scripts/argo-up.sh`.
   `tests/scripts/argo-up-dispatch-test.sh` requires every such block to name
   all four providers; extending the existing arrays avoids the question.
   `civo_resolve_inputs` keeps its own arrays, so it takes three `case` arms
   rather than the shared helper the other two resolvers call.
8. Both objects MUST be gated `{{- if ne .Values.target "local" }}`.
   `local_resolve_inputs` reaches no cloud API and has no source for the
   identifiers.
9. Both objects MUST be named explicitly in
   `scripts/gitops-render-check.sh`: required on civo and hetzner, forbidden
   on local. A new `Application` is otherwise neither required nor forbidden
   there, so the check passes silently whichever way it renders.
10. `tests/golden/gitops-aws/` MUST be regenerated. The two objects appear in
    the three `platform*` directories, and the root Application's three new
    parameters in `bootstrap/`.

## Implementation hints

- This is the repository's first `AppProject`. Everything else is
  `project: default`, which ADR 0015 says is acceptable only while the tree
  under `root` is platform-only.
- `root` renders everything under `gitops/templates/`, so a new `apps/`
  directory needs no change to `gitops/bootstrap`.
- `bash -n` will not catch a missing line continuation in a `--set` chain: the
  result is valid shell that runs `--set` as its own command. Read the diff.

## Testing / acceptance criteria

- `make gitops-check` passes, with the aws render matching the regenerated
  baseline and the civo, hetzner and local object sets unchanged otherwise.
- `make scripts-check` passes, including shellcheck over `argo-up.sh` and
  every `tests/scripts/*-test.sh`.
- `make argo-up-dispatch-check` reports four dispatch blocks and no missing
  arm.
- `make specs-check` passes.
- After a bring-up: `argocd app get vk-ahorro` is Synced and Healthy,
  `argocd app list` shows the application's two children in project
  `vk-ahorro`, and `kubectl -n ahorro get pods` shows both Running.
- `helm template gitops --set target=local` renders neither object.
