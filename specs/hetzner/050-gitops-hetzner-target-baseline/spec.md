---
id: "HETZ-050"
title: "GitOps baseline for target=hetzner: CSI Application, storage class, values defaults, render check, golden diffs"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Mechanical Helm additions guarded by golden diffs for two targets; the one design point is the storage-class default"
effort_estimate: "One session (3–5 h)"
estimate_confidence: "high"
depends_on: ["HETZ-016", "CIVO-050"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-050 — GitOps baseline for the Hetzner target

## 1. Outcome and rationale

`helm template gitops --set target=hetzner` renders the non-AWS baseline
that HETZ-016 hoisted (Envoy Gateway, CNPG operator, ESO, cert-manager,
identity, TLS, HTTPRoutes, RBAC) plus one Hetzner-only Application: the
hcloud CSI driver. `--set target=aws` and `--set target=civo` render
exactly what they render today. Civo needs no storage Application because
Civo pre-installs its CSI; Hetzner does not, so Argo owns it.

## 2. Scope and non-goals

In scope: `gitops/templates/platform/hetzner/csi/application.yaml`,
the hetzner branch of `platform.storageClassName`, hetzner defaults in
`gitops/values.yaml`, the hetzner sets in `scripts/gitops-render-check.sh`,
and `kubeconform` on the render. Not in scope: the CCM (installed by
`argo-up`, HETZ-045), LB annotations (HETZ-060), the CNPG Cluster (HETZ-115),
observability values (HETZ-160).

## 3. Current state / evidence

- `gitops/templates/_helpers.tpl:7` allows `aws|civo|local`; after HETZ-016 it allows `hetzner` and exposes `platform.selfManaged` (true for civo and hetzner).
- `_helpers.tpl:18-22` maps civo to `civo-volume` and everything else to `.Values.storage.className`.
- `scripts/gitops-render-check.sh:63-79` holds `REQUIRED_OBJECTS_CIVO`, `FORBIDDEN_KINDS_CIVO` (includes `StorageClass`), `FORBIDDEN_APPLICATIONS_CIVO`; `:122` loops over `civo local`.
- The hcloud CSI chart `hcloud/hcloud-csi` v2.23.0 ships StorageClass `hcloud-volumes` with `defaultStorageClass: true`, `reclaimPolicy: Delete`, `WaitForFirstConsumer`, expansion on, and reads `kube-system/hcloud` key `token` (research.md).
- k3s ships `local-path` as a default StorageClass unless `--disable local-storage` is set. HETZ-030 sets that flag, so `hcloud-volumes` is the only default class.
- Sync waves in use: ESO `-2`, Envoy Gateway `-1`, cert-manager `0`, identity and TLS issuers `1`, wildcard certificate `2`. Waves are uniform across targets.

## 4. Design and contracts

- `platform/hetzner/csi/application.yaml`: Argo `Application hcloud-csi`, gated `{{- if eq .Values.target "hetzner" }}`, chart `hcloud-csi` from `https://charts.hetzner.cloud`, version pinned, namespace `kube-system`, `syncOptions: [ServerSideApply=true, CreateNamespace=false]`, `sync-wave: "-3"`. Values: `controller.hcloudToken.existingSecret.name: hcloud`, `node.hcloudToken.existingSecret.name: hcloud`, `storageClasses[0]: {name: hcloud-volumes, defaultStorageClass: true, reclaimPolicy: Delete}`. No `hcloud-volumes-retain` in M1: persistence is logical dumps (ADR 0031); a Retain class would only create leaked volumes.
- Wave `-3` is below every existing wave and is hetzner-only, so no other target's ordering changes. CNPG and observability PVCs bind only after the CSI controller runs; a PVC that renders before the driver is Pending, not failed, and the root retry budget (constitution, Argo conventions) covers the window.
- `platform.storageClassName`: hetzner → `hcloud-volumes`. Keep the literal in the helper, as for civo, because the name is the chart's default and is referenced, never defined, by shared templates.
- `gitops/values.yaml` documents the hetzner values `argo-up` sets: `storage.className` unused on hetzner (helper wins), `capacity.spotAvoidance: false`, `postgres.nodeSelector: {}` (set through `--set-json`; Helm deep-merges maps), `awsIdentity.mode: rolesAnywhere`, `externalDns.txtOwnerId`, `envoyGateway.location: nbg1`. The chart defaults stay AWS-equivalent.
- `gitops-render-check.sh`: add `REQUIRED_OBJECTS_HETZNER` = the civo required set minus civo-only names plus `Application__argocd__hcloud-csi`; `FORBIDDEN_KINDS_HETZNER` = `VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot EC2NodeClass NodePool` (no `StorageClass`, the CSI chart defines one but it renders inside the chart, not in our tree; the check must still assert no `kubernetes.civo.com/` string appears in the hetzner render); `FORBIDDEN_APPLICATIONS_HETZNER` = `aws-load-balancer-controller ebs-csi-driver karpenter snapshot-controller`. Loop over `civo hetzner local`.
- `kubeconform -strict -ignore-missing-schemas` runs on the hetzner render as it does for civo.

## 5. Files/components affected

`gitops/templates/platform/hetzner/csi/application.yaml` (new),
`gitops/templates/_helpers.tpl`, `gitops/values.yaml`,
`scripts/gitops-render-check.sh`, `tests/golden/gitops-aws/` unchanged,
`tests/golden/gitops-civo/` unchanged (created by HETZ-016).

## 6. Implementation steps

1. Add the hetzner branch to `platform.storageClassName`. Run `make gitops-check`. Both golden diffs empty.
2. Add the CSI Application and the values. Render `--set target=hetzner`. Run `kubeconform`.
3. Add the hetzner sets to the render check. Break the check once on purpose (un-gate an aws NodePool) and confirm it fires for hetzner.
4. Run `make gitops-check` clean. Document `target=hetzner` in `gitops/README.md`.

## 7. Dependencies and blockers

HETZ-016 (allowed targets, hoisted non-AWS files, civo golden baseline).
CIVO-050 (the shared tree). Parallel with HETZ-025/030/040. The live sync
is HETZ-045's acceptance criterion.

## 8. Acceptance criteria

- `make gitops-check` passes with empty diffs for aws and civo.
- `helm template --set target=hetzner` renders `Application hcloud-csi` at wave `-3` and the full non-AWS baseline; it renders no alb-controller, ebs-csi, karpenter, snapshot controller, `kubernetes.civo.com` annotation, or `civo-volume` reference.
- `--set target=gcp` fails.
- `kubeconform -strict` passes for the hetzner render.

## 9. Validation

Offline only: `helm template`, `kubeconform`, golden diffs. Cost 0.

## 10. AWS regression protection

Both golden renders (aws and civo) stay empty diffs. After merge,
`argocd app diff root` on the AWS cluster and on a running Civo cluster
must show no change.

## 11. Rollout and rollback/recovery

Revert the PR. No cluster consumes `target=hetzner` until HETZ-045. No
data risk.

## 12. Risks and unresolved questions

- The CSI chart's StorageClass is Argo-owned through the chart; a later
  values change to `reclaimPolicy` recreates the class (immutable field).
  Keep `Delete` in M1.
- Volumes are 10 GB minimum; 1Gi PVC requests round up to 10 GB (HETZ-160
  cost note).
- If HETZ-030 does not disable `local-storage`, two default classes exist
  and PVCs without an explicit class fail with `more than one default`.
  This spec asserts the flag in HETZ-030 §4.
- The `hcloud` Secret is created by `argo-up`, not by this tree; a render
  is valid without it, a sync is not. `argo-up` ordering (HETZ-045) is the
  guarantee.

## 13. Definition of done

- [ ] Golden diffs empty for aws and civo
- [ ] Hetzner render validated offline
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
