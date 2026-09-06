---
id: "CIVO-180"
title: "CNPG backups to object storage with a restore drill"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Known barman-cloud pattern; credential handling is the only design point"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-120"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-180 — CNPG backups to object storage

## 1. Outcome and rationale

Scheduled base backups and WAL archiving go to an S3-compatible object
store. This gives a recoverable database independent of Civo volume
snapshots. The restore is tested. A retained volume or snapshot is not a
backup.

## 2. Scope and non-goals

In scope:

- The barman-cloud plugin `ObjectStore`.
- A scheduled backup.
- Retention.
- A restore drill into a scratch cluster.
- Credentials through ESO.

Not in scope: cross-cloud migration of production data.

## 3. Current state / evidence

- The CNPG operator uses the 0.29.0 chart. The barman-cloud plugin `ObjectStore` uses `s3Credentials` secret refs (research.md).
- CNPG pods cannot run the Roles Anywhere sidecar. So AWS S3 through Roles Anywhere is not available in-pod.
- Civo Object Store: S3-compatible, static access keys, 500 GB increments (price to confirm).

## 4. Design and contracts

- Store choice: Civo Object Store (same provider, no egress). Store the static keys in SSM SecureString. ESO delivers them to a Secret `cnpg-backup-s3`. The alternative, AWS S3 with a dedicated static key, is rejected (constitution §5).
- Create an `ObjectStore` CR with `endpointURL`, `destinationPath s3://<bucket>/<project>/`, and `retentionPolicy 14d`. Create a daily `ScheduledBackup`. Turn WAL archiving on.
- Restore drill: bootstrap a second `Cluster` from the object store in namespace `cnpg-restore-test`. Verify the rows. Delete the cluster.

## 5. Files/components affected

`terraform/live/persistent-civo/object-store` *(proposed)* if Terraform supports it, else a manual step with an SSM record; `gitops/templates/platform/civo/postgres/backup.yaml`; an ESO ExternalSecret; the `lab-role` SSM path is already covered.

## 6. Implementation steps

1. Create the store and the keys. Write the SSM parameter. Sync through ESO.
2. Apply the ObjectStore and the ScheduledBackup. The first backup must be `completed`.
3. Run the restore drill. Record the result.

## 7. Dependencies and blockers

120 (CNPG on civo).

## 8. Acceptance criteria

- The daily backup completes. The WAL is archived. The restore drill succeeds with a row count match.
- The keys are never in Git. Rotation is documented.

## 9. Validation

Real cloud: the object store minimum billing for the test period (record it).

## 10. AWS regression protection

Civo-only files.

## 11. Rollout and rollback/recovery

Remove the backup config. The data is unaffected.

## 12. Risks and unresolved questions

- The object store minimum size cost may exceed the value for a lab. Decide after the price check.

## 13. Definition of done

- [ ] Evidence incl. restore; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
