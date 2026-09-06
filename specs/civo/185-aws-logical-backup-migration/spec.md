---
id: "CIVO-185"
title: "Migrate the AWS target from EBS snapshots to the shared logical backups"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "It changes the data-recovery path of the working AWS platform; the retirement order and the proof of recovery need care"
effort_estimate: "One session (4–6 h) plus one full AWS down/up cycle"
estimate_confidence: "medium"
depends_on: ["CIVO-120", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-185 — Move the AWS target to the shared backup mechanism

## 1. Outcome and rationale

The AWS target backs up PostgreSQL with the same logical dump job that
Civo uses, and the EBS snapshot machinery retires. One mechanism serves
both providers, so there is one restore drill, one set of scripts and one
document to keep true.

This is deliberately separate from CIVO-180. Milestone M1 must not change
the working AWS data path. This spec makes that change on its own, with
its own proof.

## 2. Scope and non-goals

In scope:
- Enable the backup CronJob and the restore Job on the AWS target.
- Remove the snapshot code paths from `argo-up.sh` and `argo-down.sh`.
- Remove the snapshot classes, the recovered-snapshot template, the `ignoreDifferences` entry and the external-snapshotter Application.
- Amend ADR 0013 and the architecture document.
- Prove recovery on AWS with a full destroy and recreate cycle carrying real rows.

Not in scope:
- Deleting existing EBS snapshots. They stay until an operator removes them, so a rollback remains possible.
- Point-in-time recovery. The trade is stated in the ADR amendment.

## 3. Current state / evidence

- `scripts/argo-down.sh:54-113` creates a CNPG `Backup` with `method: volumeSnapshot`, waits for it, then prunes older EBS snapshots.
- `scripts/argo-up.sh:167-197` discovers the newest snapshot and passes its handle to the root Application.
- `gitops/templates/platform/aws/postgres/recovered-snapshot.yaml` builds a `VolumeSnapshotContent` with a client-side apply exception.
- `gitops/templates/platform/aws/ebs-csi/snapshot-controller.yaml` installs the CRDs and controller at waves -6 and -1.
- `gitops/bootstrap/templates/root-application.yaml:55-62` ignores differences on `VolumeSnapshotContent`.
- `scripts/lib/persistent-ebs-artifacts.sh` lists snapshots for the teardown scripts.

## 4. Design and contracts

- Set `postgres.backup.enabled: true` on the AWS target and point it at the same `${project}-backups` bucket that the persistent stack already creates.
- The AWS pod obtains credentials through the Pod Identity association from CIVO-180. No configuration file and no certificate are involved.
- Replace the snapshot block in `argo-down.sh` with the shared teardown gate: create a Job from the CronJob, wait, fail closed.
- Replace the snapshot discovery in `argo-up.sh` with nothing. The restore Job decides for itself whether the database is empty.
- Remove `recoverySnapshotHandle` from the root Application parameters and from `gitops/values.yaml`.
- Keep the `ebs-retain` StorageClass. It is unrelated to this change.
- Amend ADR 0013 to record that logical dumps replace VolumeSnapshot recovery on both targets, and why: the second provider has no snapshot-capable driver, and one mechanism is cheaper to keep correct than two.

## 5. Files/components affected

- `scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/persistent-ebs-artifacts.sh`, `scripts/persistent-down.sh`.
- `gitops/templates/platform/aws/postgres/recovered-snapshot.yaml` (removed), `.../ebs-csi/{volumesnapshotclass,snapshot-controller}.yaml` (removed), `gitops/bootstrap/templates/root-application.yaml` (parameters and `ignoreDifferences`).
- `gitops/values.yaml`, `docs/adr/0013-*.md`, `docs/architecture.md`, `docs/aws-platform-design.md`.
- `tests/golden/gitops-aws` is regenerated deliberately in this spec.

## 6. Implementation steps

1. Enable the backup job on AWS. Confirm a dump lands in S3 through Pod Identity.
2. Write rows, run `make down`, then `make up`. Confirm the restore Job loads the dump and the rows return.
3. Remove the snapshot code from both scripts and the snapshot manifests from the tree.
4. Regenerate the golden baseline in a separate commit, so the review sees exactly what left the render.
5. Repeat the destroy and recreate cycle with the snapshot path gone.
6. Amend ADR 0013, the architecture document and the AWS design document.

## 7. Dependencies and blockers

CIVO-180 supplies the bucket, image and jobs. CIVO-120 proves the flow on Civo first, so AWS is not the first user of a new mechanism.

## 8. Acceptance criteria

- Two full AWS destroy and recreate cycles restore the rows from S3.
- No reference to `VolumeSnapshot`, `recoverySnapshotHandle` or `snapshot-controller` remains in the scripts, the GitOps tree or the root Application.
- The existing EBS snapshots still exist and are untouched, so a rollback is possible.
- The regenerated golden baseline contains exactly the intended removals and nothing else.
- Documentation states one backup mechanism for both providers.

## 9. Validation

Real cloud on AWS: two full lifecycle cycles at the normal cost of the
AWS lab. Offline: the golden diff and its deliberate regeneration.

## 10. AWS regression protection

This spec is the AWS change, so protection means proof rather than
absence of change: two recorded destroy and recreate cycles with real
rows, taken before and after the snapshot code is removed. The retained
snapshots are the rollback path if a cycle fails.

## 11. Rollout and rollback/recovery

Roll back by reverting the commit. The EBS snapshots that existed before
the migration remain, so the old recovery path still works. This is an
irreversible step only once an operator deletes those snapshots, which
this spec does not do.

## 12. Risks and unresolved questions

- Point-in-time recovery is lost on AWS. Anything written between the last dump and a failure is unrecoverable. Record the accepted window in the ADR amendment.
- A large database makes the teardown dump slower than a snapshot. Measure and adjust the timeout.

## 13. Definition of done

- [ ] Two AWS cycles with data evidence
- [ ] Snapshot code and manifests removed; golden baseline regenerated
- [ ] ADR 0013 amended; architecture and AWS design documents updated
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as READY after the user chose one shared backup mechanism for both providers.
