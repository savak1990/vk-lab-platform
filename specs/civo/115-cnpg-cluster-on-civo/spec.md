---
id: "CIVO-115"
title: "CNPG Cluster on Civo with disposable data"
status: "IN_PROGRESS"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "A values-driven template hoist and two script changes; the data-safety reasoning lives in CIVO-120"
effort_estimate: "One session (3–5 h) including one bring-up and one teardown"
estimate_confidence: "high"
depends_on: ["CIVO-050", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# CIVO-115 — CNPG Cluster on Civo with disposable data

## 1. Outcome and rationale

A single-instance CNPG cluster runs on `civo-volume` storage with the app
password supplied through External Secrets. Data is destroyed by every
`make down` until CIVO-180 and CIVO-120 land: there is no backup or restore
mechanism on civo yet, only the cluster itself. `CI_TEARDOWN_ALLOW_DATA_LOSS=1`
is required for every Civo teardown in the interim.

## 2. Scope and non-goals

In scope:
- The shared `Cluster` template, gated so it renders on both `aws` and
  `civo` from one file.
- The teardown gate that refuses to tear down a Civo cluster with a live
  CNPG `Cluster` unless data loss is explicitly allowed.
- The bounded PVC-deletion wait on the civo teardown path.
- `gitops-render-check.sh` updates for the moved template.

Not in scope:
- Anything needing S3, the backup image, or dump/restore jobs (CIVO-180).
- The AWS target's `VolumeSnapshot` path.
- Replicas. `instances: 1` is explicit.

## 3. Current state / evidence

- The CNPG operator Application is shared and renders on both targets, at
  sync-wave `-1`, in namespace `cnpg-system`.
- `ExternalSecret/lab-postgres-app` in `cnpg-system` already rendered on
  civo before this spec (CIVO-100), and
  `/vk-civo-lab/persistent/postgres/app_password` exists in SSM.
- `platform.storageClassName` existed in `gitops/templates/_helpers.tpl`
  with no callers until this spec wired it into the `Cluster` template.

## 4. Design and contracts

- Storage: `civo-volume`, 20 Gi, reclaim `Delete`. The volume dies with the
  cluster by design — there is no snapshot or dump mechanism yet.
- No `nodeSelector` on civo; `affinity.nodeSelector` stays gated to `aws`.
- `spec.enablePDB: false` on civo, gated the same way it is described in
  CIVO-120 (a PDB for one instance blocks node draining).
- Bootstrap is always `initdb` on civo. There is no `recovery` branch and
  no snapshot handle on this target.
- Sync-wave `3`, uniform with aws.

## 5. Files/components affected

`gitops/templates/platform/shared/postgres/cluster.yaml` (moved from
`gitops/templates/platform/aws/postgres/cluster.yaml`); `gitops/values.yaml`
(stale comment); `scripts/gitops-render-check.sh`
(`REQUIRED_OBJECTS_CIVO`/`FORBIDDEN_KINDS_CIVO`); `scripts/lib/provider.sh`
(`civo_backup`); `scripts/argo-down.sh` (civo PVC wait).

## 6. Implementation steps

1. Move `cluster.yaml` to the shared template tree; replace the
   `eq target "aws"` wrapper with `ne target "local"`; gate
   `affinity.nodeSelector`, `backup.volumeSnapshot`, and the `recovery`
   bootstrap branch to `aws`; add the civo `enablePDB: false` gate; resolve
   `storageClass` through `platform.storageClassName`.
2. Update `REQUIRED_OBJECTS_CIVO`/`FORBIDDEN_KINDS_CIVO` in
   `scripts/gitops-render-check.sh` and the stale comment in
   `gitops/values.yaml`.
3. Make `civo_backup()` in `scripts/lib/provider.sh` a fail-closed gate:
   refuse teardown when a CNPG `Cluster` exists, unless
   `CI_TEARDOWN_ALLOW_DATA_LOSS=1`.
4. Make `scripts/argo-down.sh` wait (bounded,
   `ARGO_DOWN_PVC_WAIT_TIMEOUT`, default `180s`) for `cnpg-system` PVCs to
   finish deleting on the civo path, warning rather than aborting on
   timeout.
5. Run `make gitops-check`; the AWS golden diff must be empty.
6. Run `PROVIDER=civo make up` with `CI_TEARDOWN_ALLOW_DATA_LOSS` unset;
   confirm the cluster renders and reaches `Healthy`.
7. Run `PROVIDER=civo make down` without the flag; confirm the teardown
   gate refuses and exits non-zero. Re-run with
   `CI_TEARDOWN_ALLOW_DATA_LOSS=1`; confirm it proceeds and the PVC wait
   completes or warns within the timeout.

## 7. Dependencies and blockers

CIVO-050 provides the layout and the golden-diff harness. CIVO-100 provides
the app password through External Secrets.

## 8. Acceptance criteria

- The `Cluster` template renders on civo and the pod reaches `Healthy`.
- The AWS golden diff is byte-identical to the pre-change baseline.
- A civo teardown with a live `Cluster` and no
  `CI_TEARDOWN_ALLOW_DATA_LOSS` exits non-zero and leaves the cluster
  running.
- A civo teardown with `CI_TEARDOWN_ALLOW_DATA_LOSS=1` proceeds and the
  cascade completes.
- The bounded PVC wait either observes deletion or warns within
  `ARGO_DOWN_PVC_WAIT_TIMEOUT` without aborting the teardown.
- `enablePDB: false` and the civo storage class are present in the
  rendered civo manifest; `nodeSelector` and `backup.volumeSnapshot` are
  absent from it.
- `make gitops-check` passes.

## 9. Validation

Offline: `make gitops-check` (golden diff and kubeconform). Real cloud: one
Civo bring-up and one teardown cycle (~0.1 USD).

## 10. AWS regression protection

The golden diff is byte-identical, which is the whole proof; no AWS cloud
cycle was run or is needed for this spec.

## 11. Rollout and rollback/recovery

No data risk beyond what already exists on civo — the cluster's data is
already disposable before this spec, and remains disposable after it.
Rollback: revert the change; the AWS template returns to its own file
unchanged in substance.

## 12. Risks and unresolved questions

- The hoisted template carries two pre-existing comment-rule violations
  verbatim: a 5-line comment block and a `See ADR 0013` reference. The
  repo's rule caps comments at 3 lines and forbids document references.
  They were preserved because `yq -P` keeps YAML comments, so the
  committed golden baseline under `tests/golden/gitops-aws/` contains them
  verbatim; editing either comment would force regenerating that baseline
  and destroy §10's proof, which is that the golden diff is byte-identical.
  Fixing these comments belongs to whichever spec next regenerates that
  golden.
- Whether the Task 3 PVC wait is sufficient in practice is answered
  empirically by §14's evidence.

## 13. Definition of done

- [ ] Template hoisted and gated; AWS golden diff byte-identical
- [ ] Teardown gate and PVC wait implemented and exercised on one civo cycle
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `IN_PROGRESS`. Implementation (Tasks 1–3) already
  landed in commits `ffd2375`, `645f18a`, `db35b73`; this spec records it.
