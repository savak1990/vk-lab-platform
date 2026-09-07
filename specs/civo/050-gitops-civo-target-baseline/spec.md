---
id: "CIVO-050"
title: "GitOps baseline for target=civo: hoist portable components, values-driven provider differences, golden AWS render"
status: "READY"
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

`helm template gitops --set target=civo` renders a coherent minimal platform.
The platform contains Envoy Gateway, the CNPG operator, ESO, the snapshot
controller, the Civo storage classes, and a cert-manager toggle that is off by
default. `--set target=aws` renders exactly what it renders today. This gives
every later spec a place to add civo files without changes to AWS.

## 2. Scope and non-goals

In scope: `gitops/values.yaml` keys, `gitops/templates/platform/shared/`
*(new)*, `gitops/templates/platform/civo/` *(new)*, moved files, and a golden
render script. Not in scope: ingress annotations (CIVO-060), the cert-manager
install (CIVO-065), sidecars (CIVO-090+), the CNPG Cluster on civo (CIVO-120),
and observability on civo (CIVO-160).

## 3. Current state / evidence

- All 25 files under `gitops/templates/platform/aws/` start with `{{- if eq .Values.target "aws" }}`.
- These files are provider-neutral today: `envoy-gateway/application.yaml`, `postgres/application.yaml` (cnpg-operator), `postgres/priorityclass.yaml`, `external-secrets/application.yaml`, `envoy-gateway/httproutes.yaml`, `policies.yaml`, `rbac/e2e-test-readonly.yaml`.

**Implementation correction (2026-09-07):** `external-secrets/secretstore.yaml` is *not* portable, despite the `(no auth)` note above — the note meant "no explicit auth block" (Pod Identity is ambient), not "no AWS content". The file's `ClusterSecretStore` hardcodes `provider.aws.service: ParameterStore` and `region: {{ .Values.region }}`; hoisting it ungated would render a non-functional AWS-only SecretStore on civo (ESO never resolves it there, so `lab-postgres-app` never materializes — the exact Secret CNPG's bootstrap needs). It stays under `aws/`, gated as before; CIVO-100 (eso-on-civo) adds the civo equivalent. Only `external-secrets/application.yaml` (the operator install) hoists. `ebs-csi/snapshot-controller.yaml` was never actually hoisted either — see the kubernetes-architect amendment below, which already corrected this before implementation started.
- Some otherwise portable files contain AWS literals. `storageClass: ebs-delete` is at `kube-prometheus-stack.yaml:66,95,103`, `loki.yaml:69`, and `postgres/cluster.yaml:43`. Spot anti-affinity is at `kube-prometheus-stack.yaml:55-62,84-91,121-128`, `loki.yaml:59-66`, and `metrics-server.yaml:25-32`. `nodeSelector workload-type: on-demand` is at `postgres/cluster.yaml:13-15`.
- Argo tracks resources by group/kind/name/namespace. The file location does not matter.

## 4. Design and contracts

