# Local provider planning package

This folder holds the planning and specification documents for adding a
developer-owned local cluster (minikube, kind, k3d, Docker Desktop) as a
third execution target next to AWS/EKS and Civo. The platform installs
into that cluster; it never creates or deletes it. Implementation code does not live here. It lands in the normal
repository locations that each spec names.

Baseline inspected: branch `civo-115-cnpg-cluster-on-civo`, commit
`db35b73`, 2026-09-11.

This package supersedes `specs/022-local-dev-mode/`,
`specs/024-ci-kind-integration-test/`, and ADR 0006. Those documents
described `local` as a gitops-only `target` with separate `make kind-up` /
`make minikube-up` commands outside the lifecycle classes. This package
makes `local` a `PROVIDER` value that reuses the full lifecycle command
surface, with `cluster-up` reduced to a context guard. See `decisions.md` §2.

## Reading order

1. `architecture.md` — what the running platform needs from the cloud, what
   replaces each dependency locally, the target design, and the change map.
2. `research.md` — verified facts about kind, local-path storage, Envoy
   Gateway exposure, and GitHub-hosted runners, with sources.
3. `decisions.md` — accepted constraints, the ADR proposal, open decisions,
   rejected alternatives.
4. `roadmap.md` — milestones, dependency graph, first PRs, coverage.
5. The spec you were asked to implement, plus its `depends_on` specs.

## Format note

Specs in this folder use YAML front matter and a fixed 14-section body,
identical to `specs/civo/`. The folder name (`NNN-title`) and the `id`
field are the stable identifiers. Never renumber them. Numbers step by
ten. Insert later work into the gaps (`065-...`) without renumbering.

## Status protocol

| Status | Meaning |
|---|---|
| `DRAFT` | Specification incomplete, unapproved, or design unresolved |
| `READY` | Approved for development; no active blocker. An implementer may start only when every `depends_on` is `DONE` (checked at session start) |
| `IN_PROGRESS` | An authorized implementer started the bounded work |
| `BLOCKED` | Needs a named decision, capability, prerequisite, or unfinished hard dependency; `blocked_by` names it |
| `IN_REVIEW` | Implementation and checks complete, awaiting review. **Used only when the operator asks for a pull request.** A change that goes straight to `main` skips this status |
| `DONE` | Acceptance criteria and gates passed, evidence recorded, reviewed and integrated |
| `CANCELLED` | Abandoned or superseded; rationale and replacement kept |

Flow: `DRAFT → READY → IN_PROGRESS → DONE`, or
`DRAFT → READY → IN_PROGRESS → IN_REVIEW → DONE` when a pull request exists.
`BLOCKED` may interrupt anywhere. It returns to `READY` or `IN_PROGRESS`.
A review failure returns the spec to `IN_PROGRESS`. Reopening `DONE` needs a
recorded reason.

Priority:

- `P0`: a critical prerequisite or a governance/data-safety blocker for the milestone.
- `P1`: required for the first viable local platform.
- `P2`: a follow-up.
- `P3`: optional.

Difficulty:

- `S`: a bounded local change.
- `M`: several known components.
- `L`: substantial cross-component or lifecycle reasoning.
- `XL`: must be split (none remain).

Model tier: `fast`, `standard`, `strongest`. This is a recommendation only.
The gates do not relax.

## Implementation-session protocol

1. Read this README, `architecture.md` §3, and the spec plus its `depends_on`.
2. Check that every `depends_on` is `DONE`. Otherwise, set `BLOCKED` with `blocked_by` and stop.
3. Set `status: "IN_PROGRESS"` and `updated`. Add a status-history line.
4. Implement only the spec's scope. Do not touch AWS or Civo behavior unless the spec says so. Run the AWS regression gate that the spec names (`make gitops-check` golden diff at minimum).
5. Run the validation section. Record the commands and results (no secrets) under "Execution evidence".
6. A pull request is optional. The operator decides. **The default is to push the change straight to `main` and open no pull request.** Ask only when the change is large, risky, or touches AWS or Civo behaviour.
   - No pull request: skip `IN_REVIEW`. Go to step 7.
   - Pull request: set `IN_REVIEW` and open one PR mapped to the spec ID. Go to step 7 after the merge.
7. When the change is on `main` and the gates pass, set `DONE` and `completed`. Record in the status history whether a pull request was used. Re-check the direct dependents' `blocked_by`.
8. Update the index table below if the status, priority, or dependencies changed.

## Index

| ID | Folder | Title | Status | Pri | Diff | Tier | Depends on | Milestone |
|---|---|---|---|---|---|---|---|---|
| LOCAL-010 | [010-provider-command-surface](010-provider-command-surface/spec.md) | `PROVIDER=local`: Make dispatch, context guard, script branches, secrets from KMS | READY | P0 | M | strongest | — | M0 |
| LOCAL-015 | [015-governance-adr-constitution](015-governance-adr-constitution/spec.md) | ADR 0032, constitution §17/§18/§20, architecture §10a, delete specs 022/024 | READY | P0 | S | standard | — | M0 |
| LOCAL-020 | [020-feasibility-spike](020-feasibility-spike/spec.md) | Throwaway spike: CNPG adoption on local-path, minikube node path, port-forward authority | READY | P0 | M | standard | 010 | M0 |
| LOCAL-030 | [030-gitops-local-target-baseline](030-gitops-local-target-baseline/spec.md) | `target=local` render contract inverted; helpers, gates, render-check | READY | P1 | M | standard | 010 | M1 |
| LOCAL-040 | [040-storage-and-cnpg](040-storage-and-cnpg/spec.md) | Platform-owned local-path provisioner, `local-retain`; CNPG survives `down`/`up` | READY | P1 | M | standard | 020, 030 | M1 |
| LOCAL-050 | [050-ingress-envoy-portforward](050-ingress-envoy-portforward/spec.md) | Envoy `ClusterIP` by port-forward, HTTP only, `*.localhost` routes | READY | P1 | M | standard | 030 | M1 |
| LOCAL-070 | [070-observability-trimmed](070-observability-trimmed/spec.md) | Observability stack on local with laptop-sized retention and PVCs | READY | P1 | M | standard | 040, 050 | M1 |
| LOCAL-080 | [080-e2e-local-environment](080-e2e-local-environment/spec.md) | `framework.LocalEnvironment`; `make test` on local | READY | P1 | M | standard | 040, 050, 070 | M1 |
| LOCAL-090 | [090-ci-and-lifecycle-validation](090-ci-and-lifecycle-validation/spec.md) | `lifecycle-test.yml` `provider=local` on a kind runner; full lifecycle evidence | READY | P1 | M | standard | 080 | M1 |
| LOCAL-110 | [110-developer-docs](110-developer-docs/spec.md) | README quickstart and workstation prerequisites | READY | P2 | S | fast | 090 | M2 |

The headers in each `spec.md` are the source of truth. Keep this table in sync.
