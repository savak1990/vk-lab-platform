---
id: "SHARED-048"
title: "A Postgres database moves between providers without losing data"
status: "IN_PROGRESS"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "strongest"
model_rationale: "The code is small, but the failure mode is silent: a recovery that does not resolve renders initdb over a recoverable archive and reports healthy"
effort_estimate: "One session, plus three live bring-ups across three clouds"
estimate_confidence: "medium"
depends_on: ["CIVO-120", "HETZ-120", "CIVO-185"]
blocked_by: []
supersedes: []
created: "2026-09-24"
updated: "2026-09-24"
completed: ""
---

# SHARED-048 — A database moves between providers

## 1. Outcome and rationale

`RECOVER_FROM=s3://<bucket>/<generation>` makes a bring-up start from a backup
generation written by a **different** target. The rows survive the move.

The operator's framing, 2026-09-24: *"Imagine we started our startup on hetzner
k3s cloud and it became viral and we need to scale … we might want to migrate to
civo or aws without loosing data."*

Nothing about that scenario was supported. Each target read its own SSM pointer
and nothing else, so leaving a provider meant leaving the data.

## 2. Why this is nearly free

Three properties of the existing design do almost all the work.

**One object store for every target.** `objectstore.yaml:19` sets
`destinationPath: s3://<bucket>/` with no `endpointURL`. Civo and Hetzner do not
use Civo Object Store or Hetzner Object Storage — they write AWS S3 in
`eu-west-1` through IAM Roles Anywhere. The archive never lived on the provider
being left.

**One Postgres binary.** `gitops/values.yaml:87` digest-pins
`postgresql:18.4-system-trixie` in one place, with no per-target override.
Physical WAL recovery requires identical major versions. This pin is what makes
a cross-provider restore legal rather than merely attempted.

**One AWS account.** No `assume_role` appears anywhere in `terraform/live` or
`scripts/lib`. The buckets are SSE-S3 with no KMS key, and the bucket policy
(`postgres-backups/main.tf:28-52`) is a `Deny` on plaintext transport with no
principal allow-list.

The only true gap was that nothing let an operator name a source.

## 3. Scope and non-goals

In scope:

- `RECOVER_FROM`, validated offline before any cloud call.
- An import step that copies the named generation into this project's own
  bucket, and is a no-op when the prefix is already there.
- Three live bring-ups proving a database crosses two provider boundaries.

Not in scope:

- **RDS, or any non-CNPG target.** No `pg_dump`, `pg_restore` or
  `pg_basebackup` exists anywhere in `scripts`, `gitops`, `terraform` or
  `tests`. Physical recovery between CNPG clusters is the only mechanism this
  platform has. A migration to a managed service needs tooling that does not
  exist yet, and is a different spec.
- **Horizontal scaling.** `cluster.yaml:12` is `instances: 1` with no replicas.
  This spec moves data; it scales nothing. If viral growth is the real driver,
  replicas, connection pooling and storage sizing are the work.
- **Reading a foreign bucket in place.** Designed and rejected — see §5.
- **Any IAM change.** See §5.

## 4. The silent-`initdb` hazard

`cluster.yaml:30` selects the bootstrap branch:

```
{{- if and .Values.postgres.backup.enabled .Values.postgres.backup.recoverServerName }}
```

An empty `recoverServerName` renders `initdb`. The comment beneath it — *"No
initdb fallback: a loud failure beats silently wiping a recoverable database"* —
covers a **failed** recovery. It does not cover an **absent or unresolved**
handle.

That is the failure this spec must not introduce. A migration that resolves to
nothing would bring up an empty database, report healthy, and lose the data it
was asked to move.

Two mechanisms prevent it:

1. `require_valid_recover_from` refuses a malformed value offline, before any
   cloud call, and reports every problem in one pass.
2. `backup_import_generation` runs under `set -euo pipefail`. A copy from a
   source that does not exist aborts the bring-up rather than continuing with an
   unresolved handle.

Neither is a substitute for reading `.spec.bootstrap` on the live cluster, which
§8 requires.

## 5. Why copy rather than read across

barman keys everything under `<destinationPath><serverName>/`. Copying a
generation prefix into the target's own bucket preserves that layout exactly, so
the existing single `ObjectStore` resolves it with no chart change at all.

The alternative was designed in full and rejected. `cluster.yaml:49` points
recovery at `barmanObjectName: lab-postgres-backups` — the same `ObjectStore`
the cluster archives into. `serverName` is a parameter at each reference site,
so one store already serves two *prefixes*; but `destinationPath` lives only on
the store, so two *buckets* need two stores.

