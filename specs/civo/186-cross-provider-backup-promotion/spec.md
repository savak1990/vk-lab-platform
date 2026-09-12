---
id: "CIVO-186"
title: "Cross-provider backup promotion: restore either target from the other target's dumps"
status: "READY"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One script and a Make target; the credential path and the restore contract are already decided by CIVO-180"
effort_estimate: "Half a session (2-3 h) plus one AWS and one Civo cycle"
estimate_confidence: "high"
depends_on: ["CIVO-180", "CIVO-185"]
blocked_by: []
supersedes: []
created: "2026-09-07"
updated: "2026-09-12"
completed: null
---

# CIVO-186 — Cross-provider backup promotion

## 1. Outcome and rationale

An operator writes rows on one provider, destroys that cluster, brings up
the other provider, and finds the same rows. The command is

    make backup-promote FROM=aws TO=civo

It copies the newest PostgreSQL dump from one project's backup bucket to
the other's. The next `make up` on the destination restores it through
the restore path CIVO-120 already ships.

This proves the data layer is coupled to neither cloud. It is a stronger
statement than the constitution's existing destroy-and-recreate loop,
which only proves data survives within one provider.

Two decisions already taken make this nearly free. CIVO-120 dumps with
`pg_dump --format=custom --no-owner --no-privileges`, and those two flags
strip the role and ACL ownership that would otherwise bind a dump to the
cluster that produced it. CIVO-120's restore path decides for itself
whether the schema is empty and loads the newest dump if it is, so it
does not care which cluster wrote the object. No restore-side change is
needed.

## 2. Scope and non-goals

In scope:

- `scripts/backup-promote.sh` and one Make target.
- A server-side S3 copy between the two projects' backup buckets, run with the operator's own credentials.
- A PostgreSQL major-version guard that refuses a promotion that cannot restore.
- One recorded drill in each direction.

Not in scope:

- One backup bucket shared between the two projects. Rejected in §4.
- Any cluster-side cross-project IAM, Roles Anywhere consumer, or policy widening.
- Scheduled or automatic promotion. This is a deliberate operator action.
- Point-in-time recovery. ADR 0031 already accepts its loss.
- Migration between PostgreSQL major versions. The guard refuses instead.

## 3. Current state / evidence

- `scripts/lib/provider.sh:9,17` sets `PROJECT_NAME` to `vk-civo-lab` or `vk-lab-platform`. `terraform/live/root.hcl:8` reads it into `local.project`. CIVO-180 §4 names the bucket `${project}-backups`, so the two targets have two buckets, in one AWS account, under two projects.
- CIVO-180 §4 fixes the object layout: `postgres/${cluster}-${YYYYMMDDTHHMMSSZ}.dump`, one flat prefix per bucket. CIVO-120 §4 writes it with `pg_dump --format=custom --no-owner --no-privileges`.
- Neither target's cluster holds an AWS identity (CIVO-180 §4): the lifecycle script presigns a URL and the Job speaks plain HTTP through it. That makes this spec's "operator's own credentials" framing the *only* credential model in play, rather than a second one alongside a cluster identity.
- CIVO-120 §4: the restore job counts tables, and when the count is zero and a dump exists it downloads the newest **key** and runs `pg_restore`. When the count is not zero it exits successfully without touching data. (This contract moved from CIVO-180 to CIVO-120 on 2026-09-11.)
- CIVO-120 §4: the backup job keeps the newest two keys under `postgres/` and prunes the rest. There is no lifecycle rule on the bucket — S3 expiry is age-based and cannot express a count.
- The AWS target backs up with ADR 0013's `VolumeSnapshot` until CIVO-185 lands. An EBS snapshot is not readable from Civo, so CIVO-185 is a hard gate, not a preference.
- `terraform/live/persistent/` currently holds `acm`, `route53`, `secrets`, `vpc`. There is no `backups` unit and no `s3-backups` module yet, so no dump exists on either target today.
- ADR 0027 states that a leaked Civo credential cannot reach the AWS project's state or secrets. ADR 0030 states that a `CIVO_TOKEN` compromise transitively reaches every AWS role's permissions through the CA-key path.

## 4. Design and contracts

- `make backup-promote FROM=<aws|civo> TO=<aws|civo>` dispatches to `scripts/backup-promote.sh`. `FROM` and `TO` must differ and must both be known providers.
- The script resolves each side's bucket by reading `PROJECT_NAME` for that provider through the existing `scripts/lib/provider.sh` mapping. Bucket names are never hardcoded.
- **Credentials are the operator's own** — the same identity that runs `make persistent-up`, which already spans both projects because ADR 0027 puts them in one AWS account. The script creates no IAM resource, adds no Roles Anywhere consumer, and grants no cluster any cross-project access. ADR 0027's isolation statement stays literally true.
- **The copy is server-side.** `aws s3 cp s3://<src> s3://<dst>` between two buckets in one account never streams the object through the operator's workstation, so the plaintext database contents do not land on local disk.
- **The promoted object is renamed with a fresh UTC timestamp**, keeping the source cluster name: `<src-cluster>-<promoted-at>.dump`. This makes the object unambiguously newest whether the restore Job orders by the timestamp in the key or by S3 `LastModified`. Provenance is recorded in object metadata (`promoted-from=<src-project>`, `promoted-source-key=<original key>`), not in the name, so key ordering stays intact.
- **Version guard.** The script reads the PostgreSQL major version each provider renders and refuses when they differ, naming both versions. CIVO-180 §4 pins one `postgres.imageName` value that feeds both the server and the dump container, so client/server skew cannot happen *within* a target; this guard extends the same protection *across* targets, where nothing else enforces it.
- **Empty-schema warning.** The restore Job no-ops when the destination database already has tables. The script says so explicitly on success: a promotion takes effect on the next `make up` of a cluster whose database is empty, and does nothing to a populated one.
- **Freshness guard.** The script refuses when the destination bucket already holds a dump newer than the source object, unless `--force` is given, so a promotion cannot silently lose newer data.
- The script prints the plan — source key, size, age, destination key, both versions — and requires confirmation unless `-y` is passed.
- Ownership: this spec adds a script and a Make target only. No Terraform resource, no Argo resource, no `gitops/` change.

