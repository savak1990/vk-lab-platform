---
id: "CIVO-180"
title: "Civo Object Store, backup credentials, and the barman-cloud plugin for CNPG"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Known barman-cloud pattern; credential handling and state exposure are the design points"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-025", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-180 — CNPG backups to object storage

## 1. Outcome and rationale

A Civo Object Store bucket exists for the project, its access keys reach
the cluster as a Kubernetes Secret through SSM and ESO, and the CNPG
barman-cloud plugin plus an `ObjectStore` CR are installed. This is the
persistence mechanism for CNPG on Civo (CIVO-120), because the Civo CSI
driver cannot snapshot or clone volumes.

## 2. Scope and non-goals

In scope:
- `terraform/live/persistent-civo/object-store` with `civo_object_store` and `civo_object_store_credential`.
- SSM `SecureString` parameters for the access key and secret key.
- ESO `ExternalSecret cnpg-backup-s3` in `cnpg-system`.
- The barman-cloud plugin Application (shared, gated by `postgres.backup.enabled`) and the `ObjectStore` CR on Civo.

Not in scope:
- The CNPG `Cluster`, scheduled backups, teardown backup, and restore drill (CIVO-120).
- AWS S3 as the store: CNPG pods cannot host the Roles Anywhere sidecar, and a static AWS key is forbidden by constitution §5.

## 3. Current state / evidence

- The CNPG operator uses the 0.29.0 chart. The barman-cloud plugin `ObjectStore` uses `s3Credentials` secret refs (research.md).
- CNPG pods cannot run the Roles Anywhere sidecar. So AWS S3 through Roles Anywhere is not available in-pod.
- Civo Object Store: S3-compatible, static access keys, 500 GB increments (price to confirm).

## 4. Design and contracts

- Bucket: `civo_object_store` named `${project}-cnpg`, minimum size 500 GB (Civo sizes in 500 GB steps, about 5.43 USD per month at the 2026-09-06 price), region `LON1`.
- Credential: `civo_object_store_credential` for the bucket. The access key and secret key land in Terraform state as sensitive values. This is accepted for the lab because the state bucket is per project, encrypted, and access-controlled; `decisions.md` records the trade-off. Alternative if the user prefers: create the credential by hand and commit it with `scripts/secret-encrypt.sh` as `secrets/<project>/cnpg-s3-access-key.enc` and `cnpg-s3-secret-key.enc`.
- SSM: `/${project}/persistent-civo/object-store/access_key_id` and `/secret_access_key` as `SecureString` with `alias/lab-secrets`; `/endpoint` and `/bucket` as `String`.
- IAM: the `${project}-ra-eso` role gains `ssm:GetParameter` on the two new parameter ARNs (CIVO-082 variable list).
- ESO: `ExternalSecret cnpg-backup-s3` in `cnpg-system` with keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`.
- Plugin: the barman-cloud plugin Helm chart or manifest as a shared Application at wave -1 next to the CNPG operator, gated by `postgres.backup.enabled`.
- `ObjectStore civo-object-store` in `cnpg-system`: `endpointURL` from values, `destinationPath: s3://${bucket}/${project}/`, `s3Credentials` referencing the Secret, `retentionPolicy: 14d`.

## 5. Files/components affected

`terraform/live/persistent-civo/object-store` *(proposed)* if Terraform supports it, else a manual step with an SSM record; `gitops/templates/platform/civo/postgres/backup.yaml`; an ESO ExternalSecret; the `lab-role` SSM path is already covered.

## 6. Implementation steps

1. Add the Terraform unit and module; apply with `PROVIDER=civo make persistent-up`; confirm the bucket and SSM parameters.
2. Add the IAM statement to the ESO role; re-apply the bootstrap unit.
3. Add the `ExternalSecret`, the plugin Application, and the `ObjectStore` CR; run `make gitops-check` (AWS golden diff empty).
4. `PROVIDER=civo make up`; confirm the Secret synced and the `ObjectStore` shows `Ready`.
5. Upload and delete a test object with the credential from a pod to prove access.

## 7. Dependencies and blockers

CIVO-025 (`persistent-civo` stack), CIVO-100 (ESO on Civo).

## 8. Acceptance criteria

- Bucket exists; credential works from inside the cluster; `ObjectStore` is `Ready`.
- Keys are never in Git, Argo manifests, or logs.
- AWS golden diff empty; no plugin or `ObjectStore` on AWS while `postgres.backup.enabled` is false.
- Bucket survives `cluster-down`; `persistent-down` deletes it only with confirmation.

## 9. Validation

Offline: Terraform fmt and validate, golden diff. Real cloud: bucket minimum billing during the test (about 0.18 USD per day).

## 10. AWS regression protection

Civo-only files.

## 11. Rollout and rollback/recovery

Destroy the unit with `persistent-down`. Deleting the bucket deletes all backups; the script requires confirmation.

## 12. Risks and unresolved questions

- The Civo Terraform provider's object-store credential resource attributes; confirm at implementation.
- Whether the 500 GB minimum is acceptable at about 5.43 USD per month; the user decides in `decisions.md`.

## 13. Definition of done

- [ ] Evidence incl. restore; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).

- 2026-09-06 — repurposed from P2 restore drill to the P1 M1 persistence prerequisite after the kubernetes-architect review; CIVO-120 now depends on this spec.

