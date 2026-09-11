---
id: "HETZ-115"
title: "CNPG Cluster on Hetzner with disposable data on hcloud-volumes"
status: "READY"
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
updated: "2026-09-11"
completed: ""
---

# HETZ-115 — CNPG Cluster on Hetzner with disposable data

## 1. Outcome and rationale

A single-instance CNPG cluster runs on `hcloud-volumes` storage with the
app password from External Secrets. Data dies with every `make down` until
HETZ-120 lands. `CI_TEARDOWN_ALLOW_DATA_LOSS=1` is required for every
Hetzner teardown in the interim, exactly as on Civo.

Read `specs/civo/115-cnpg-cluster-on-civo/spec.md` first. This spec
records only the Hetzner differences.

## 2. Scope and non-goals

In scope:
- The `storage.className` value for `target: hetzner`.
- One real bring-up and one teardown on Hetzner that exercise the shared
  teardown gate and PVC wait.
- The `hetzner` required-objects set in `scripts/gitops-render-check.sh`
  for the `Cluster` kind.

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
3. Run `PROVIDER=hetzner make up` with `CI_TEARDOWN_ALLOW_DATA_LOSS` unset.
   Confirm the Postgres Application reaches `Healthy` and the PVC is
   `Bound` with `csi.hetzner.cloud` as provisioner.
4. Run `hcloud volume list -o json` and confirm one volume of 20 GB in
   `nbg1` attached to the node that runs the instance.
5. Run `PROVIDER=hetzner make down` without the flag. Confirm the gate
   refuses and exits non-zero. Re-run with `CI_TEARDOWN_ALLOW_DATA_LOSS=1`.
   Confirm the PVC wait observes deletion inside
   `ARGO_DOWN_PVC_WAIT_TIMEOUT` and `hcloud volume list` is empty before
   `cluster-down` starts.

## 7. Dependencies and blockers

HETZ-050 provides the storage class and the render-check set. HETZ-085
provides the app password through ESO. CIVO-115 provides the shared
template and the gate.

## 8. Acceptance criteria

- The `Cluster` renders on hetzner and the pod reaches `Healthy`.
- The PVC is `Bound`, provisioner `csi.hetzner.cloud`, storage class
  `hcloud-volumes`, 20 Gi.
- `hcloud volume list` shows exactly one volume while the cluster runs and
  none after `argo-down` completes.
- A teardown with a live `Cluster` and no `CI_TEARDOWN_ALLOW_DATA_LOSS`
  exits non-zero and leaves the cluster running. A teardown with the flag
  destroys the database; that is the documented interim behaviour.
- The aws and civo golden diffs are byte-identical to their baselines.
- `make gitops-check` passes.

## 9. Validation

Offline: `make gitops-check`. Real cloud: one Hetzner bring-up and one
teardown, about 0.10 EUR (one hour of three CAX21 plus one 20 GB volume).

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

- [ ] Values and render-check set added; golden diffs empty
- [ ] One bring-up and one gated teardown recorded with volume listings
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
