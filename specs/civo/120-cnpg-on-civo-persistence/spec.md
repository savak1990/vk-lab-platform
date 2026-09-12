---
id: "CIVO-120"
title: "CloudNativePG on Civo with data surviving make down and make up"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "Data-safety path across cluster destruction; backup and restore must be reasoned through with failure modes"
effort_estimate: "One to two sessions (6–10 h) including three full down/up cycles"
estimate_confidence: "medium"
depends_on: ["CIVO-050", "CIVO-100", "CIVO-115", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-11"
completed: null
---

# CIVO-120 — CNPG on Civo with persistence

## 1. Outcome and rationale

Rows written to `vkdb` before `PROVIDER=civo make down` are present after the
next `make up`, with no operator intervention and no override variable. The data
of record is a logical dump in S3, written by a Job at teardown and read by a
Job at bring-up. The Civo volume stays disposable.

This retires the interim state CIVO-115 deliberately shipped, where every Civo
teardown destroyed the database and needed `CI_TEARDOWN_ALLOW_DATA_LOSS=1` to
proceed. After this spec that variable stops being a routine part of the
operator's command line and goes back to meaning what its name says.

## 2. Scope and non-goals

In scope:
- The backup and restore job manifests, built on CIVO-180's image and identity.
- Rewriting `civo_backup()` from a refusal into a real backup.
- A restore step in `argo-up`, and the empty-schema logic that makes it
  idempotent.
- Retention: the newest two dumps, enforced by the backup job.
- Three full down/up cycles carrying real rows, plus the failure paths.

Not in scope:
- The bucket, the IAM, the image and the certificate (CIVO-180).
- Switching the AWS target to this mechanism (CIVO-185). AWS keeps its EBS
  snapshot path untouched through this spec.
- Replicas. `instances: 1` is explicit: a second instance doubles volume and
  memory cost and protects nothing against cluster deletion, which is the only
  failure this platform actually plans for.
- Point-in-time recovery, permanently. ADR 0031 accepts that loss.
- A scheduled backup. See §4.

## 3. Current state / evidence

- The `Cluster` renders on Civo today, from
  `gitops/templates/platform/shared/postgres/cluster.yaml`, delivered by
  CIVO-115. Storage is `civo-volume`, 20 Gi, reclaim `Delete`. Bootstrap is
  always `initdb` on Civo — there is no recovery branch and no snapshot handle,
  because Civo's CSI driver implements no snapshot RPC at all.
- `civo_backup()` already exists at `scripts/lib/provider.sh:107-120`. CIVO-115
  shipped it as a fail-closed gate: if any CNPG `Cluster` exists it aborts the
  teardown unless `CI_TEARDOWN_ALLOW_DATA_LOSS=1`. **This spec rewrites that
  function; it does not add it.** Earlier drafts described it as new.
- `argo-up.sh` has no Postgres logic on the Civo branch.
  `civo_recovery_handle()` (`provider.sh:99-102`) returns an empty string
  unconditionally and exists only so the AWS and Civo branches share a shape.
- The AWS target already implements exactly the lifecycle this spec wants, with
  a different storage mechanism: `aws_cnpg_backup_and_prune`
  (`argo-down.sh:86-147`) backs up at teardown and prunes to the newest two;
  `aws_resolve_snapshot` (`argo-up.sh:296-328`) restores the latest at bring-up.
  The shape is proven. Only the artifact changes.
- `tests/e2e/postgres_test.go` already targets cluster `lab-postgres` and Secret
  `lab-postgres-app`.

## 4. Design and contracts

**Backups run at teardown, not on a schedule.** The platform is disposable and
spends most of its time destroyed, so a daily timer would mostly fire against a
cluster that does not exist, while the backup that actually matters is the one
taken immediately before the data is deleted. This mirrors what AWS has done
since ADR 0013. An earlier draft of CIVO-180 specified `0 3 * * *`; that is
dropped.

**Pod specs live in GitOps; scripts only pull the trigger.** Two CronJobs in
`cnpg-system`, `postgres-backup` and `postgres-restore`, both `suspend: true`,
both gated on `.Values.postgres.backup.enabled`, on the same sync-wave on both
targets. The scripts run `kubectl create job --from=cronjob/<name>`. Argo keeps
ownership of the Kubernetes resource, the script owns only the moment — the same
split `argo-down` already uses when it creates a CNPG `Backup` CR. Both
`jobTemplate`s set `ttlSecondsAfterFinished`: a Job created this way carries no
Argo tracking label, so nothing else will ever reap it.

**Backup job.** `pg_dump --format=custom --no-owner --no-privileges` piped to
`aws s3 cp - s3://$BUCKET/postgres/$CLUSTER-$(date -u +%Y%m%dT%H%M%SZ).dump`.
Then, and only then, list the prefix and delete everything but the newest two
keys.

- `set -o pipefail`, and the upload is verified to exist with non-zero size
  before anything is deleted. `aws s3 cp -` reads stdin to EOF, so a `pg_dump`
  that dies part-way still commits a truncated object under the newest key; a
  prune that trusted key order alone would then delete the last good copy.
- On any failure the partial key is removed, so a failed backup leaves the
  prefix exactly as it found it.

**Retention is the newest two keys**, enforced here rather than by an S3
lifecycle rule, because lifecycle expiry is age-based and cannot express a
count. Two is what AWS already keeps.

**"Newest" means the newest key, not the newest `LastModified`.** Keys carry a
sortable UTC stamp, and a server-side copy — which CIVO-186 performs — rewrites
`LastModified` while preserving the name. This resolves the open question
CIVO-186 §12 raised.

**Restore runs from `argo-up`, not as an Argo hook.** `CLAUDE.md` treats hooks
as the exception and specifically warns that a hook caught mid-sync can hold a
sync operation open and deadlock the teardown cascade. A script step also puts
restore at the same boundary the AWS snapshot logic already occupies, and gives
`make up` a line saying what it restored. An earlier draft specified a
`PostSync` hook; that is dropped.

**Wait for the database, not for Argo.** A healthy root Application does not
mean Postgres accepts connections — `initdb` finishing and the `-rw` Service
having endpoints are separate moments. `argo-up` waits on
`kubectl wait --for=condition=Ready cluster/lab-postgres -n cnpg-system` before
creating the restore Job, and the job itself opens with a bounded `pg_isready`
loop.

**Restore job decision table**, evaluated as the `vkdb` owner against `vkdb`'s
`public` schema:

| Tables | Newest dump | Action |
|---|---|---|
| > 0 | any | Exit 0, touch nothing. Makes re-syncs idempotent |
| 0 | exists | Download and `pg_restore`. A failure exits non-zero and leaves the cluster up but visibly unhealthy — ADR 0031 forbids a silent fall back to an empty database |
| 0 | none | Exit 0 |

That last row is the genuinely fresh environment, and it is a deliberate,
narrow exception to ADR 0031's no-silent-fallback rule: an empty bucket is not
a failed restore, it is a first bring-up. The exception is exactly "the list
call succeeded and returned nothing".

**A failed list is not an empty bucket.** If `aws s3 ls` fails, the job exits
non-zero rather than treating the error as "no dump". `aws_resolve_snapshot`
already draws this distinction on AWS (`argo-up.sh:296-301`); without it an IAM
misconfiguration on a first bring-up is indistinguishable from a fresh
environment, and the operator silently gets an empty database.

**Teardown gate.** `civo_backup()` creates the backup Job, waits, and prunes.
On failure or timeout it exits non-zero and leaves the cluster running, unless
`CI_TEARDOWN_ALLOW_DATA_LOSS=1`. The variable name is fixed verbatim by this
spec, CIVO-180 and CIVO-115 — do not invent a new one. The difference from
CIVO-115's version is that the default path now succeeds.

## 5. Files/components affected

New: `gitops/templates/platform/shared/postgres/backup-cronjob.yaml` and
`restore-cronjob.yaml`.

Modified: `scripts/lib/provider.sh` (`civo_backup` rewritten),
`scripts/argo-up.sh` (restore step, `ARGO_UP_RESTORE_TIMEOUT`, bucket name read
from SSM in the existing batched `get-parameters` call), `gitops/values.yaml`
(`postgres.backup.*`), `scripts/gitops-render-check.sh`
(`CronJob__cnpg-system__postgres-backup` and
`CronJob__cnpg-system__postgres-restore` added to `REQUIRED_OBJECTS_CIVO`).

The render-check additions are not optional bookkeeping: without them the check
passes vacuously if the `postgres.backup.enabled` gate is wrong in either
direction. That was CIVO-115's lesson.

## 6. Implementation steps

1. Confirm CIVO-180 is `DONE` — bucket, role, certificate and image digest all
   resolvable.
2. Write both CronJobs and the values. `make gitops-check`: the AWS golden diff
   must be empty, because `postgres.backup.enabled` is false on AWS.
3. Rewrite `civo_backup()`. `shellcheck`, `bash -n`.
4. Add the restore step to `argo-up.sh`. `shellcheck`, `bash -n`.
5. `PROVIDER=civo make up`. Write rows.
6. `PROVIDER=civo make down` with **no** override. Confirm it succeeds, the dump
   is in S3, and the message names the object.
7. `PROVIDER=civo make up`. Confirm the rows are back and `argo-up` says so.
8. Repeat 6 and 7 twice more, so that a third dump forces the first out and the
   prefix is proven to hold exactly two objects.
9. Re-sync Argo without a teardown; confirm the restore Job exits 0 and changes
   nothing.
10. Failure paths, each recorded: a backup that cannot reach S3 aborts the
    teardown and leaves the cluster running; a corrupted dump fails the restore
    loudly rather than leaving an empty database that looks healthy; a first
    bring-up against an empty prefix succeeds.

## 7. Dependencies and blockers

CIVO-050 provides the layout, CIVO-100 the database password, CIVO-115 the
running `Cluster` and the gate this rewrites, CIVO-180 the bucket, identity and
image.

## 8. Acceptance criteria

- Rows survive three down/up cycles with no override variable on any command.
- After the third cycle the prefix holds exactly two objects.
- A re-sync without a teardown leaves data untouched.
- A failed backup aborts the teardown with the cluster still running and the
  prefix unchanged — no truncated object, and the previous dumps still present.
- A corrupted dump fails the restore visibly; the cluster does not come up
  pretending to be empty.
- A genuinely first bring-up against an empty prefix succeeds and says why.
- `cluster-down` never touches the bucket. `persistent-down` empties it only
  after its explicit confirmation.
- The AWS golden diff is empty, and one AWS down/up cycle still restores from
  its EBS snapshot.
- `PROVIDER=aws make -n up` output is unchanged.

## 9. Validation

Offline: `make gitops-check`, `shellcheck`, `bash -n`, kubeconform.

Real cloud: three Civo cycles, well under 1 USD in total, plus one AWS cycle to
prove the untouched path still works. No Let's Encrypt production order is
spent; the existing certificate round-trips through SSM, and the SSM parameter
holding it must not be deleted before this spec is `DONE`.

## 10. AWS regression protection

`postgres.backup.enabled` stays false on AWS for every commit in this spec, so
both new manifests render to nothing there and the golden diff proves it.
`scripts/argo-up.sh` and `scripts/lib/provider.sh` are shared by both targets:
the restore step must be Civo-gated, and the AWS branch re-read for ordering
assumptions before merge. One AWS down/up cycle is recorded as evidence, not
assumed.

## 11. Rollout and rollback/recovery

Data risk: yes — this spec is the data path. Test with disposable rows only
until the third cycle passes. Rollback is reverting the commits, which returns
Civo to CIVO-115's behaviour: teardown refuses unless the override is set. The
bucket and its dumps survive a rollback, because they belong to the persistent
stack.

## 12. Risks and unresolved questions

- **The dump and restore duration sets the teardown timeout** and is unmeasured.
  Start generous, record the real number on the first cycle, tighten afterwards.
- **The empty-schema probe is the single highest-risk line in the spec.** It
  must run as the `vkdb` owner against `vkdb`'s `public` schema. Counting
  against `postgres`, or as a superuser, or without the schema qualifier, gives
  an answer that looks right and silently skips a restore.
- A logical dump restores to the moment of the dump. With backups taken only at
  teardown, an unplanned cluster loss costs everything since the last teardown.
  That is an accepted property of a disposable lab, not an oversight — but it is
  a real change from a daily schedule and belongs in the operator's mental model.
- **`persistent-down` now destroys the only copy of the database.** It already
  demands explicit confirmation; that confirmation's wording must name the
  bucket's contents, not only the SSM parameters and volumes it names today.
- **Update (2026-09-09, from CIVO-060):** `scripts/argo-up.sh` still shortens
  `WATCH_SECONDS` to 300s on civo, deliberately, because a healthy `root` was
  observed on one run rather than proven across cycles. This spec runs at least
  three civo cycles and is the natural place to confirm `Synced/Healthy` is
  reached reliably and drop the shortened default — but the restore step added
  here runs *after* that watch, so budget for it separately rather than folding
  it into the same number.

## 13. Definition of done

- [ ] Both jobs, the rewritten gate and the restore step in place
- [ ] Three cycles with row-count evidence; retention proven at exactly two
- [ ] All three failure paths recorded, including the fresh-environment case
- [ ] One AWS cycle recorded; golden diff empty
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as BLOCKED on CIVO-020.

- 2026-09-06 — kubernetes-architect review: `csi.civo.com` advertises no
  `CREATE_DELETE_SNAPSHOT` or `CLONE_VOLUME` capability
  (https://github.com/civo/civo-csi/blob/master/pkg/driver/controller_server.go).
  Snapshot and PVC-datasource recovery dropped; redesigned around object-store
  backups; blocker removed; status READY with new dependency CIVO-180.

- 2026-09-06 — user decision: persistence moves from object-store barman backups
  to shared logical dumps in S3. The Civo Object Store bills a 500 GB minimum;
  S3 bills bytes stored.

- 2026-09-11 — CNPG Cluster delivery split out to CIVO-115 (runs on civo with
  disposable data); this spec keeps the persistence proof.

- 2026-09-11 — rescoped and corrected. This spec absorbed the backup and restore
  jobs and the lifecycle wiring from CIVO-180, which now delivers only the
  bucket, identity and image. Stale references to a snapshot-era design were
  removed from §5 — `civo_recovery_handle`, a `persistent-civo-artifacts.sh`
  that was to mirror the EBS one, and a `persistent-down` artifact sweep — all
  of which contradicted this spec's own §4. The restore trigger moved from an
  Argo `PostSync` hook to an `argo-up` step; the backup schedule became
  teardown-only; `civo_backup()` is now described as a rewrite of the function
  CIVO-115 shipped rather than a new addition; and the fresh-environment,
  failed-list and truncated-upload cases were specified, none of which the
  earlier text covered.
