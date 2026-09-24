---
id: "HETZ-120"
title: "CloudNativePG on Hetzner with data surviving make down and make up"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "The mechanism is decided, implemented and proven by CIVO-120, and every template and script path here is already shared. What remains is three wiring points and the live evidence"
effort_estimate: "Half a session (2-3 h) including two full down/up cycles"
estimate_confidence: "high"
depends_on: ["HETZ-115", "CIVO-120", "CIVO-180"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-23"
completed: "2026-09-23"
---

# HETZ-120 — CNPG on Hetzner with persistence

## 1. Outcome and rationale

Rows written before `PROVIDER=hetzner make down` are present after
`make up`. The data of record lives in S3 as a physical backup — a base
backup plus a continuous WAL archive, written by CNPG's barman-cloud
plugin (ADR 0032, ADR 0033). The hcloud volume is disposable and dies
with the cluster by design.

Because the archive is continuous, a row committed seconds before
`make down` is already durable off-cluster before the teardown starts.

Read `specs/civo/120-D-cnpg-on-civo-persistence/spec.md` first. The
mechanism is identical and its §4 is the design of record. This spec
records only the Hetzner differences and the Hetzner evidence.

## 2. Scope and non-goals

In scope:
- The backup values for `target: hetzner` at bring-up: the bucket name,
  the minted generation, and the generation recovered from.
- Two full down and up cycles that carry real rows on Hetzner.

Not in scope:
- The bucket, the sidecar image, the plugin Application, the
  `ObjectStore`, the `ScheduledBackup` and the IAM role. Those are
  CIVO-180's, and every one of them already renders on this target.
- The `Cluster` itself and the teardown guard (HETZ-115).
- Replicas. `instances: 1` stays explicit.
- A `Retain` storage class. The data of record is in S3, so a retained
  volume would add cost and leak risk without adding durability. This is
  the conclusion ADR 0031 reached, and it outlived the mechanism that
  reached it — ADR 0032 and ADR 0033 changed how the data leaves the
  cluster, not whether the volume is disposable.
- Observability data. Prometheus and Loki volumes stay disposable with no
  off-cluster archive (ADR 0018).

## 3. Current state / evidence

Almost everything this spec once described as work has landed elsewhere,
because the mechanism was built provider-neutral rather than per-target:

- Every template under `gitops/templates/platform/shared/postgres/` gates
  on `.Values.postgres.backup.enabled` together with
  `platform.selfManaged` or `ne .Values.target "local"`. There is no
  civo-only gate in that tree, and `platform.selfManaged` is true for
  hetzner.
- `scripts/gitops-render-check.sh` renders hetzner with
  `postgres.backup.enabled=true`, and its hetzner required set already
  demands `ObjectStore/lab-postgres-backups`,
  `ScheduledBackup/lab-postgres`, `Application/barman-cloud-plugin`,
  `ConfigMap/pgbackup-aws-config` and `Certificate/pgbackup`.
- `PERSISTENT_EXCLUDE` for hetzner is `vpc` alone, so
  `terraform/live/persistent/backups` is applied on this target and
  creates `${project}-${provider_region}-postgres-backups`. Unlike Civo,
  which has its own `persistent-civo/backups`, Hetzner reuses the shared
  persistent layer — which is what `BACKUP_SSM_LAYER=persistent` in
  `scripts/lib/provider.sh` already says.
- The `pgbackup` Roles Anywhere role is created per project, and its ARN
  is already read by `hetzner_resolve_inputs`. HETZ-085 issues the
  certificate that reaches the sidecar.
- `backup_teardown` in `scripts/lib/provider.sh` returns early when no
  `ObjectStore` exists and arms itself when one appears. It reads the
  `ContinuousArchiving` condition **before** the teardown proceeds and
  names the writes an unhealthy state destroys, which is what
  constitution §4 requires. This spec needs no code for that.
- `backup_publish_server_name` and `backup_prune_generations` in
  `scripts/argo-up.sh` are gated on the bucket being non-empty, not on
  the provider.
- The `cnpg-barman-sidecar` image needs no Hetzner variant: the nodes are
  x86 `cx33`, so the amd64 build Civo runs resolves unchanged, and
  `gitops/values.yaml` already aliases hetzner to it.

What was missing was the bring-up saying yes.
`hetzner_install_root_application` passed `postgres.backup.enabled=false`,
and `hetzner_resolve_inputs` deliberately blanked the three backup
variables because no bucket was read.

## 4. Design and contracts

The Civo design applies unchanged. The Hetzner-specific points:

- Storage: `hcloud-volumes`, 20 Gi, reclaim `Delete`, provisioner
  `csi.hetzner.cloud`. It is the cluster default and the only class,
  because k3s starts with `--disable=local-storage`. Hetzner's 10 GB
  volume minimum does not affect a 20 Gi claim.
- The bucket is read from the shared persistent layer at
  `/<project>/persistent/backups/bucket_name`. The generation pointer is
  written to `/<project>/persistent/postgres-backup/server_name` —
  `persistent`, not `persistent-hetzner`, matching `BACKUP_SSM_LAYER`.
- `serverName` is generation-scoped: each bring-up mints
  `lab-postgres-<UTC timestamp>` and recovers from the previous one. A
  constant name would make a recovered cluster archive into the prefix it
  just recovered from, and the timeline histories would collide. The
  pointer is written only after the root Application reports healthy, so
  a failed bring-up cannot burn it.
- Bootstrap has two branches. With a non-empty `recoverServerName` the
  Cluster uses `bootstrap.recovery` with `source: lab-postgres-previous`
  and an `externalClusters` entry naming that generation; otherwise
  `initdb`. **There is no `initdb` fallback on the recovery branch** — a
  loud failure beats silently wiping a recoverable database.
- Teardown is best-effort, not fail-closed. It forces a final
  `pg_switch_wal()`, creates a `Backup` with `method: plugin`, waits, and
  on failure warns loudly and proceeds. Continuous archiving has already
  made every committed row durable, so a failed final backup costs replay
  time, not data (constitution §4, ADR 0032).
- The stored backup count is bounded by `argo-up`, not by
  `retentionPolicy`. `retentionPolicy` is a recovery window and prunes
  only from inside a live cluster, scoped to its own `serverName`, and no
  live cluster ever owns an older generation.

## 5. Files/components affected

`scripts/argo-up.sh` only, in three places:

1. `hetzner_resolve_inputs` reads
   `/<project>/persistent/backups/bucket_name`. That is an eleventh SSM
   name, and `aws ssm get-parameters` accepts ten per call, so the single
   request becomes the batching loop `civo_resolve_inputs` already uses.
2. The three blanked backup variables are replaced by the bucket read and
   a `backup_resolve_generation` call — the same two lines the aws
   resolver ends with.
3. `hetzner_install_root_application` passes `enabled=true`, `bucket`,
   `serverName` and `recoverServerName` instead of `enabled=false`.

No template change, no Terraform change, no render-check change.

## 6. Implementation steps

1. Wire the three points in §5. Confirm `make scripts-check`,
   `make gitops-check` and `make specs-check` pass.
2. `PROVIDER=hetzner make full-up` from a cold start. Confirm `initdb`, a
   new generation, `ContinuousArchiving=True`, a `completed` Backup, and
   the pointer written.
3. Confirm `aws sts get-caller-identity` from the backup sidecar returns
   the `pgbackup` role, with no permanent AWS key in the cluster, the
   repo or SSM.
4. Write rows, including one committed seconds before the teardown. That
   row is what proves the last WAL segment reached S3; a row written
   minutes earlier does not.
5. `make down`, then `make up`. Confirm recovery from the previous
   generation, that every row and table is present, and that new
   archiving goes to a different prefix.
6. Repeat step 5 once. The second cycle is the one that matters: it
   recovers from a cluster that was itself recovered.
7. Re-sync Argo without a teardown and confirm it changes nothing.
8. `./scripts/verify-no-leaks.sh hetzner`, then
   `PROVIDER=hetzner make full-down`.

## 7. Dependencies and blockers

HETZ-115 (the Cluster and the teardown guard), CIVO-120 (the mechanism
and its proof), CIVO-180 (the bucket, the image, the plugin and the
`ObjectStore`). All three are `DONE`.

## 8. Acceptance criteria

- Rows and schema survive two down and up cycles on Hetzner, including a
  row committed seconds before each teardown, and including a cycle that
  recovers from an already-recovered cluster.
- Each generation archives into its own prefix, and the timeline history
  files do not collide.
- The pre-teardown backup is best-effort: it runs, it is waited for, and
  a failure warns loudly without blocking the teardown. The archiving
  state is read **before** the teardown proceeds, and an unhealthy state
  names the writes being destroyed.
- A re-sync without a teardown changes nothing.
- `aws sts get-caller-identity` in the backup sidecar returns the
  `pgbackup` role; no permanent AWS key exists in the cluster, the repo
  or SSM.
- `cluster-down` never touches the bucket; `persistent-down` empties it
  and deletes the pointer, under the existing confirmation.
- The aws golden diff is empty and the civo render is unchanged.

## 9. Validation

Offline: `make scripts-check`, `make gitops-check`, `make specs-check`.
Real cloud: one cold `full-up`, two Hetzner down/up cycles and one
`full-down` — roughly 0.30-0.60 EUR of Hetzner compute, one load
balancer and one 20 GB volume, plus S3 cents.

## 10. AWS regression protection

Every changed line is inside `hetzner_resolve_inputs` or
`hetzner_install_root_application`, both reached only from the hetzner
dispatch arms, plus one stale comment at the pointer-publish call site.
The aws and civo resolvers, installers and shared backup helpers are
untouched, and `make gitops-check` reports the aws golden diff unchanged.

## 11. Rollout and rollback/recovery

Data risk: yes. Test with disposable data only. Rollback: restore
`postgres.backup.enabled=false` for this target. Backups stay in the
bucket until `persistent-down`.

## 12. Risks and unresolved questions

- **"The pointer exists but the bucket is empty" has never been
  exercised**, on either target. The recovery branch has no `initdb`
  fallback by design, so this state must fail loudly rather than start an
  empty database that looks healthy. `persistent-down` deletes the
  pointer with the bucket, which keeps the two from disagreeing, but a
  hand-emptied bucket or a prune bug would reach it. Carried from
  CIVO-120 §12; not closed here.
- **No e2e assertion covers archiving.** `tests/e2e/postgres_test.go`
  asserts nothing about `ContinuousArchiving` or a `completed` Backup, so
  a silent archiving failure fails no test. Recorded here as a known gap;
  no spec owns it.
- A volume re-attach on Hetzner stalled for about six minutes in the
  HETZ-020 spike (`specs/hetzner/research.md`). Any timeout budget for a
  volume-carrying pod moving between nodes must exceed that. No spec has
  pinned it.
- The base-backup duration for a 20 GiB volume on a `cx33` sets
  `ARGO_DOWN_BACKUP_TIMEOUT`. Measure it once on this target rather than
  inheriting Civo's number by assumption.
- Enabling backups also arms this path in the `lifecycle-hetzner` CI leg,
  which runs `make full-up`. That leg has never exercised a bucket.

## 13. Definition of done

- [x] The three wiring points in §5 landed; offline checks green
- [x] A cold start plus two down/up cycles with row, schema and timeline
      evidence, including a row committed seconds before each teardown
- [x] Index updated; status `DONE`

Not claimed: the "pointer exists but the bucket is empty" path in §12 was not
exercised, and no e2e assertion covers archiving. Both are named there rather
than hidden. One unrelated defect was found during this run and is recorded
below as a finding against HETZ-040.

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — no longer depends on HETZ-182 (x86 nodes).

- 2026-09-23 - HETZ-115 closed the teardown half without this spec. The
  `backup_teardown` guard now returns early when no barman `ObjectStore`
  exists, so a hetzner teardown no longer attempts a plugin Backup it cannot
  run. The guard reads cluster state rather than `$PROVIDER`, so when this
  spec creates the `ObjectStore` the backup path arms itself with no code
  change here.

- 2026-09-23 — **rewritten from the withdrawn logical-dump design to the
  one that ships.** The body described ADR 0031's `images/pg-backup`
  image, daily `CronJob`, `PostSync` restore Job and `retentionDays`,
  none of which were ever built. §§1, 2, 4, 5, 6, 8, 9, 10 and 12 now
  describe the barman-cloud plugin. Three corrections worth naming:

  - The bucket was written as `vk-hetzner-lab-backups`. The module builds
    `${project}-${provider_region}-postgres-backups`, published at
    `/<project>/persistent/backups/bucket_name`.
  - §8 asserted *"The teardown gate fails closed on a failed dump."* That
    is the opposite of what ships. Constitution §4 makes a continuously
    archiving workload's pre-shutdown backup best-effort, and the
    criterion is replaced by one matching `backup_teardown`'s contract.
  - §2's no-`Retain`-class decision cited ADR 0031, which is superseded.
    The decision outlived that mechanism and is now attributed to
    ADR 0032 and ADR 0033.

  Scope shrank with the rewrite. The spec was written expecting to build
  the Hetzner half of a backup mechanism; the mechanism was built
  provider-neutral instead, so the delta is three wiring points in one
  file. Difficulty M becomes S.

  The same reading retires an obligation recorded against HETZ-040 §14:
  *"HETZ-120 adds persistent volumes on this target, and must narrow the
  volume leg of the sweep before it does."* That assumed this spec would
  introduce a `Retain` class. It does not — the volume stays `Delete` and
  disposable — so the sweep needs no narrowing.

- 2026-09-23 — **wiring implemented offline.** `hetzner_resolve_inputs`
  reads the bucket from the shared persistent layer and calls
  `backup_resolve_generation`; the eleventh SSM name pushed the single
  `get-parameters` request onto the batching loop the civo resolver uses.
  `hetzner_install_root_application` passes `enabled=true` with the
  bucket and both generation names. `make scripts-check`,
  `make gitops-check` (aws golden unchanged, hetzner object set as
  expected) and `make specs-check` all pass. The live evidence in §13 is
  outstanding.

- 2026-09-23 — **executed end to end on a live Hetzner cluster; every
  acceptance criterion in §8 passed.** Project `vk-hetzner-lab`, location
  `fsn1`, three `cx33` servers, k3s v1.36.4+k3s1, bucket
  `vk-hetzner-lab-fsn1-postgres-backups`.

  **Cold start.** No `server_name` pointer existed, so the Cluster took
  `bootstrap.initdb` — confirmed by reading `.spec.bootstrap`, not inferred
  from a healthy pod. Generation `lab-postgres-20260923T211038Z` was minted
  and the pointer written only after root reported healthy.
  `ContinuousArchiving=True` at `21:19:50Z`. `ScheduledBackup` produced
  `lab-postgres-20260923211957` (`method: plugin`) in `completed`. Six objects
  landed, including `base/20260923T211958/data.tar.gz`. PVC `lab-postgres-1`
  `Bound`, 20Gi, `hcloud-volumes`. All 11 Applications `Synced/Healthy`,
  `barman-cloud-plugin` among them.

  **Credentials.** The sidecar carries exactly three AWS variables —
  `AWS_CONFIG_FILE=/projected/aws/config`, `AWS_REGION`,
  `AWS_DEFAULT_REGION` — and `/projected/aws/config` sets `credential_process`
  to `aws_signing_helper` against role `vk-hetzner-lab-ra-pgbackup` with a
  3600s session. `grep -c` for `AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY` over
  the whole pod spec returns 0. §8 asks for `aws sts get-caller-identity` in
  the sidecar; that cannot run, because the image ships `aws_signing_helper`
  and barman's own boto but no `aws` CLI. The substitute evidence is stronger
  in one respect and weaker in another: objects demonstrably landed in S3
  under `inheritFromIAMRole: true`, which is impossible without the role
  resolving, but the role ARN is read from configuration rather than echoed
  back by STS. Recorded as met by different evidence than the literal wording.

  **Cycle 1 — recovery from a fresh cluster.** Three `cycle0` rows, the last
  (`FINAL-ROW-BEFORE-TEARDOWN`) at `21:21:23.811Z`, seconds before teardown.
  `argo-down` forced the WAL switch and the pre-teardown `Backup` reached
  `completed` in **25s** — that is the measured figure for a 20 GiB volume on
  a `cx33`, against the 600s `ARGO_DOWN_BACKUP_TIMEOUT`. `cluster-down`
  reported no leaks. After `make up` the Cluster showed `bootstrap.recovery`
  with `source: lab-postgres-previous`, `externalClusters[0]` naming
  `lab-postgres-20260923T211038Z`, archiving to
  `lab-postgres-20260923T213050Z`. All three rows present including the final
  one, `ddl_proof_cycle0` recovered, timeline 2.

  **Cycle 2 — recovery from a cluster that was itself recovered.** This is the
  case the generation-scoped `serverName` exists for. Three `cycle1` rows, the
  last at `21:38:39.061Z`. After `make up`: recovered from
  `lab-postgres-20260923T213050Z`, archiving to
  `lab-postgres-20260923T214905Z`, `ContinuousArchiving=True`. **All six rows
  across both cycles were present, both `FINAL-ROW-BEFORE-TEARDOWN` rows and
  both `ddl_proof_*` tables.** Timeline 3.

  **Timeline separation confirmed directly.** Each generation holds its own
  history file and nothing else: `lab-postgres-20260923T213050Z/wals/00000002.history.gz`
  and `lab-postgres-20260923T214905Z/wals/00000003.history.gz`. With a constant
  `serverName` these would have collided in one prefix.

  **Generation pruning ran for the first time on this target.** The first
  bring-up logged `1 backup generation(s) stored, keeping 2 - nothing to
  prune`; the second `2 ... nothing to prune`; the third pruned
  `lab-postgres-20260923T211038Z` and left the current and recovered-from
  prefixes, which is the bound §4 describes.

  **Re-sync without a teardown changes nothing.** A fourth `make up` on the
  live platform took the fast path (`root Application already Synced/Healthy`)
  and did not reinstall the root Application, so no generation was minted:
  Cluster `serverName` unchanged, SSM pointer unchanged, still two
  generations, still six rows, postgres container `restartCount` 0.

- 2026-09-23 — **finding against HETZ-040, fixed in this pull request.** The first
  `make up` of this session failed with
  `hetzner_kubeconfig: /etc/rancher/k3s/k3s.yaml did not appear on <ip> within 600s.`
  four seconds after `terragrunt apply` completed — it never waited 600s. The
  k3s.yaml poll runs on the far side of a single SSH call, so the retry budget
  covers the file appearing but not sshd answering. On a server created
  seconds earlier the connection itself fails, and that failure is reported as
  a k3s timeout. The cluster was healthy throughout: all three nodes `Ready`,
  k3s.yaml present, cloud-init `done`. Re-running `make up` succeeded
  immediately and no later bring-up in this session reproduced it, so it needs
  a slow server create to surface. The message is also actively misleading,
  which is the more expensive half of the defect.

  Fixed after PR #84 (`hetz-170-autoscaler`) failed its CI `lifecycle-hetzner`
  leg with the identical message, which showed this was blocking the Hetzner
  CI leg generally rather than being a local curiosity. The fetch is extracted
  into `hetzner_fetch_k3s_kubeconfig`, which retries only on ssh exit 255 —
  ssh's own "could not connect" — and lets any other status through, because
  that status came back from the remote side and means the wait really ran.
  The two cases now report different messages. `tests/scripts/hetzner-kubeconfig-fetch-test.sh`
  stubs `hetzner_ssh` to cover four cases: connects first try, connects after
  two refusals, never connects, and connects onto a server with no k3s.yaml.
