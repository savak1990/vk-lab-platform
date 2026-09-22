---
id: "HETZ-050"
title: "GitOps baseline for target=hetzner: CSI Application, storage class, values defaults, render check, golden diffs"
status: "DONE"
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
updated: "2026-09-22"
completed: "2026-09-22"
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
- k3s ships the `local-path` StorageClass as the cluster default, which would compete with the CSI chart's. HETZ-030 removes it with `--disable=local-storage`, so `hcloud-volumes` from the CSI chart is the only class and the only default. k3s also ships metrics-server, so unlike the kubeadm design this target installs none of its own (HETZ-160).
- Sync waves in use: ESO `-2`, Envoy Gateway `-1`, cert-manager `0`, identity and TLS issuers `1`, wildcard certificate `2`. Waves are uniform across targets.

## 4. Design and contracts

- `platform/hetzner/csi/application.yaml`: Argo `Application hcloud-csi`, gated `{{- if eq .Values.target "hetzner" }}`, chart `hcloud-csi` from `https://charts.hetzner.cloud`, version pinned, namespace `kube-system`, `syncOptions: [ServerSideApply=true]`, `sync-wave: "-5"`. Values: `storageClasses[0]: {name: hcloud-volumes, defaultStorageClass: true, reclaimPolicy: Delete}`, and `controller.volumeExtraLabels` carrying `project`, `scope`, `lifecycle` and `managed_by`. The token values the earlier draft listed are the chart's own defaults (`hcloud`/`token`, `controller` only - there is no `node.hcloudToken`), so they are inherited, not restated. No `hcloud-volumes-retain` in M1: persistence is logical dumps (ADR 0031); a Retain class would only create leaked volumes.
- Wave `-5` is the wave `aws/ebs-csi/application.yaml` already uses, and for the same reason: Argo deletes in reverse wave order, and a CSI driver must outlive the PV, PVC and VolumeAttachment objects its own controllers created, which no wave can order against it. An early-deleted driver leaves finalizers uncleared and volumes undeleted. On creation the direction is harmless either way - CNPG and observability PVCs bind only after the CSI controller runs; a PVC that renders before the driver is Pending, not failed, and the root retry budget (constitution, Argo conventions) covers the window.
- `platform.storageClassName`: hetzner → `hcloud-volumes`. Keep the literal in the helper, as for civo, because the name is the chart's default and is referenced, never defined, by shared templates.
- `gitops/values.yaml` documents the hetzner values `argo-up` sets: `storage.className` unused on hetzner (helper wins), `capacity.spotAvoidance: false`, `postgres.nodeSelector: {}` (set through `--set-json`; Helm deep-merges maps), `awsIdentity.mode: rolesAnywhere`, `externalDns.txtOwnerId`, `envoyGateway.location: nbg1`. The chart defaults stay AWS-equivalent.
- `gitops-render-check.sh`: add `REQUIRED_OBJECTS_HETZNER` = the civo required set minus civo-only names plus `Application__argocd__hcloud-csi`; `FORBIDDEN_KINDS_HETZNER` = `VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot EC2NodeClass NodePool` (no `StorageClass`, the CSI chart defines one but it renders inside the chart, not in our tree; the check must still assert no `kubernetes.civo.com/` string appears in the hetzner render); `FORBIDDEN_APPLICATIONS_HETZNER` = `aws-load-balancer-controller ebs-csi-driver karpenter snapshot-controller`. Loop over `civo hetzner local`.
- `platform-critical` PriorityClass (value 100000) under `platform/hetzner/`, referenced by `priorityClassName` in the Argo CD, Envoy, cert-manager, ESO, ExternalDNS and CNPG values for `target: hetzner`; `preferredDuringSchedulingIgnoredDuringExecution` node affinity to `role=worker` (weight 50) on CNPG, Prometheus, Loki and Tempo; CNPG `enablePDB: false`. The control plane is schedulable on Hetzner (decisions.md §3, "Schedulable control plane"), so priority orders preemption and eviction while the affinity keeps the heavy pods on the worker.
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
- `helm template --set target=hetzner` renders `Application hcloud-csi` at wave `-5` and the full non-AWS baseline; it renders no alb-controller, ebs-csi, karpenter, snapshot controller, `kubernetes.civo.com` annotation, or `civo-volume` reference.
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
- The `hcloud` Secret is created by `argo-up`, not by this tree; a render
  is valid without it, a sync is not. `argo-up` ordering (HETZ-045) is the
  guarantee.

## 13. Definition of done

- [x] Golden diffs empty for aws and civo
- [x] Hetzner render validated offline
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-20 — k3s (HETZ-017): the reason `hcloud-volumes` is the only class
  changes from "the bootstrap ships none" to "the bundled `local-path` class
  is disabled by flag", and the render check must assert that no `local-path`
  StorageClass survives on hetzner. metrics-server is no longer an Application
  on this target, because k3s ships one (HETZ-160).
- 2026-09-20 — adds the `platform-critical` PriorityClass, the soft
  `role=worker` affinity and CNPG `enablePDB: false` (decisions.md §3,
  "Schedulable control plane").
