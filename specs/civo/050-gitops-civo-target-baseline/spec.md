---
id: "CIVO-050"
title: "GitOps baseline for target=civo: hoist portable components, values-driven provider differences, golden AWS render"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Mechanical Helm restructuring guarded by a golden diff; the diff makes mistakes visible"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "high"
depends_on: ["CIVO-010"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-050 — GitOps baseline for the Civo target

## 1. Outcome and rationale

`helm template gitops --set target=civo` renders a coherent minimal
platform (Envoy Gateway, CNPG operator, ESO, snapshot controller, Civo
storage classes, cert-manager toggle off by default), and
`--set target=aws` renders exactly what it renders today. This gives every
later spec a place to add civo files without touching AWS.

## 2. Scope and non-goals

In scope: `gitops/values.yaml` keys, `gitops/templates/platform/shared/`
*(new)*, `gitops/templates/platform/civo/` *(new)*, moved files, a golden
render script. Not in scope: ingress annotations (CIVO-060), cert-manager
install (CIVO-065), sidecars (CIVO-090+), CNPG Cluster on civo (CIVO-120),
observability on civo (CIVO-160).

## 3. Current state / evidence

- All 25 files under `gitops/templates/platform/aws/` start with `{{- if eq .Values.target "aws" }}`.
- Provider-neutral today: `envoy-gateway/application.yaml`, `postgres/application.yaml` (cnpg-operator), `postgres/priorityclass.yaml`, `external-secrets/application.yaml`, `external-secrets/secretstore.yaml` (no `auth`), `ebs-csi/snapshot-controller.yaml` (CRDs + controller), `envoy-gateway/httproutes.yaml`, `policies.yaml`, `rbac/e2e-test-readonly.yaml`.
- AWS literals in otherwise portable files: `storageClass: ebs-delete` at `kube-prometheus-stack.yaml:66,95,103`, `loki.yaml:69`, `postgres/cluster.yaml:43`; spot anti-affinity at `kube-prometheus-stack.yaml:55-62,84-91,121-128`, `loki.yaml:59-66`, `metrics-server.yaml:25-32`; `nodeSelector workload-type: on-demand` at `postgres/cluster.yaml:13-15`.
- Argo tracks resources by group/kind/name/namespace; file location does not matter.

## 4. Design and contracts

- New values (defaults = current AWS behavior): `storage.className: ebs-delete`, `storage.snapshotClassName: ebs-postgres-snapshot`, `capacity.spotAvoidance: true`, `postgres.nodeSelector: {workload-type: on-demand}`, `certManager.enabled: false`, `awsIdentity.mode: podIdentity`, `externalDns.txtOwnerId: ""` (empty → `.Values.project`), `envoyGateway.tls.mode: nlb` (`envoy` on civo), `envoyGateway.service.annotations: {}` (aws annotations moved into values-driven form only in CIVO-060; here the aws file keeps its literals).
- `gitops/templates/platform/shared/` gets the hoisted files with no target gate: envoy-gateway Application, cnpg-operator Application, PriorityClass, ESO Application, ClusterSecretStore + ExternalSecrets, snapshot CRDs + controller, HTTPRoutes, BackendTrafficPolicy, e2e RBAC.
- `gitops/templates/platform/civo/` gets: `storageclass.yaml` (`civo-volume` is preinstalled; add `civo-retain` only if the spike chose option b), `volumesnapshotclass.yaml` (driver `csi.civo.com`, Retain, gated on spike result), and placeholders for later specs.
- Files that stay aws-only: alb-controller, ebs-csi driver + classes, karpenter, webhook probe, EnvoyProxy/Gateway (until CIVO-060 makes them values-driven), observability (until CIVO-160), CNPG Cluster (until CIVO-120).
- `.Values.target` allowed values `aws|civo|local`; a `fail` in `_helpers.tpl` for anything else.
- Golden render: `scripts/gitops-render-check.sh` *(new)* renders `gitops/` and `gitops/bootstrap/` with `--set target=aws` (plus once with `postgres.recoverySnapshotHandle=snap-x`), strips `# Source:` lines, sorts documents by kind/name, and diffs against a committed baseline under `tests/golden/gitops-aws/`. Regenerating the baseline is an explicit, reviewed action.

## 5. Files/components affected

- `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml` (new parameters).
- Moves: the hoisted files to `shared/`.
- Edits: the five storageClass literals, six spot-affinity blocks, CNPG nodeSelector → values.
- New: `civo/` files, `scripts/gitops-render-check.sh`, `tests/golden/gitops-aws/*.yaml`, `Makefile` target `gitops-check`.

## 6. Implementation steps

1. Commit the golden baseline from the current tree first (separate commit).
2. Add values with AWS-equivalent defaults; replace literals; run the check: diff must be empty.
3. Move portable files to `shared/`; drop their gate; run the check: empty.
4. Add `civo/` files and the target validation helper; render `--set target=civo` and `kubeconform`/`kubectl --dry-run=server` on the AWS cluster for schema only where CRDs exist.
5. Wire `make gitops-check`; document in `README.md`.

## 7. Dependencies and blockers

CIVO-010 only for the `target` naming; otherwise independent. Parallel with 015/020/025/030.

## 8. Acceptance criteria

- `make gitops-check` passes with an empty diff for aws after every step.
- `helm template --set target=civo` renders: envoy-gateway, cnpg-operator, external-secrets, snapshot controller, ClusterSecretStore, HTTPRoutes, RBAC; no alb-controller, ebs-csi, karpenter, webhook probe.
- `--set target=gcp` fails.
- `kubeconform -strict` (with CRD schemas where available) passes for both renders.

## 9. Validation

Offline only: `helm template`, `kubeconform`, golden diff. Real cloud: optional AWS sync after merge shows no OutOfSync/pruned resources (Argo UI/CLI check recorded). Cost 0.

## 10. AWS regression protection

Golden render diff plus a post-merge Argo `app diff root` on the AWS cluster showing no changes.

## 11. Rollout and rollback/recovery

Revert the PR; Argo reconciles back. No data risk (no CNPG Cluster change on aws).

## 12. Risks and unresolved questions

- Helm sort order of moved files does not matter to Argo, but the golden script must sort documents to avoid false diffs.

## 13. Definition of done

- [ ] Golden baseline committed and check green
- [ ] Civo render validated
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
