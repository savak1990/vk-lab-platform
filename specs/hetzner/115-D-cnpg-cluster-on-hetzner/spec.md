---
id: "HETZ-115"
title: "CNPG Cluster on Hetzner with disposable data on hcloud-volumes"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "The template is already shared and gated by HETZ-016; this spec adds one storage-class value and one real cycle"
effort_estimate: "Half a session (2–3 h) including one bring-up and one teardown"
estimate_confidence: "high"
depends_on: ["HETZ-050", "HETZ-085", "CIVO-115"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-23"
completed: "2026-09-23"
---

# HETZ-115 — CNPG Cluster on Hetzner with disposable data

## 1. Outcome and rationale

A single-instance CNPG cluster runs on `hcloud-volumes` storage with the
app password from External Secrets. Data dies with every `make down` until
HETZ-120 lands. Teardown does not block on that: it warns that no backup
mechanism exists yet and proceeds, exactly as on Civo.

Read `specs/civo/115-D-cnpg-cluster-on-civo/spec.md` first. This spec
records only the Hetzner differences.

## 2. Scope and non-goals

In scope:
- The `storage.className` value for `target: hetzner`.
- One real bring-up and one teardown on Hetzner that exercise the shared
  teardown gate and PVC wait.
- The `hetzner` required-objects set in `scripts/gitops-render-check.sh`
  for the `Cluster` kind. Already present at `:181-196` when this spec ran;
  no edit was needed. Already present at `:181-196` when this spec ran;
  no edit was needed.

Not in scope:
- Dumps, restore, the S3 bucket (CIVO-180, HETZ-120).
- Replicas. `instances: 1` stays explicit.
- A `Retain` storage class. Not needed: the dump is the persistence.

## 3. Current state / evidence

- `gitops/templates/platform/shared/postgres/cluster.yaml` renders on every
  non-`local` target (CIVO-115). After HETZ-016, `enablePDB: false` and the
  absence of `nodeSelector` are gated by `platform.selfManaged`, which is
  true for `civo` and `hetzner`.
- `platform.storageClassName` resolves `hcloud-volumes` for `hetzner`
  (HETZ-050). The class is created by the CSI Application at wave −3 with
  `reclaimPolicy: Delete`, `volumeBindingMode: WaitForFirstConsumer`,
  expansion on (`research.md`, hcloud-csi row).
- `ExternalSecret/lab-postgres-app` renders on hetzner (HETZ-085), and
  `/vk-hetzner-lab/persistent/postgres/app_password` exists in SSM after
  `persistent-up`.
- The teardown gate (`non_aws_backup` after HETZ-016) and the bounded PVC
  wait in `scripts/argo-down.sh` run on every non-AWS provider.

## 4. Design and contracts

- Storage: `hcloud-volumes`, 20 Gi. Hetzner's minimum is 10 GB, so the
  request is honoured as-is. Reclaim `Delete`: the volume is removed when
  the PVC is removed. The volume is `location`-bound to `nbg1`; every node
  is in `nbg1`, so `WaitForFirstConsumer` binding can never fail on
  location.
- No `nodeSelector`. The control-plane node is schedulable (HETZ-030). The
  instance may land on it; that is accepted for one instance.
- `spec.enablePDB: false` through `platform.selfManaged`. HETZ-170's
  autoscaler drains real servers, so this matters more than on Civo.
- Bootstrap is always `initdb`. No recovery branch, no snapshot handle.
- Sync-wave `3`, uniform across targets.
- Labels: the CSI driver labels every volume with the PVC namespace and
  name. HETZ-040's sweep selects volumes by the CSI's labels plus the
  cluster name, so a volume left behind by a failed cascade is reaped by
  `cluster-down`.

## 5. Files/components affected

`gitops/values.yaml` (hetzner target block: `storage.className`);
`scripts/gitops-render-check.sh` (`REQUIRED_OBJECTS_HETZNER` gains
`Cluster/lab-postgres`); no template change.

## 6. Implementation steps

1. Confirm `helm template --set target=hetzner` renders the `Cluster` with
   `storageClass: hcloud-volumes`, `enablePDB: false`, no `nodeSelector`,
   no `backup.volumeSnapshot`, no `recovery`.
2. Add `Cluster/lab-postgres` to the hetzner required set in
   `scripts/gitops-render-check.sh`. Run `make gitops-check`. The aws and
   civo golden diffs must be empty.
3. Run `PROVIDER=hetzner make up`. Confirm the Postgres Application
   reaches `Healthy` and the PVC is `Bound` with `csi.hetzner.cloud` as
   provisioner.
4. Run `hcloud volume list -o json` and confirm one volume of 20 GB in
   `nbg1` attached to the node that runs the instance.
5. Run `PROVIDER=hetzner make down`. Confirm it warns that no backup
   mechanism exists and proceeds. Confirm the PVC wait observes deletion
   inside `ARGO_DOWN_PVC_WAIT_TIMEOUT` and `hcloud volume list` is empty
   before `cluster-down` starts.

## 7. Dependencies and blockers

HETZ-050 provides the storage class and the render-check set. HETZ-085
provides the app password through ESO. CIVO-115 provides the shared
template and the gate.

## 8. Acceptance criteria

- The `Cluster` renders on hetzner and the pod reaches `Healthy`.
- The PVC is `Bound`, provisioner `csi.hetzner.cloud`, storage class
  `hcloud-volumes`, 20 Gi.
- `hcloud volume list` shows exactly one *Postgres* volume while the cluster
  runs, and none after `argo-down` completes. The count is four in total:
  observability binds three more (Prometheus, Alertmanager, Loki), which this
  criterion was written before and does not own.
- A teardown with a live `Cluster` and no configured backup says so and
  proceeds without attempting one. It destroys the database; that is the
  documented interim behaviour until HETZ-120 lands.
- The aws and civo golden diffs are byte-identical to their baselines.
- `make gitops-check` passes.

## 9. Validation

Offline: `make gitops-check`. Real cloud: one Hetzner bring-up and one
teardown, about 0.10 EUR (one hour of the fixed `cx33` pair plus one
20 GB volume).

## 10. AWS regression protection

No template changes; the aws golden diff is the proof. Civo: the civo
golden diff is empty and `PROVIDER=civo make -n down` is byte-identical.

## 11. Rollout and rollback/recovery

No data risk beyond what already exists on hetzner. Rollback: revert the
values entry; the render check then fails until the set is reverted too.

## 12. Risks and unresolved questions

- Volume detach on teardown: hcloud detaches a volume only when the node
  releases it. If the CNPG pod is force-deleted, the CSI node plugin may
  not unpublish and the volume stays `attached` until the server dies.
  HETZ-040's sweep deletes volumes after the servers, so this cannot leak,
  but it may slow `cluster-down` by one detach timeout. Record the timing.
- The 10 GB minimum does not affect this claim; it affects HETZ-160.

## 13. Definition of done

- [x] Values and render-check set added; golden diffs empty
- [x] One bring-up and one gated teardown recorded with volume listings
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — cost line re-based on the fixed `cx33` pair; CAX is gone.

- 2026-09-22 — observed during HETZ-060's live cycle, not investigated:
  **Postgres backups are half-enabled on this target.** `argo-up` passes
  `postgres.backup.enabled=false`, yet `argo-down` reported
  `ContinuousArchiving=True` on the live cluster and its pre-teardown backup
  failed immediately:

  ```
  ARGO-DOWN: backup phase: failed (0s/600s)
  ARGO-DOWN: WARNING - the pre-teardown Postgres backup did not complete
  ARGO-DOWN: WARNING - ContinuousArchiving=True.
  ```

  So archiving was running while the backup path did not work. `backup_teardown`
  handled it exactly as designed - warned, explained the consequence for
  recovery, and continued rather than blocking the teardown - which is why
  this is a note and not an incident.

  Determining whether archiving should be on at all here, and why the backup
  failed, belongs to this spec and HETZ-120. It was left alone deliberately:
  chasing it mid-teardown would have cost a rebuild, and the evidence
  disappears as the cascade proceeds.

  Evidence that this spec's own criteria are close: three `hcloud-volumes`
  PVCs bound at 10Gi each (Prometheus, Alertmanager, Loki) with provisioner
  `csi.hetzner.cloud`, and every volume gone after teardown.

- 2026-09-22 — reproduced on HETZ-047's cycle, with the same shape: the
  pre-teardown backup failed immediately while `ContinuousArchiving=True`
  and `argo-up` had passed `postgres.backup.enabled=false`. Two cycles
  running makes this consistent rather than a one-off, so it is a
  configuration contradiction to find, not a flake to wait out.
- 2026-09-22 — observed on HETZ-085's cycle. The `lab-postgres` Cluster
  reached `Cluster in healthy state` with one instance and one bound 20Gi
  `hcloud-volumes` PVC, and `kubectl get application -n argocd` listed ten
  Applications with no `barman-cloud-plugin` among them — which is the
  expected shape when `argo-up` passes `postgres.backup.enabled=false`, and
  confirms directly that the plugin `backup_teardown` asks for is not
  installed on this target. That is the missing half of the contradiction
  recorded above: `backup_teardown` is ungated for every provider except
  `local` (`scripts/argo-down.sh:137-139` → `scripts/lib/provider.sh:468-526`)
  and never consults `postgres.backup.enabled`, so it applies a
  `method: plugin` Backup against a cluster that has no plugin. One guard in
  `backup_teardown` is the whole fix; it belongs to this spec, not to the one
  whose cycle found it.

- 2026-09-23 - fourth reproduction, on HETZ-070's prod cycle. `argo-down`
  printed `Backup/lab-postgres-teardown-... reported phase 'failed'` and
  `ContinuousArchiving=True` again, with no `barman-cloud-plugin` Application
  in the cluster. Nothing new about the mechanism; it is simply four for four.

- 2026-09-23 - closed on one cycle on `vk-hetzner-lab`, `fsn1`, three `cpx32`.

  The `Cluster` reached `1/1` and "Cluster in healthy state". Its PVC bound at
  20 Gi on `hcloud-volumes`, provisioner `csi.hetzner.cloud`, reclaim
  `Delete`. `hcloud volume list` held one 20 GB volume for Postgres and three
  10 GB ones for Prometheus, Alertmanager and Loki, and none after the
  teardown. Nothing in `gitops/` or `values.yaml` needed changing: the storage
  class is hardcoded in `_helpers.tpl:38-42` and `Cluster/lab-postgres` was
  already in `REQUIRED_OBJECTS_HETZNER`, so the spec's own §5 file list was
  stale in this spec's favour.

  The teardown bug this spec inherited is fixed, and the fix is four lines in
  `backup_teardown` (`scripts/lib/provider.sh`, after the existing Cluster
  check). It reproduced on the 060, 047, 085 and 070 cycles: `argo-up` passes
  `postgres.backup.enabled=false` on hetzner, so no barman plugin and no
  `ObjectStore` exist, while `cluster.yaml` is ungated and `lab-postgres`
  does - and the teardown attempted a `method: plugin` Backup that failed in
  zero seconds, warned that writes were about to be destroyed, and then waited
  out its poll. This run printed one line instead:

      ARGO-DOWN: no barman ObjectStore - backups are not configured, nothing to back up.

  The guard reads the `ObjectStore`, not `$PROVIDER`. `kubectl get objectstore`
  returns non-zero when the CRD itself is absent, which is the hetzner case
  (`the server doesn't have a resource type "objectstore"`), so one check
  covers both and the fix holds for any backup-disabled configuration rather
  than for one target.

  §8's third criterion said "exactly one volume" and its fourth named a
  warning the code has never emitted. Both were corrected above before the
  run rather than reported as passes.
