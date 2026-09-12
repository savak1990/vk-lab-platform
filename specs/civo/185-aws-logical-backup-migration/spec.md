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
effort_estimate: "One session (4–6 h) plus two full AWS down/up cycles"
estimate_confidence: "medium"
depends_on: ["CIVO-120", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-11"
completed: null
---

# CIVO-185 — Move the AWS target to the shared backup mechanism

## 1. Outcome and rationale

The AWS target backs up PostgreSQL with the same job Civo uses, reading and
writing the same object layout in its own bucket. The EBS snapshot machinery is
deleted. One mechanism means one restore drill, one set of scripts, and one
paragraph in the architecture document that has to stay true.

This is deliberately the third and last step. Milestone M1 must not touch the
working AWS data path, so CIVO-180 builds the plumbing and CIVO-120 proves the
whole cycle on Civo, where the data is already disposable. Only then does AWS
move. The M2 milestone reflects that AWS is not broken today — not that this
work is indefinitely deferred; it is sequenced directly after CIVO-120.

## 2. Scope and non-goals

In scope:
- Enable the backup and restore jobs on the AWS target.
- Delete the snapshot code paths from `argo-up.sh`, `argo-down.sh` and
  `scripts/lib/persistent-ebs-artifacts.sh`.
- Delete the snapshot manifests, the `recoverySnapshotHandle` plumbing, the
  recovery bootstrap branch and the `ignoreDifferences` entry.
- Regenerate the golden render deliberately.
- Amend ADR 0013 and correct the architecture document.
- Two full AWS destroy/recreate cycles carrying real rows.

Not in scope:
- Any change to Civo behaviour. Civo is already on this mechanism and must not
  move under this spec.
- Point-in-time recovery. ADR 0031 states the trade; this spec enacts it for
  AWS and does not reopen it.
- Cross-provider promotion (CIVO-186).

## 3. Current state / evidence

Line numbers below were re-checked on 2026-09-11; earlier drafts of this spec
cited pre-CIVO-115 positions that no longer exist.

- `scripts/argo-down.sh:86-147` (`aws_cnpg_backup_and_prune`) creates a CNPG
  `Backup` with `method: volumeSnapshot`, polls for `completed` against
  `ARGO_DOWN_BACKUP_TIMEOUT`, then prunes tagged EBS snapshots to the newest two
  with `sort_by(...)[:-2]`. It aborts on failure with no override — AWS has
  never had a `CI_TEARDOWN_ALLOW_DATA_LOSS` escape hatch.
- `scripts/argo-up.sh:296-328` (`aws_resolve_snapshot`) discovers the newest
  completed snapshot, prunes as a safety net, and passes the handle to the root
  Application at line 392.
- `gitops/templates/platform/shared/postgres/cluster.yaml` carries an
  aws-only `bootstrap.recovery` branch and an aws-only `backup.volumeSnapshot`
  stanza, both gated on the target and the handle.
- `gitops/templates/platform/aws/postgres/recovered-snapshot.yaml` renders the
  `VolumeSnapshotContent` and `VolumeSnapshot`.
- `gitops/templates/platform/aws/ebs-csi/` holds the `VolumeSnapshotClass` and
  the `snapshot-controller`/`external-snapshotter-crds` Applications.
- `gitops/bootstrap/templates/root-application.yaml` ignores differences on
  `VolumeSnapshotContent`.
- `scripts/lib/persistent-ebs-artifacts.sh` enumerates snapshots for
  `persistent-down.sh`, whose confirmation prompt names them.

## 4. Design and contracts

- Set `postgres.backup.enabled: true` for the AWS target, pointing at
  `${project}-backups` — the same unit CIVO-180 already applies to both
  projects.
- The AWS pod gets credentials from the Pod Identity association CIVO-180
  created. No config file, no certificate, no sidecar. The manifests are
  identical to Civo's apart from that.
- `aws_cnpg_backup_and_prune` is replaced by the shared teardown gate — create
  the Job from the suspended CronJob, wait, prune to two. **AWS gains the
  `CI_TEARDOWN_ALLOW_DATA_LOSS` override it never had**, because the gate is now
  one shared function. Say so explicitly rather than letting it arrive as a
  side effect: it is a real loosening of AWS's data-safety posture, justified
  only by having one code path instead of two.
- `aws_resolve_snapshot` is replaced by the shared restore step. Nothing
  discovers a handle, nothing is passed into Helm, and the `Cluster` bootstrap
  becomes unconditionally `initdb` on both targets.
- **Existing EBS snapshots are deleted as part of this migration.** The operator
  confirmed there is no AWS data to preserve, so there is no bridge step and no
  rollback copy. Anyone running this spec against a cluster whose data does
  matter must take a dump *before* starting, because after step 3 there is no
  code left that can read a snapshot.
- `persistent-down.sh` stops naming snapshots in its confirmation and starts
  naming the bucket's contents — after this spec the bucket holds the only copy
  of the database on both targets.
- Keep the `ebs-retain` StorageClass. It is unrelated to Postgres.

## 5. Files/components affected

Modified: `scripts/argo-up.sh`, `scripts/argo-down.sh`,
`scripts/lib/persistent-ebs-artifacts.sh`, `scripts/persistent-down.sh`,
`gitops/templates/platform/shared/postgres/cluster.yaml`,
`gitops/bootstrap/templates/root-application.yaml`, `gitops/values.yaml`,
`scripts/gitops-render-check.sh`, `tests/golden/gitops-aws/`,
`docs/adr/0013-postgres-volumesnapshot-recovery.md`, `docs/architecture.md`,
`docs/aws-platform-design.md`.

Deleted: `gitops/templates/platform/aws/postgres/recovered-snapshot.yaml`,
`gitops/templates/platform/aws/ebs-csi/volumesnapshotclass.yaml`,
`gitops/templates/platform/aws/ebs-csi/snapshot-controller.yaml`.

## 6. Implementation steps

1. Enable the jobs on AWS. Confirm a dump lands in S3 using Pod Identity, with
   the snapshot path still in place — one mechanism proven before the other is
   removed.
2. Write rows, one full `make down`/`make up`, confirm the restore read S3 and
   not the snapshot.
3. Delete the snapshot code, manifests and values. Delete the existing EBS
   snapshots.
4. Regenerate `tests/golden/gitops-aws/` with `MODE=update` in its **own
   commit**, so the removals are reviewable as a diff rather than buried.
5. Second full `make down`/`make up` with the snapshot path gone entirely.
6. Amend ADR 0013 with a superseded-by note in the blockquote convention it
   already uses at the top of the file. Correct `docs/architecture.md` §13 and
   §16, which still describe EBS retention as the persistence mechanism, and
   §10a's Civo qualifier, which will no longer be an interim state.

Step order is load-bearing: the new mechanism is proven on AWS in steps 1-2
while the old one is still available to fall back to, and only then deleted.

## 7. Dependencies and blockers

CIVO-120 proves the mechanism end to end on Civo. CIVO-180 supplies the bucket,
the Pod Identity role and the image. Nothing blocks.

## 8. Acceptance criteria

- Two full AWS destroy/recreate cycles restore real rows from S3, with row
  counts recorded.
- `git grep` finds no remaining reference to `recoverySnapshotHandle`,
  `volumeSnapshot`, `VolumeSnapshotContent`, `snapshot-controller` or
  `external-snapshotter` outside ADR 0013 and the status history of specs that
  describe the retired design.
- The regenerated golden baseline's diff contains exactly the intended removals
  and nothing else — reviewed object by object, not by file count.
- `PROVIDER=civo make -n up` output is unchanged, and one Civo cycle still works
  after the change.
- The documents state one backup mechanism for both providers, and ADR 0013
  says it has been superseded.
- The loosening of AWS's teardown gate is recorded in the ADR amendment, not
  only in this spec.

## 9. Validation

Offline: `make gitops-check` with `MODE=update` once, then clean;
`shellcheck`; `git grep` for the retired identifiers.

Real cloud: two AWS cycles. EKS control plane plus nodes for the session, call
it 3-5 USD. One Civo cycle as a regression check, under 1 USD.

## 10. AWS regression protection

This spec *is* an AWS change, so the golden diff cannot be the gate — it is
regenerated deliberately. The gate is instead the two recorded down/up cycles
with real row counts, and the requirement that step 4's diff is reviewed key by
key. The Civo regression check is the mirror of the usual rule: Civo must be
provably unaffected.

## 11. Rollout and rollback/recovery

Data risk: high, and one-way. After step 3 no code can read an EBS snapshot, and
step 3 deletes them. The mitigation is step order — the S3 path is proven on AWS
in steps 1-2 before anything is removed — not a rollback. Reverting the commits
restores the code but not the deleted snapshots.

## 12. Risks and unresolved questions

- **AWS gains a data-loss override it did not have.** Sharing one teardown gate
  means `CI_TEARDOWN_ALLOW_DATA_LOSS=1` now works on AWS. Whether that is
  acceptable, or whether the shared gate should refuse the override when the
  target is AWS, is a decision this spec must make explicitly rather than
  inherit.
- Dump and restore duration on AWS may differ from Civo's measured number.
  Re-measure rather than assuming the Civo timeout transfers.
- `docs/architecture.md` §13 and §16 and `specs/000-constitution` §4 all still
  describe persistence as a property of volume reclaim policy. That stopped
  being true on AWS at ADR 0013 and on Civo at CIVO-115; this spec is the point
  where no target's Postgres volume is retained at all. The constitution is out
  of scope to amend here, but the divergence should be named.
- Deleting the snapshots is irreversible and is done on the operator's stated
  confirmation that no AWS data matters. Re-confirm at execution time rather
  than relying on this sentence.

## 13. Definition of done

- [ ] Two AWS cycles with row-count evidence, one before and one after removal
- [ ] Snapshot code, manifests and existing snapshots all gone; golden
      regenerated in its own commit and reviewed object by object
- [ ] ADR 0013 amended; architecture and AWS design docs corrected
- [ ] The override-on-AWS decision made and recorded
- [ ] One Civo cycle proving no regression
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as READY, M2, depending on CIVO-120 and CIVO-180.

- 2026-09-11 — rescoped as the third task of the S3-backup effort. Line-number
  citations in §3 were corrected against the current files; the earlier ones
  pointed at pre-CIVO-115 positions. The operator confirmed no AWS Postgres data
  needs preserving, so the optional bridge step was removed and existing EBS
  snapshots are now deleted as part of the migration rather than kept for
  rollback — which also removes the rollback, stated plainly in §11. Two
  consequences the earlier draft did not name were added: AWS inherits the
  `CI_TEARDOWN_ALLOW_DATA_LOSS` override by sharing one gate, and
  `persistent-down`'s confirmation text must change because the bucket becomes
  the only copy of the database on both targets.