- 2026-09-22 — implemented and merged as #65; folder renamed to
  `050-D-gitops-hetzner-target-baseline`. The status was set to `IN_REVIEW` in
  that pull request and moved to `DONE` immediately afterwards, when the
  protocol stopped using `IN_REVIEW` at all; no work changed hands between the
  two. Seven contracts in §3, §4 and §6 were
  wrong or already satisfied, and are corrected here rather than followed.
  - **Sync wave `-5`, not `-3`.** §4 justified `-3` as "below every existing
    wave", which is false: the tree carries `-6`, `-5` and `-4`. The wave that
    matters is a teardown property, and `aws/ebs-csi/application.yaml:13` is
    already at `-5` for the reason that transfers exactly — the attacher must
    clear VolumeAttachment finalizers and the provisioner must delete the
    released volume, and no wave orders controller-created dependents against
    their driver, only being last does. The two CSI drivers now share a wave.
  - **`node.hcloudToken` does not exist.** The chart declares `hcloudToken`
    under `controller` only; §4's `node.hcloudToken.existingSecret.name` would
    have been a silently ignored no-op. The node plugin performs mount
    operations and needs no API token.
  - **The chart's defaults already are §4's values.** `hcloudToken.existingSecret`
    defaults to `hcloud`/`token`, which is what `argo-up` creates (HETZ-045),
    and `storageClasses[0]` already defaults to `hcloud-volumes`,
    `defaultStorageClass: true`, `reclaimPolicy: Delete`. Only `storageClasses`
    is restated, because `reclaimPolicy` is immutable and a chart default that
    flipped to `Retain` would leak volumes silently; a changed token-secret
    default would crash-loop the controller, which is loud enough.
  - **`controller.volumeExtraLabels` added, which §4 does not mention.** A
    dynamically provisioned volume would otherwise carry no labels at all, and
    HETZ-040's post-destroy sweep selects on `project=`, so a leaked volume
    would have been invisible to the one check meant to catch it.
  - **`postgres.backup.sidecarImages` had no `hetzner` key**, so with backups
    enabled the barman plugin rendered `sidecarImage.tag:
    "%!s(<nil>)@%!s(<nil>)"` and two empty fields rather than failing. Both
    self-managed targets reach AWS through Roles Anywhere and need the same
    `aws_signing_helper` build, so `hetzner` is a YAML alias of `civo` rather
    than a copied digest that would drift at the next bump. The render check
    now runs `verify_backup_render` for every non-local target, which is what
    makes a future missing key fail instead of rendering empty.
  - **`REQUIRED_OBJECTS_HETZNER` was a three-item stub** against a 44-object
    render, so adding hetzner to the loop alone would have asserted almost
    nothing. It is now the civo set less `EnvoyProxy` and `Gateway`
    (HETZ-060) and `cluster-autoscaler` with its ServiceMonitor (HETZ-170),
    plus `Application/hcloud-csi`. The cross-target leak grep, previously
    civo-only, now also runs for hetzner and additionally rejects
    `civo-volume` and `kubernetes.civo.com`, which is §8's second criterion.
  - **§6 step 1 and step 4 were already satisfied or unexecutable.**
    `platform.storageClassName` gained its hetzner arm in HETZ-016, so no
    helper change was needed. There is no `gitops/README.md`; the target
    contract lives in `_helpers.tpl:6-9` and the Hetzner Argo flow is already
    described at `docs/civo-high-level-design.md:50`.
  Verified offline: `make gitops-check` green with empty aws and civo golden
  diffs, `kubeconform -strict` 44/44 valid on the hetzner render,
  `--set target=gcp` fails, `shellcheck` and `bash -n` clean. Each new
  assertion was proved to fail when the thing it guards was removed: the CSI
  Application, the `sidecarImages.hetzner` key, and an injected `civo-volume`
  or `kubernetes.civo.com` string.
- 2026-09-22 — three items deliberately left out of this spec, with reasons.
  - The `platform-critical` PriorityClass, the `role=worker` node affinity and
    CNPG `enablePDB: false` move to **HETZ-160**. `role = "worker"` at
    `terraform/modules/hcloud-nodes/main.tf:103` is an hcloud *server* label
    and the k3s install passes no `--node-label`, so the affinity as written
    matches zero Kubernetes nodes. Neither preemption order nor a soft
    affinity is observable in a helm render, and §9 is offline-only, so
    shipping them here would edit templates shared with aws and civo behind no
    check. HETZ-160 installs the heavy pods and can see where they land.
  - Hetzner renders a `GatewayClass` whose `parametersRef` points at an
    `EnvoyProxy` that never renders, because `gateway.yaml:17` gates
    `EnvoyProxy` and `Gateway` on `aws|civo|local` and
    `platform.envoyServiceSpec` and `platform.envoyListeners` have no hetzner
    arm. §2 assigns the load balancer to **HETZ-060**; opening the gate without
    those arms yields an empty service spec.
  - §14's 2026-09-20 note that the render check must assert no `local-path`
    StorageClass survives is not executable here. It is a property of k3s
    started with `--disable=local-storage`, invisible to a helm render, and
    belongs to HETZ-045's live acceptance or HETZ-130.