- New values, with defaults equal to the current AWS behavior: `storage.className: ebs-delete`, `storage.snapshotClassName: ebs-postgres-snapshot`, `capacity.spotAvoidance: true`, `postgres.nodeSelector: {workload-type: on-demand}`, `certManager.enabled: false`, `awsIdentity.mode: podIdentity`, `externalDns.txtOwnerId: ""` (empty → `.Values.project`), `envoyGateway.tls.mode: nlb` (`envoy` on civo), `envoyGateway.service.annotations: {}`. CIVO-060 moves the aws annotations into a values-driven form. In this spec, the aws file keeps its literals.
- `gitops/templates/platform/shared/` gets the hoisted files with no target gate. The hoisted files are: the envoy-gateway Application, the cnpg-operator Application, the PriorityClass, the ESO Application (not the ClusterSecretStore + ExternalSecrets — see the 2026-09-07 correction above), the HTTPRoutes, the BackendTrafficPolicy, and the e2e RBAC. The snapshot CRDs + controller are not hoisted either (kubernetes-architect amendment below).
- **Correction (2026-09-07):** no `gitops/templates/platform/civo/` directory is created in M1 - both of this bullet's original conditionals resolve negative against the CIVO-020 spike result (`specs/civo/research.md:23-24`, ADR 0031, decided 2026-09-06, same day as this spec but not yet folded in when this section was written):
  - `civo-retain` needed `civo-retain` only if the spike chose persistence option (b) (retained volume rebind). It chose (d), logical dumps to S3. Not needed.
  - `volumesnapshotclass.yaml` needed the driver to support snapshots. It doesn't: `ControllerGetCapabilities` never lists a snapshot capability, `CreateSnapshot`/`DeleteSnapshot` return `Unimplemented`, and the `VolumeSnapshot*` CRDs aren't even installed on a Civo cluster. Defining one would be `no matches for kind` at Argo sync time, not a harmless no-op. Not created.
  - `civo-volume` itself needs no gitops template either way - it's preinstalled and owned by a k3s Addon (a patch to it is reverted by the Addon's own reconciler), so it must only ever be *referenced* by name, never defined by a template we own (same two-owners problem this repo's constitution forbids for Terraform/Argo, generalized to k3s/Argo here).
  - What civo *does* need, so this isn't lost until CIVO-120/160 actually consume it: `templates/_helpers.tpl`'s `platform.storageClassName` resolves to `civo-volume` on civo and `.Values.storage.className` otherwise - CIVO-120/160's future civo-only files should call this helper rather than read `.Values.storage.className` directly. No file consumes it yet (nothing civo-facing needs a StorageClass name in M1).
  - `templates/_validate.yaml` (the target-validation guard, unaffected by the above) is real and still added - but named `templates/validate.yaml`, not `_validate.yaml`: Helm never renders (executes) a file whose name starts with `_`, so the leading underscore silently defeats the whole guard - confirmed by testing (`--set target=gcp` rendered clean instead of failing) before catching it.
- These files stay aws-only: alb-controller, the ebs-csi driver + classes, karpenter, the webhook probe, EnvoyProxy/Gateway (until CIVO-060 makes them values-driven), observability (until CIVO-160), and the CNPG Cluster (until CIVO-120).
- `.Values.target` permits the values `aws|civo|local`. A `fail` in `_helpers.tpl` rejects all other values.
- Golden render: `scripts/gitops-render-check.sh` *(new)* renders `gitops/` and `gitops/bootstrap/` with `--set target=aws`. It also renders once with `postgres.recoverySnapshotHandle=snap-x`. The script strips the `# Source:` lines. It sorts the documents by kind/name. It compares the result with a committed baseline under `tests/golden/gitops-aws/`. A regeneration of the baseline is an explicit, reviewed action.

**Review amendments (2026-09-06, kubernetes-architect):**
- The golden check must compare objects, not text. `helm template` output includes template comments and quoting differences (`"external"` vs `external`) that change when literals become values. Normalize each document with `yq -P 'sort_keys(..)'` (or split with `kubectl-slice` and compare with `dyff`) before the diff.
- The `fail` for an unknown `.Values.target` must live in a template that always renders (for example `templates/_validate.yaml` with a guarded `{{- include }}`), not only in a helper that a matching file includes; otherwise an unknown target renders an empty chart without error.
- Keep the AWS EnvoyProxy annotations as a target-conditional literal block inside the shared file (they embed `{{ .Values.envoyGateway.nlbSubnetIds }}`), or render values through `tpl`. CIVO-060 follows this rule.
- Keep the external-snapshotter CRDs and controller gated to `aws`. No snapshot-capable driver exists on Civo, and the `VolumeSnapshotContent` client-side-apply exception plus the root `ignoreDifferences` entry apply to AWS only.

## 5. Files/components affected

- `gitops/values.yaml`, `gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml` (new parameters).
- Moves: the hoisted files to `shared/`.
- Edits: the five storageClass literals, the six spot-affinity blocks, and the CNPG nodeSelector. Each of these becomes a value.
- New: the `civo/` files, `scripts/gitops-render-check.sh`, `tests/golden/gitops-aws/*.yaml`, and the `Makefile` target `gitops-check`.

## 6. Implementation steps

1. Commit the golden baseline from the current tree first. Use a separate commit.
2. Add the values with AWS-equivalent defaults. Replace the literals. Run the check. The diff must be empty.
3. Move the portable files to `shared/`. Remove their gate. Run the check. The diff must be empty.
4. Add the `civo/` files and the target validation helper. Render `--set target=civo`. Run `kubeconform`/`kubectl --dry-run=server` on the AWS cluster for the schema, only where the CRDs exist.
5. Wire `make gitops-check`. Document it in `README.md`.

## 7. Dependencies and blockers

This spec depends on CIVO-010 only for the `target` naming. It is otherwise independent. It can run in parallel with 015/020/025/030.

## 8. Acceptance criteria

- `make gitops-check` passes with an empty diff for aws after every step.
- `helm template --set target=civo` renders envoy-gateway, cnpg-operator, external-secrets (the operator only, not the ClusterSecretStore — see the 2026-09-07 correction), the HTTPRoutes, the BackendTrafficPolicy, and the RBAC. It renders no alb-controller, ebs-csi, karpenter, webhook probe, snapshot controller, or ClusterSecretStore.
- `--set target=gcp` fails.
- `kubeconform -strict` (with CRD schemas where available) passes for both renders.

## 9. Validation

Offline only: `helm template`, `kubeconform`, and the golden diff. Real cloud: an optional AWS sync after the merge shows no OutOfSync or pruned resources. Record the Argo UI/CLI check. The cost is 0.

## 10. AWS regression protection

The golden render diff protects AWS. A post-merge Argo `app diff root` on the AWS cluster must also show no changes.

## 11. Rollout and rollback/recovery

Revert the PR. Argo reconciles the cluster back. There is no data risk, because the CNPG Cluster on aws does not change.

## 12. Risks and unresolved questions

- The Helm sort order of the moved files does not matter to Argo. The golden script must sort the documents to prevent false diffs.

## 13. Definition of done

- [x] Golden baseline committed and check green
- [x] Civo render validated (structural check in `gitops-render-check.sh` + `kubeconform -strict`; no real-cluster Argo sync yet - that's `make argo-up PROVIDER=civo` in CIVO-045)
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-07 — implemented on branch `civo-050-gitops-baseline`: golden baseline (`36a6560`), values-driven storage/spot/nodeSelector (`ea24286`), portable-file hoist to `shared/` (`a886f71`). `templates/validate.yaml` + `_helpers.tpl` added (target validation, `platform.storageClassName`); no `civo/` directory in M1 per the S3/S4 corrections above. `scripts/gitops-render-check.sh` extended to structurally verify `target=civo`/`target=local` (required objects present, aws-only kinds/Applications absent - verified the negative case fires by temporarily un-gating a NodePool file). `make gitops-check` wired (Makefile, appended only - `.PHONY` left untouched to avoid CIVO-040's concurrent rename there). `kubeconform -strict -ignore-missing-schemas` run against both aws (49 resources, 14 checked, 0 invalid) and civo (11 resources, 5 checked, 0 invalid) renders - many CRD-typed resources (Argo `Application`, CNPG `Cluster`, Gateway API, Envoy Gateway policies, Karpenter CRDs) have no local schema and are skipped, not failed; full CRD validation needs a real cluster's `--dry-run=server` (spec S9's "real cloud" case, not yet run). Not yet done: an actual `PROVIDER=civo make argo-up` sync (blocked on CIVO-040/045), and the index/roadmap update (owned by a concurrent session's spec-authoring work on `specs/civo/README.md`/`roadmap.md` at the time of this implementation - not touched here to avoid collision).
