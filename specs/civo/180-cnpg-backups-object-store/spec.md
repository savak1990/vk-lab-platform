---
id: "CIVO-180"
title: "CNPG backups to object storage with a restore drill"
status: "DRAFT"
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

Scheduled base backups and WAL archiving to an S3-compatible object store
give a recoverable database independent of Civo volume snapshots, with a
tested restore. A retained volume or snapshot is not a backup.

## 2. Scope and non-goals

In scope: barman-cloud plugin `ObjectStore`, scheduled backup, retention,
restore drill into a scratch cluster, credentials via ESO. Not in scope:
cross-cloud migration of production data.

## 3. Current state / evidence

- CNPG operator 0.29.0 chart; barman-cloud plugin `ObjectStore` uses `s3Credentials` secret refs (research.md).
- CNPG pods cannot run the Roles Anywhere sidecar, so AWS S3 via Roles Anywhere is not available in-pod.
- Civo Object Store: S3-compatible, static access keys, 500 GB increments (price to confirm).

## 4. Design and contracts

- Store choice: Civo Object Store (same provider, no egress) with static keys stored in SSM SecureString and delivered by ESO to a Secret `cnpg-backup-s3`; alternative AWS S3 with a dedicated static key is rejected (constitution §5).
- `ObjectStore` CR with `endpointURL`, `destinationPath s3://<bucket>/<project>/`, `retentionPolicy 14d`; `ScheduledBackup` daily; WAL archiving on.
- Restore drill: bootstrap a second `Cluster` from the object store in namespace `cnpg-restore-test`, verify rows, delete.

## 5. Files/components affected

`terraform/live/persistent-civo/object-store` *(proposed)* if Terraform supports it, else manual with SSM record; `gitops/templates/platform/civo/postgres/backup.yaml`; ESO ExternalSecret; `lab-role` SSM path already covered.

## 6. Implementation steps

1. Create the store and keys; SSM; ESO sync.
2. Apply ObjectStore/ScheduledBackup; first backup `completed`.
3. Restore drill; record.

## 7. Dependencies and blockers

120 (CNPG on civo).

## 8. Acceptance criteria

- Daily backup completes; WAL archived; restore drill succeeds with row count match.
- Keys never in Git; rotation documented.

## 9. Validation

Real cloud: object store minimum billing for the test period (record).

## 10. AWS regression protection

Civo-only files.

## 11. Rollout and rollback/recovery

Remove the backup config; data unaffected.

## 12. Risks and unresolved questions

- Object store minimum size cost may exceed value for a lab; decide after price check.

## 13. Definition of done

- [ ] Evidence incl. restore; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
