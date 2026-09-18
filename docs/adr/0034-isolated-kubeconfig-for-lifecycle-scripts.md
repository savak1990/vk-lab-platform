# ADR 0034: Lifecycle scripts run against an isolated kubeconfig

## Status

Accepted.

## Context

Every lifecycle script repointed the operator's own kubectl at the lab
cluster. `configure_kubeconfig()` wrote `~/.kube/config` and ran
`kubectl config use-context`, and five call sites reached it with no
kubeconfig path: `argo-up.sh` (both provider branches), `argo-down.sh`,
`cluster-down.sh`, and the `kubeconfig` Make target.
`configure_test_kubeconfig()` did the same for `make test`.

So `make full-up`, `make down` and `make test` all took the current context
away from whatever the operator was working on. Someone running a lab
bring-up in one shell could not keep working against minikube in another.
The `test-kubeconfig` doc comment even instructed the reader to run
`make kubeconfig` afterwards to switch back.

Two isolated call sites already existed for exactly this reason:
`scripts/clusters.sh` and `scripts/status.sh` pass a temporary kubeconfig
path into `argo_state()`, because walking N clusters would otherwise
repoint the operator's kubectl N times. Constitution §17 already required
`make clusters` not to modify the operator's kubeconfig.

Two options were considered.

**Per-command `--context`.** Rejected. It cannot reach the goal, for two
reasons. First, `aws eks update-kubeconfig` has no opt-out from switching:

> When update-kubeconfig writes a configuration to a kubeconfig file, the
> current-context of the kubeconfig file is set to that configuration.

A script must run that command to create the context at all, so the
operator's current context still moves. The only escape the AWS CLI offers
is `--kubeconfig <other file>`. Second, it would miss `helm`, which takes
`--kube-context`, not `--context`; four cluster-touching helm calls exist in
`argo-up.sh` and `argo-down.sh`. It also scales badly — about 80 `kubectl`
call sites — and a call site added later is silently unprotected.

**A separate kubeconfig file, selected through `KUBECONFIG`.** Accepted.
One exported variable per script process covers `kubectl`, `helm`,
`aws eks update-kubeconfig`, the `civo` CLI and the Go E2E suite together.

## Decision

Lifecycle scripts write the lab cluster into a repo-local kubeconfig,
`.kube/<project-name>.config`, and export `KUBECONFIG` to point at it.
`~/.kube/config` is never opened.

`make kubeconfig` and `make test-kubeconfig` are the only two targets that
write the operator's kubeconfig or change their current context. Both exist
for that purpose and are invoked by a human on purpose.

`scripts/lib/provider.sh` gains two functions:

- `use_isolated_kubeconfig [path]` — resolves the path (default
  `.kube/${PROJECT_NAME}.config`, relative paths against the repo root),
  creates the parent directory, exports `KUBECONFIG`, and records the same
  value in `LAB_KUBECONFIG`. That marker is deliberately *not* exported: an
  inherited one would let the guard pass in a shell that never called the
  setup function.
- `require_isolated_kubeconfig` — fails when `KUBECONFIG` is not
  `LAB_KUBECONFIG`. It guards the entry points only —  `backup_teardown`,
  `civo_export_tls_secret`, `civo_import_tls_secret`. The status helpers
  those reach (`backup_archiving_status`, `backup_archiving_since`,
  `backup_teardown_warn`) stay unguarded on purpose: their callers are
  written against a "never fails, may return empty" contract that a guard's
  non-zero return would break.

The guard inverts a failure mode that this change creates. Before it, a
bare `kubectl delete` was safe because the script had just switched the
current context to the lab. After it, the same command follows `KUBECONFIG`
— and a script that forgets to set it would delete from whatever cluster
the operator has selected. The guard turns that into an immediate error. A
non-empty check would not do: operators export `KUBECONFIG` for their own
sessions, so the guard compares the two values.

`use_isolated_kubeconfig` deliberately does nothing at source time.
`make kubeconfig` sources the same library and must still write the default
file.

`make test` no longer depends on `test-kubeconfig`. It builds the same
read-only identity into `.kube/<project-name>-test.config` through a new
internal target, and passes that path to `go test`. One file per identity,
so the read-only context never overwrites the cluster-admin one. The path
is passed explicitly on each recipe line rather than exported, because an
export made in one Make recipe line's shell never reaches the next line.

## Consequences

- A bring-up, a teardown and a test run leave the operator's kubectl alone.
  Parallel work against another cluster is possible.
- Debugging the lab without switching context:
  `KUBECONFIG=.kube/<project-name>.config kubectl get pods`.
- The `aws eks update-kubeconfig` merge semantics apply to the isolated file
  too, so stale contexts accumulate there across cluster recreations.
  Harmless; the file is gitignored and disposable.
- The reachability gates in `argo-down.sh` and `cluster-down.sh` now fail
  with a connection error rather than a missing-resource error when the
  isolated file is empty. Both gates sit behind `cluster_exists()`, which
  asks the provider API, so the no-cluster path never reaches kubectl.
- The `kubeconfig` and `test-kubeconfig` targets lost their `PROVIDER`
  `ifeq` split: both branches became identical once the AWS recipes moved
  into `provider.sh`, which dispatches on `PROVIDER` internally. This
  removes the second, invisible way to write the default kubeconfig, so the
  invariant is now greppable — exactly two call sites pass no path.
- Runbooks under `tests/manual/` use unqualified `kubectl`. They now assume
  the reader ran `make kubeconfig` first.
- `configure_kubeconfig` and `configure_test_kubeconfig` now abort when the
  cluster fetch fails, instead of falling through to
  `kubectl config set-context --current`. That trailing call would otherwise
  set `namespace=default` on whatever context the caller's kubeconfig
  happened to hold — the operator's own, for `make kubeconfig`.
- The `REGION` Make variable had no remaining reference once the inline aws
  kubeconfig recipes moved into `provider.sh`, and was removed. The region
  still comes from `scripts/lib/region.sh` for scripts and `root.hcl` for
  terragrunt, exactly as its comment described.
