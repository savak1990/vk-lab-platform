---
id: "HETZ-120"
title: "CloudNativePG on Hetzner with data surviving make down and make up"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "The mechanism is decided and implemented by CIVO-180/120; this spec proves it on ARM with two real cycles"
effort_estimate: "One session (4–6 h) including two full down/up cycles"
estimate_confidence: "medium"
depends_on: ["HETZ-115", "HETZ-182", "CIVO-120", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-120 — CNPG on Hetzner with persistence

## 1. Outcome and rationale

Rows written before `PROVIDER=hetzner make down` are present after
`make up`. The data of record is a logical dump in the project's S3 bucket
(`vk-hetzner-lab-backups`), written by the shared backup job from
CIVO-180 and loaded by its restore Job. The hcloud volume is disposable.

Read `specs/civo/120-cnpg-on-civo-persistence/spec.md` first. The
mechanism is identical; this spec adds the ARM image, the Hetzner bucket
and the Hetzner evidence.

## 2. Scope and non-goals

In scope:
- The `postgres.backup.*` values for `target: hetzner`.
- The `pgbackup` Roles Anywhere consumer for the Hetzner project.
- Two full down and up cycles that carry real rows on Hetzner.
- Removing the shortened `WATCH_SECONDS` on hetzner once cycles are stable.

Not in scope:
- The bucket module, the image, the CronJob, the restore Job (CIVO-180).
- Retained-volume rebind. Hetzner volumes outlive servers only if the
  reclaim policy were `Retain`; with `Delete` the volume dies with the PVC.
  The dump is the persistence. This is the same decision as ADR 0031.
- Replicas.

## 3. Current state / evidence

- CIVO-180 delivers `terraform/live/persistent/backups` (bucket
  `${project}-backups`), `images/pg-backup`, the CronJob, the `PostSync`
  restore Job and the `aws-config` ConfigMap gated on
  `awsIdentity.mode == rolesAnywhere`. `PROVIDER=hetzner make persistent-up`
  creates `vk-hetzner-lab-backups` with no change.
- HETZ-182 publishes `pg-backup` for `linux/arm64`. Without it the CronJob
  pod fails to pull on CAX21 (`no matching manifest`).
- HETZ-085 issues the `pgbackup-ra-cert` Certificate and the
  `${project}-ra-pgbackup` role for the Hetzner project.
- `scripts/argo-up.sh` keeps `WATCH_SECONDS=300` on non-AWS providers
  (CIVO-120 §12).

## 4. Design and contracts

- Values on hetzner: `postgres.backup.enabled: true`,
  `postgres.backup.bucket: vk-hetzner-lab-backups`, schedule `0 3 * * *`,
  `retentionDays: 14`, `awsIdentity.mode: rolesAnywhere`. The
  `aws-config` ConfigMap renders with the Hetzner project's trust anchor,
  profile and `pgbackup` role ARNs from SSM through `argo-up`.
- Teardown: the dump gate in `scripts/argo-down.sh` runs on hetzner through
  the non-AWS branch (HETZ-016). It creates a one-off Job from the
  CronJob, waits 600 s, and fails closed unless
  `CI_TEARDOWN_ALLOW_DATA_LOSS=1`.
- Bring-up: no backup logic in `argo-up`. The restore Job runs `PostSync`
  on the Postgres Application and loads the newest dump when the schema
  is empty.
- The backup pod is `arm64`. `aws_signing_helper` in the image is the
  arm64 binary. `aws sts get-caller-identity` from the pod must return the
  `pgbackup` role through Roles Anywhere over IPv4 egress (research.md,
  IPv6 row).

## 5. Files/components affected

`gitops/values.yaml` (hetzner block); `scripts/argo-up.sh`
(`WATCH_SECONDS` default for hetzner); this spec's evidence.

## 6. Implementation steps

1. Confirm CIVO-180 and HETZ-182 are `DONE` and the image digest in values
   is a manifest list with `linux/arm64`.
2. Run `PROVIDER=hetzner make up`. Confirm the CronJob exists in
   `cnpg-system` and its pod image resolves on a CAX21 node.
3. Trigger the CronJob once by hand:
   `kubectl -n cnpg-system create job --from=cronjob/postgres-backup manual-1`.
   Confirm the object under `s3://vk-hetzner-lab-backups/postgres/`.
4. Write rows through the e2e Postgres test or `psql`.
5. Run `make down` without the flag. Confirm the teardown dump completed
   and the object is in S3.
6. Run `make up`. Confirm the restore Job loaded the dump and the rows are
   present.
7. Repeat steps 5 and 6.
8. Re-sync Argo without a teardown. Confirm the restore Job exits
   successfully and changes nothing.
9. Failure path: scale the CronJob's image to a wrong digest, run
   `make down`. The gate must exit non-zero and leave the cluster running.
10. If every cycle reached `Synced/Healthy` inside 300 s, keep the short
    watch; if not, document the observed time and raise it for hetzner.

## 7. Dependencies and blockers

HETZ-115 (the Cluster), HETZ-182 (arm64 image), CIVO-120 (mechanism
proof on Civo), CIVO-180 (bucket, image, jobs).

## 8. Acceptance criteria

- Rows survive two down and up cycles on Hetzner.
- A re-sync without a teardown does not touch existing data.
- The teardown gate fails closed on a failed dump.
- `aws sts get-caller-identity` in the backup pod returns the `pgbackup`
  role; no permanent AWS key exists in the cluster, the repo, or SSM.
- `cluster-down` never touches the bucket; `persistent-down` empties it
  only after confirmation.
- The aws and civo golden diffs are empty.

## 9. Validation

Offline: golden diffs, kubeconform. Real cloud: two Hetzner cycles, about
0.30 EUR; S3 storage cents.

## 10. AWS regression protection

No shared template changes; values are hetzner-scoped. AWS keeps EBS
snapshots until CIVO-185. Civo: `PROVIDER=civo make -n down` byte-identical;
one civo `argo-down` dry run shows the same gate path.

## 11. Rollout and rollback/recovery

Data risk: yes. Test with disposable data only. Rollback: set
`postgres.backup.enabled: false` on hetzner. Dumps stay in the bucket
until `persistent-down`.

## 12. Risks and unresolved questions

- Dump and restore duration for 20 GiB on a CAX21 sets the teardown
  timeout. Measure once. ARM `pg_dump` throughput may differ from x86.
- A logical dump restores to the moment of the dump. The teardown gate
  bounds that window for planned teardowns; the daily schedule bounds it
  otherwise.
- The restore Job's empty-schema test is table count; unchanged from
  CIVO-180.
- Server deletion while the PVC still exists leaves the volume
  `available` and billing. Only the `cluster-down` sweep reaps it. HETZ-150
  verifies this path.

## 13. Definition of done

- [ ] Two cycles with row evidence; failure path; re-sync no-op
- [ ] `WATCH_SECONDS` decision recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