Rejected: **one bucket shared by both projects, with per-provider prefixes and read-all access.** It would automate a rare, deliberate operation at the cost of a standing weakening of ADR 0027 — through ADR 0030's CA-key path, a `CIVO_TOKEN` compromise would then read the AWS lab's database dumps. An operator-run copy buys the same capability with no standing permission at all.

## 5. Files/components affected

- `scripts/backup-promote.sh` (new).
- `Makefile` (one target).
- `scripts/lib/provider.sh` (a bucket-name helper, if CIVO-120 did not already add one).
- `docs/architecture.md` (one line recording the capability).
- `specs/civo/README.md` index and `specs/civo/roadmap.md`.

## 6. Implementation steps

1. Add the bucket-name helper and the script. Run `shellcheck`.
2. Add the Make target. Confirm `make -n up` and `make -n down` output is unchanged for both providers.
3. Write rows on AWS, take a dump, run `make down`.
4. Run `make backup-promote FROM=aws TO=civo`. Confirm the object appears in the Civo project's bucket with the metadata and the fresh timestamp.
5. Run `PROVIDER=civo make up`. Confirm the restore Job loads the dump and the row counts match.
6. Repeat steps 3 to 5 in the opposite direction.
7. Run the negative tests: mismatched major versions, same `FROM` and `TO`, and a destination holding a newer dump.

## 7. Dependencies and blockers

CIVO-185 is the hard gate: until the AWS target backs up with logical
dumps, there is no AWS object a Civo cluster can read, and no AWS restore
Job to receive a Civo object. CIVO-180 supplies the two buckets and the
object layout; CIVO-120 supplies the dump format and the restore path.

## 8. Acceptance criteria

- Rows written on AWS are present on Civo after a destroy, a promotion and a `make up`, with matching row counts.
- The same holds in the Civo to AWS direction.
- The version guard refuses a promotion when the two targets' PostgreSQL majors differ, and names both versions.
- The freshness guard refuses when the destination holds a newer dump, and `--force` overrides it.
- No IAM role, policy, Roles Anywhere consumer or Kubernetes object is created by this spec. A `git grep` over the diff proves it.
- The copy is server-side: no dump file is written to the operator's working directory during a promotion.
- `make -n` output for `up` and `down` is unchanged on both providers, and the AWS golden gitops diff is empty.

## 9. Validation

Offline: `shellcheck`, the `make -n` comparison, and the golden diff.
Real cloud: one AWS cycle and one Civo cycle at the normal cost of each
lab for the window, plus a few cents of S3 requests. The copy itself is
server-side and transfers no data out of AWS.

## 10. AWS regression protection

The change is additive — a new script and a new target. No existing
script path, manifest or Terraform resource is modified, so the `make -n`
comparison and the empty golden diff are the protection. The AWS drill in
§6 exercises the AWS restore path that CIVO-185 introduced, and is
evidence for that path as well as this one.

## 11. Rollout and rollback/recovery

Roll back by deleting the script and the Make target. Objects already
promoted are ordinary dumps in the destination bucket and are pruned by the
next two backups on that target, without operator action.

## 12. Risks and unresolved questions

- **Resolved (2026-09-11):** the restore job selects the newest **key**, not the newest `LastModified` — fixed by CIVO-120 §4 precisely because a server-side copy rewrites `LastModified` while preserving the name. The fresh-timestamp naming in §4 is therefore load-bearing, not cosmetic: a promoted object must sort last.
- **Retention is a count, not an age.** The 14-day lifecycle rule this bullet assumed was dropped: CIVO-120 keeps the newest two dumps and enforces it in the backup job, because an S3 lifecycle rule cannot express a count. So the promotion window is bounded by teardowns, not by days — two more teardowns on the source target and the dump you meant to promote is gone, however recently it was written. A longer-lived migration needs the operator to copy it somewhere durable first.
- Nothing else in the platform pins the two targets to the same PostgreSQL major version. This spec's guard detects drift but does not prevent it.
- A promoted dump carries real database contents into the other project. The projects share an AWS account, so this is not a cross-account transfer, but it is a deliberate crossing of the ADR 0027 project boundary and should be visible in the object metadata for exactly that reason.

## 13. Definition of done

- [ ] Script, Make target and helper in place; `shellcheck` clean
- [ ] One AWS to Civo drill and one Civo to AWS drill, with row-count evidence
- [ ] Negative tests recorded: version mismatch, same source and target, newer destination dump
- [ ] Architecture document line added
- [ ] Index and roadmap updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-07 — created as DRAFT. Raised by the operator while reviewing Civo backup storage: whether one set of dumps can serve whichever cluster is currently running. The design was chosen over a shared bucket to keep ADR 0027's isolation boundary intact. Promote to READY when the operator approves the design.
- 2026-09-07 — approved for development by the operator; promoted to READY. CIVO-185 still gates the start.

- 2026-09-12 — unchanged in substance, corrected in its references. CIVO-180's
  scope narrowed to the bucket, the presigning helper and the image pin, so the
  dump format and the restore path are cited to CIVO-120. The credential note in
  §3 was added because the presigned-URL model (ADR 0031 amendment, 2026-09-12)
  makes this spec's operator-credentials framing the platform's only credential
  model for backups rather than one of two.
