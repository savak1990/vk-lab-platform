# ADR 0038: The `local` target joins the PROVIDER command surface

## Status

Accepted. Supersedes ADR 0006.

## Context

ADR 0006 added a `local` (minikube/kind) execution target on 2026-08-20. It was
written before `terraform/live/cluster/` and `gitops/` existed on disk, and it
said so: the two-target structure it described was meant to shape specs 004 and
006–012 "from the outset, not be retrofitted."

Those specs were then implemented, and four decisions since have overtaken ADR
0006's design. Each is recorded, but none amended ADR 0006, so its text now
describes a platform that does not exist.

**The chart layout is not what ADR 0006 specified.** ADR 0006 required every
`gitops/` component to be one Helm chart with `values.yaml` plus
`values-aws.yaml` and `values-local.yaml` overrides. CIVO-050 built something
else: a single umbrella chart, per-file inline `{{- if eq .Values.target "x" }}`
gates, a shared `gitops/values.yaml` overridden with `--set` at install time,
and a golden render diff guarding the `aws` output. No `values-<target>.yaml`
file exists anywhere, and none is planned. `docs/architecture.md` §10a already
records this; the specs did not catch up.

**The install path is no longer a divergence.** ADR 0006 made a point of `local`
installing Argo CD from a plain script while `aws` used Terraform. ADR 0012,
accepted two days later, moved the `aws` target off Terraform for exactly the
reason ADR 0006's carve-out created: two divergent mechanisms for one job.
Script-installed Argo CD is now universal.

**A `PROVIDER` selector arrived that ADR 0006 could not anticipate.** Civo
(ADR 0027) and Hetzner (ADR 0036, ADR 0037) are real, non-AWS execution targets
selected by a `PROVIDER` operator input. Constitution §20 states their shared
command convention: the same command pairs as AWS, dispatched by `PROVIDER`, no
separate per-target command set, no new lifecycle command. ADR 0006's
`make minikube-up` / `make kind-up` predates that convention and contradicts it.

**Part of `local` was built, as exclusions.** Implementing Civo and Hetzner left
`local` a valid value of `.Values.target` guarded by eighteen
`{{- if ne .Values.target "local" }}` gates, with a structural contract locked
into `scripts/gitops-render-check.sh`. That render is a skeleton: no Postgres, no
Gateway, no observability, no External Secrets. It also renders an
`HTTPRoute/argocd` whose `parentRefs` name a Gateway that the same render
excludes — a broken render nothing has exercised, because no local cluster has
ever existed.

So the remaining work is un-gating and supplying values, not constraining other
specs. That is a different job from the one ADR 0006 described, and the gap is
too wide to close by amendment.

## Decision

The `local` target is retained, with its purpose unchanged — a fast, AWS-free
inner development loop — and redesigned around what the platform became.

- **`local` is a fourth `PROVIDER`.** `PROVIDER=local` selects it, and the
  existing lifecycle commands do the work: `make up`, `make down`, `make full-up`,
  `make full-down`. Bootstrap and Persistent are no-ops on this target, since it
  owns no cloud resources. `cluster-up` creates a kind cluster and `cluster-down`
  deletes it. There is no `make kind-up` and no `make minikube-up`. This replaces
  ADR 0006's separate command set and brings `local` under constitution §20's
  convention rather than beside it.
- **kind only.** minikube is dropped. Nothing in the design depends on either
  tool, the CI integration test needs kind specifically, and supporting two
  local Kubernetes tools doubles the acceptance surface for no architectural
  gain. ADR 0006 mandated both and forbade a wrapper that chose between them;
  that requirement is withdrawn rather than implemented.
- **One umbrella chart, as CIVO-050 built it.** `local` is a value of
  `.Values.target`, gated per file, with differences expressed through
  `gitops/values.yaml` and `_helpers.tpl` functions. ADR 0006's per-component
  `values-aws.yaml` / `values-local.yaml` layout is withdrawn. It never existed
  and will not be created.
