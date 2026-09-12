---
id: "LOCAL-010"
title: "PROVIDER=local: Make dispatch, context guard, script branches, secrets from KMS"
status: "READY"
priority: "P0"
milestone: "M0"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Touches every lifecycle script; each non-civo branch silently assumes AWS and must be found, not guessed"
effort_estimate: "One to two sessions (6–10 h) including repeated up/down cycles on a laptop"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: ["spec 022 Req 5, Req 11, Req 12, Req 15"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-010 — `PROVIDER=local`: Make dispatch, context guard, script branches, secrets from KMS

## 1. Outcome and rationale

`PROVIDER=local make up` on a workstation whose current kubectl context is
a local cluster (minikube, kind, k3d, Docker Desktop) installs Argo CD,
creates the two workload Secrets from KMS-decrypted ciphertext, and installs
the root Application with `target=local`. `PROVIDER=local make down` removes
the root Application cascade and the Secrets and leaves the cluster. The
platform does not create, configure, or delete the cluster: the developer
brings one. Every lifecycle target exists for local; those with no local
meaning print one line and exit 0. `full-up`/`full-down` therefore work
and collapse to `up`/`down`. AWS and Civo behaviour is unchanged.

This spec lands before the gitops contract is inverted (LOCAL-030), so at
its end the root Application syncs today's almost-empty `target=local`
render. That is enough to prove the command surface.

## 2. Scope and non-goals

In scope:
- `PROVIDER` allowlist and defaults in `Makefile` and `scripts/lib/provider.sh`;
  `PROJECT_NAME=vk-local-lab`; no `SUBDOMAIN`.
- No-op `state-*`, `bootstrap-*`, `persistent-*`, `cluster-down` (one line,
  exit 0).
- `cluster-up` = context guard only: the current kubectl context must
  match a local pattern and the API server must answer; otherwise exit 1
  with the offending context name. No cluster is created.
- `kubeconfig` / `test-kubeconfig`: no-op (the developer's context is used
  as is).
- `require-persistent.sh` local bypass.
- `status`: current context, Argo root health, `local-retain` PVC list.
- `argo-up.sh` local branch: inputs, namespaces + Secrets, Argo install
  without spot anti-affinity, root Application with `--set target=local`,
  readiness on root health only (HTTP readiness arrives with LOCAL-050).
- `argo-down.sh` local branch: `cluster_exists` = context guard; skip the
  CNPG snapshot backup and the Route 53 wait; run the cascade; delete the
  two `managed-by=argo-up` Secrets.
- `cluster-down.sh` local branch: print "cluster is developer-owned;
  nothing to do".
- `secrets/vk-local-lab/` with three files byte-copied from
  `secrets/vk-lab-platform/`.

Not in scope:
- Creating a cluster (never, on any spec). CI creates its own (LOCAL-090).
- Any gitops template change (LOCAL-030 onwards).
- HTTP readiness and port-forward helper (LOCAL-050).
- `make test` (LOCAL-080).

## 3. Current state / evidence

- `Makefile:10-12` errors on any `PROVIDER` other than `aws`/`civo`;
  `scripts/lib/provider.sh:8-10` mirrors it; `Makefile:17-23` binary
  `PROJECT_NAME`/`SUBDOMAIN` defaults.
- `scripts/lib/provider.sh:61-95`: `cluster_exists` and
  `configure_kubeconfig` fall through to `aws eks`.
- `scripts/argo-up.sh`: `aws_resolve_inputs` (`:131-135`),
  `aws_resolve_snapshot` (`:330-334`, aborts on failure),
  `install_argocd` anti-affinity guard (`:338`),
  `aws_install_root_application` (`:427-431`), `aws_wait_for_dns`
  (`:511-517`) all run for any non-civo provider.
- `scripts/argo-up.sh:217-230` `ensure_ca_secret` is the precedent for a
  script-created Secret before the root Application.
- `scripts/argo-down.sh:30-33` exits 0 when `cluster_exists` is false;
  `:149-151` runs `aws_cnpg_backup_and_prune` for non-civo and exits 1 at
  `:118` if the snapshot never completes; `:214-245` waits on Route 53
  unconditionally.
- `scripts/cluster-down.sh:46` runs `terragrunt destroy` for every
  provider; `:95-206` AWS leak sweep.
- `scripts/require-persistent.sh:14-31` reads S3 state keys.
- `scripts/secret-encrypt.sh:33-38`: no encryption context; ciphertext is
  portable between project directories. `alias/lab-secrets` is
  account-global.
- `scripts/lib/require-valid-project-name.sh:22-23`: `vk-local-lab` passes.

## 4. Design and contracts

Inputs: `PROVIDER=local`, `PROJECT_NAME` (default `vk-local-lab`),
`TARGET_REVISION` (default `git rev-parse --abbrev-ref HEAD`),
`LOCAL_CONTEXT_PATTERN` (default `^(kind-|minikube|k3d-|docker-desktop|rancher-desktop|orbstack)`),
existing `ARGO_UP_*`/`ARGO_DOWN_*` timeouts. `SUBDOMAIN`, `REGION` (KMS
only), `ROOT_DOMAIN`, `TLS_*`, `E2E_INSECURE_TLS`, `CONFIRM_DESTROY`,
`CI_TEARDOWN_ALLOW_DATA_LOSS` are ignored on local.

Context guard (`scripts/lib/provider.sh` `local_context_guard`):

```
ctx=$(kubectl config current-context)
[[ $ctx =~ $LOCAL_CONTEXT_PATTERN ]] || die "context '$ctx' does not look local; set LOCAL_CONTEXT_PATTERN or switch context"
kubectl cluster-info >/dev/null || die "context '$ctx' is not reachable"
```

The guard runs at the start of `cluster-up`, `argo-up`, `argo-down`,
`status`, and `test`. It is the only thing that stands between a developer
and running `PROVIDER=local make down` against an EKS context, so it is
fail-closed: an unmatched context is an error, never a warning.

Secrets created by `argo-up` before the root Application, after creating
their namespaces:

| Secret | Namespace | Type | Keys | Source |
|---|---|---|---|---|
| `lab-postgres-app` | `cnpg-system` | `kubernetes.io/basic-auth` | `username=vkdb`, `password` | `secret-decrypt.sh postgres-app-password` |
| `grafana-admin-credentials` | `observability` | Opaque | `admin-user=admin`, `admin-password` | `secret-decrypt.sh grafana-admin-password` |

Both labelled `managed-by=argo-up`; `argo-down` deletes by label after the
cascade. Plaintext never touches disk or logs.

Argo CD admin: `configs.secret.argocdServerAdminPassword` read from
`secrets/${PROJECT_NAME}/argocd-admin-password.bcrypt`.

Root Application values for local: `target=local`, `project`, `repoURL`,
`targetRevision=${TARGET_REVISION}`, `envoyGateway.fqdn=localhost`,
`capacity.spotAvoidance=false`, `storage.className=local-retain`. No ARNs,
no reserved IP, no TLS values.

Lifecycle mapping (ADR 0032): the cluster is developer-owned and outside
the lifecycle classes; Bootstrap = nothing; Persistent = the
`local-retain` data directory on the node (LOCAL-040); Disposable = every
Argo-managed resource and the two `argo-up` Secrets. `persistent-down`
prints where the data lives and how to remove it (`kubectl delete pv` +
node path) but deletes nothing itself.

## 5. Files/components affected

`Makefile`; `scripts/lib/provider.sh`; `scripts/argo-up.sh`;
`scripts/argo-down.sh`; `scripts/cluster-down.sh`;
`scripts/require-persistent.sh`; `scripts/status.sh`;
`scripts/persistent-down.sh`; `scripts/bootstrap-up.sh`;
`secrets/vk-local-lab/{postgres-app-password.enc,grafana-admin-password.enc,argocd-admin-password.bcrypt}`.

## 6. Implementation steps

1. `Makefile`: widen the allowlist; three-way `PROJECT_NAME` block; route
   every stage target through `ifeq ($(PROVIDER),local)`. `make -n full-up`
   for `PROVIDER=aws` and `civo` must be byte-identical before and after.
2. `scripts/lib/provider.sh`: three-way defaults; `local_context_guard`;
   `cluster_exists` local case = the guard.
3. `secrets/vk-local-lab/`: `cp` the three files; verify
   `PROJECT_NAME=vk-local-lab scripts/secret-decrypt.sh postgres-app-password | wc -c`
   is non-zero.
4. `scripts/argo-up.sh`: `local_resolve_inputs`, `ensure_local_secrets`,
   anti-affinity guard, `local_install_root_application`, readiness = root
   Synced/Healthy only.
5. `scripts/argo-down.sh`: guard; skip backup and Route 53; delete labelled
   Secrets after the cascade.
6. `cluster-down.sh`, `require-persistent.sh`, `status.sh`,
   `persistent-down.sh`, `bootstrap-up.sh` local cases.
7. On minikube (the user's current tool): `PROVIDER=local make full-up`,
   `make status`, `make full-down`, `make up`; then switch context to an
   EKS/Civo context and confirm `PROVIDER=local make down` refuses.
8. `make gitops-check`; AWS golden diff empty (no gitops change here —
   sanity gate).

## 7. Dependencies and blockers

None. LOCAL-015 runs in parallel and must be on `main` before this spec
is marked `DONE` (constitution §13).

## 8. Acceptance criteria

- `PROVIDER=local make up` on a minikube context ends with Argo CD
  installed, the two Secrets present, and the root Application
  `Synced`/`Healthy`.
- `PROVIDER=local make down` deletes the cascade and the Secrets; the
  cluster and Argo CD's namespace-level leftovers are as `argo-down`
  leaves them on other providers.
- `full-up`/`full-down` behave as `up`/`down` with no-op lines for the
  other stages.
- With a non-local current context, every local target exits non-zero
  before touching the cluster.
- `PROVIDER=aws make -n full-up` and `PROVIDER=civo make -n full-up`
  output unchanged.
- No plaintext secret appears in any command echo or log.

## 9. Validation

Offline: `make -n` diffs; `shellcheck`; `make gitops-check`. Workstation:
step 7 (~15 min).

## 10. AWS regression protection

Every branch is `if PROVIDER = local ... else <existing code>`; the
`make -n` diff and the golden gitops diff are the proof.

## 11. Rollout and rollback/recovery

No cloud resources. Rollback: revert.

## 12. Risks and unresolved questions

- The context-name pattern is a heuristic. A developer who renamed their
  minikube context must set `LOCAL_CONTEXT_PATTERN`; the error message says
  so.
- `TARGET_REVISION` defaulting to the current branch surprises developers
  who forgot to push — `argo-up` prints the revision and
  `git status -sb` before installing.

## 13. Definition of done

- [ ] Steps 1–6 landed; step 7 cycle recorded including the refusal test
- [ ] aws/civo `make -n` diffs empty; golden diff empty
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `READY`.
- 2026-09-11 — replanned: the platform no longer creates or deletes the
  cluster; `cluster-up` is a context guard.