| | Copy (chosen) | Read across (rejected) |
|---|---|---|
| Chart change | none | new template, `cluster.yaml:49`, golden regeneration |
| Terraform change | **none** | wildcard bucket ARN in two modules |
| Unknowns | none | two `ObjectStore` objects in one namespace, unproven here |
| Cost at scale | duplicates the archive | reads in place |

**No IAM change is needed.** The copy runs with the operator's own credentials,
which already reach both buckets; the cluster itself only ever reads the bucket
it already owns. The rejected design would have widened
`rolesanywhere/main.tf:18` and `postgres-backup-pod-identity/main.tf:13` to
`arn:aws:s3:::*-postgres-backups`, giving every lab cluster `s3:DeleteObject` on
every other project's archive.

The trade is real and is accepted knowingly: copying duplicates the archive. At
lab size that is seconds and cents. At the size the motivating scenario implies,
reading in place would be the better mechanism, and this decision should be
revisited rather than assumed still correct.

## 6. Composition with generation pruning

`backup_prune_generations` protects both `$BACKUP_SERVER_NAME` and
`$RECOVER_SERVER_NAME` by name. After an import the recovered-from generation
genuinely is in `$BACKUP_BUCKET`, so it is protected for exactly as long as it
is the source, then ages out under the ordinary
`POSTGRES_BACKUP_KEEP_GENERATIONS` rule. No new code, and no special case.

## 7. Implementation

| Piece | Where |
|---|---|
| Guard and parse | `scripts/lib/require-valid-recover-from.sh` |
| Unit test | `tests/scripts/recover-from-test.sh`, 13 assertions |
| Import and branch | `scripts/argo-up.sh`, `backup_import_generation` and `backup_resolve_generation` |
| Operator surface | `Makefile`: `export RECOVER_FROM ?=`, a `require-valid-recover-from` target on `up`, `full-up` and `platform-up` |

`RECOVER_FROM` is deliberately not persisted. `backup_publish_server_name`
writes only `BACKUP_SERVER_NAME`, so the next bring-up on that target returns to
its own pointer with no extra code. The override applies to one bring-up.

No Helm value and no `--set` flag changed: `RECOVER_SERVER_NAME` already flowed
to the chart, and after the import the generation is in the bucket
`postgres.backup.bucket` already names.

## 8. Acceptance criteria

1. Rows written on Hetzner are readable on AWS, having passed through Civo.
2. On each recovering bring-up, `.spec.bootstrap` on the live `Cluster` shows
   `recovery` and no `initdb` key — **read, not inferred from a healthy pod**.
3. The imported generation prefix appears in the target project's own bucket.
4. The source project's bucket still lists that generation afterwards.
5. A second bring-up with the same `RECOVER_FROM` prints the skip message and
   does not re-copy.
6. A bring-up with no `RECOVER_FROM` recovers from that target's own pointer.
7. A malformed `RECOVER_FROM` exits non-zero before any cloud call.
8. `PROVIDER=aws|civo make -n up` differs from `origin/main` by exactly the one
   added guard line; `make gitops-check` reports no golden change.
9. `verify-no-leaks.sh` exits 0 on all three targets afterwards.

## 9. Operator procedure

```bash
# 1. Find the source generation.
aws s3 ls s3://vk-hetzner-lab-<region>-postgres-backups/

# 2. Bring the new target up from it.
RECOVER_FROM=s3://vk-hetzner-lab-<region>-postgres-backups/lab-postgres-<T> \
  PROVIDER=civo make full-up

# 3. Confirm the branch before trusting a row.
kubectl get cluster lab-postgres -n cnpg-system -o jsonpath='{.spec.bootstrap}'
```

**Never `make full-down` on the source until the new target is verified.**
`scripts/persistent-down.sh:123` empties the backup bucket and `:148` deletes
the generation pointer. `make down` leaves both intact.

`retentionPolicy` is `"2d"` (`values.yaml:99`), so a source archive older than
two days may already have been pruned by its own project. Migrate promptly, or
raise the retention before starting.

## 14. Evidence

Offline, 2026-09-24, on `origin/main` at `abdee9d`:

- `make scripts-check` — passes, including `recover-from-test.sh` (13/13).
- `make gitops-check` — passes; the aws golden baseline is unchanged, which is
  the mechanized proof that this needed no chart change.
- `make -n up` on all four targets differs from the base by exactly one line,
  the new guard.
- The guard refuses through both `RECOVER_FROM=x make ...` and
  `make ... RECOVER_FROM=x`, reporting both problems in one pass:

```
Refusing: invalid RECOVER_FROM
  - bucket 'b' is not a valid S3 bucket name
  - generation 'nonsense' must look like lab-postgres-20260101T000000Z
```

**Outstanding:** the three-hop live run (§8 criteria 1-6, 9). Recorded here
rather than claimed.