- **The root Application syncs from the working tree, through the CLI.**
  ADR 0006 required `local` to reconcile `gitops/` edits without a commit and
  left the mechanism unresolved. Argo CD's repo-server clones over git and has
  no local-filesystem Application source, so the obvious readings of that
  requirement — a git daemon, or an in-cluster Gitea — mean running a component
  for the whole life of the cluster to save a commit.

  `argocd app sync root --local gitops` needs neither. The CLI renders the
  chart locally and hands the result to the controller, so an uncommitted edit
  reconciles directly. It works here specifically because every child
  Application sources an *upstream* chart: everything this repository authors
  is in the root chart's own render, so one root sync covers it. Argo refuses a
  local sync while automated sync is enabled, so the root Application omits
  `syncPolicy.automated` for this target only, and `argo-up` performs the sync
  itself. Re-running `PROVIDER=local make argo-up` is therefore the target's
  edit-reconcile loop, and it adds an `argocd` CLI dependency that the other
  targets do not have.

  **Amended 2026-09-21.** As first accepted, this bullet said the opposite —
  that `targetRevision` would name a pushed branch like every other target.
  A spike disproved the premise behind that: the CLI path was assumed to be
  defeated by the app-of-apps structure, and it is not.
- **Placeholder secrets only, and no AWS call anywhere.** `argo-up` creates the
  Kubernetes `Secret` objects the platform needs, with generated throwaway
  values, in the same untracked bootstrap class as the Civo CA secret. The
  External Secrets path stays excluded for this target. ADR 0006's opt-in path
  that decrypted real values from `secrets/*.enc` through AWS KMS is withdrawn:
  it was the single AWS dependency in the entire local path, and local data is
  throwaway, so real credentials buy nothing.
- **Access stays `kubectl port-forward` to a ClusterIP Service, over plain HTTP,
  with path-based routing.** These four carry over from ADR 0006 unchanged, and
  the reasoning still holds. Envoy Gateway's own default Service type hangs
  `<pending>` on kind with no cloud load-balancer implementation present. A
  forward to `localhost:PORT` cannot present the Host header that hostname
  matching needs, so `local` matches by path (`/argo`, `/grafana`) while every
  other target matches by hostname. A cert only adds warnings on a target that
  never leaves the machine.

## Alternatives considered

**a. Amend ADR 0006 in place.** Rejected: four of its bullets are withdrawn and
two more describe a chart layout that does not exist. An amendment that large
leaves a reader unable to tell which sentences still hold.

**b. Keep `make kind-up` as a non-lifecycle command, per ADR 0006 and
constitution §17.** Rejected: it duplicates `cluster-up`'s job under a second
name, needs its own teardown command, and puts `local` outside the dispatch that
Civo and Hetzner established. The lifecycle commands already express create and
destroy; a target that creates and destroys a cluster fits them.

**c. Keep minikube alongside kind.** Rejected on cost, not on feasibility.
minikube works. But the CI test standardizes on kind, host reachability differs
between the two on macOS, and every change would need verifying twice.

**d. Keep the working-directory sync by running a git daemon or Gitea.**
Rejected: a component installed, waited for and torn down on every bring-up, to
avoid typing `git commit`. The cost is not proportionate to the saving.

**e. Give `local` its own row in constitution §20 rather than keeping §18.**
Rejected: §20 governs real cloud targets that reach AWS for identity and DNS and
carry their own per-provider variants of the lifecycle classes. `local` reaches
nothing and sits outside the lifecycle taxonomy entirely. §18 remains the right
home, and §20's preamble already says so.

**f. Un-gate nothing and leave `local` as the skeleton it is today.** Rejected:
the skeleton cannot run the E2E suite, and its `HTTPRoute` already dangles. A
target that renders but cannot come up is a maintenance cost with no user.

## Consequences

- ADR 0006 is superseded. Its `local` bullets that survive — ClusterIP, plain
  HTTP, path routing, throwaway data, no AWS edge — are restated above rather
  than cross-referenced, so this ADR reads on its own.
- Constitution §17 loses its `make minikube-up` / `make kind-up` bullet, and §18
  is rewritten: the KMS opt-in sentence goes, the "minikube or kind" phrasing
  becomes kind, and the stale Secrets Manager wording is corrected to Parameter
  Store (ADR 0023).
- `specs/local/022` and `specs/local/024` are rewritten against this ADR. Their
  requirements that cite `values-local.yaml`, `make kind-up`, minikube, the
  working-directory sync, or the KMS opt-in are withdrawn.
  `specs/shared/019`'s rendering requirement is corrected the same way.
- The eighteen `ne .Values.target "local"` gates are revisited component by
  component, and `scripts/gitops-render-check.sh`'s forbidden-object lists for
  `local` shrink to match. Those lists are the contract; changing the render
  without changing them fails the check, which is the intent.
- A local run remains no substitute for the `aws` full lifecycle test
  (constitution §11) or §12's Definition of Done.
