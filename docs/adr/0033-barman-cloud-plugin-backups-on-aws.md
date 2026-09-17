# ADR 0033: The AWS target moves to the CNPG barman-cloud plugin

## Status

Accepted. Supersedes ADR 0013. Extends ADR 0032 to the AWS target.

## Context

ADR 0013 made a cold CNPG `VolumeSnapshot` backup, taken by `argo-down`
just before teardown, the only thing that carried the AWS PostgreSQL
database across `make down` / `make up`. ADR 0032 then gave Civo
continuous physical backups to S3 through the CloudNativePG barman-cloud
plugin, because Civo's CSI driver cannot snapshot.

That left two recovery mechanisms, and the AWS one had real costs:

- **No point-in-time recovery.** One recovery point per cycle, taken at
  teardown. A crash or a failed teardown backup lost everything since the
  previous cycle.
- **The backup fences the primary.** `online: false` stops writes while
  the snapshot runs, and the teardown had to fail closed on it, because
  the snapshot was the only copy.
- **More moving parts.** The external-snapshotter CRDs and controller, a
  `VolumeSnapshotClass`, a client-side-applied `VolumeSnapshotContent`
  with a root `ignoreDifferences` entry, the EBS CSI `csi-snapshotter`
  sidecar, and tag-based snapshot discovery and pruning in two scripts.

ADR 0013 rejected the barman plugin because it needed cert-manager and
exceeded the "survive one teardown" scope. Both reasons are gone:
cert-manager runs on both targets, and ADR 0032 already runs the plugin
on Civo.

The CIVO-185 spike (evidence in that spec's §14) settled the two open
questions on a live EKS cluster:

- **Identity.** The EKS Pod Identity webhook injects
  `AWS_CONTAINER_CREDENTIALS_FULL_URI`, the token file, `AWS_REGION` and
  `AWS_DEFAULT_REGION` into the plugin's native sidecar, exactly as into
  any other container. `inheritFromIAMRole: true` then works with no
  extra configuration.
- **Architecture.** The upstream sidecar image is multi-arch. A base
  backup and a recovery that replayed WAL past it both worked on arm64
  Graviton nodes, with matching rows.

## Decision

**Both targets back up PostgreSQL through the barman-cloud plugin.** The
AWS `VolumeSnapshot` mechanism is removed: the snapshot manifests and
CRDs, the `csi-snapshotter` sidecar, the root `ignoreDifferences` entry,
`postgres.recoverySnapshotHandle`, and the snapshot discovery, pruning
and fail-closed teardown backup.

**Identity differs; nothing else does.** AWS uses a Pod Identity
association for `cnpg-system/lab-postgres`, scoped to this project's
bucket, and the upstream sidecar image. Civo keeps ADR 0032's Roles
Anywhere certificate, `credential_process` and custom sidecar image. The
plugin Application, `ObjectStore`, `ScheduledBackup`, the Cluster's
`plugins` block and the recovery branch are shared templates.

**The bucket and the generation pointer stay per project and per
lifecycle layer.** AWS: `terraform/live/persistent/backups`, SSM
`/<project>/persistent/backups/bucket_name` and
`/<project>/persistent/postgres-backup/server_name`. Civo keeps
`persistent-civo`. `PERSISTENT_EXCLUDE` keeps the AWS unit off Civo.

**The PostgreSQL image is pinned by digest on both targets**
(`Cluster.spec.imageName`), so an operator chart upgrade can never change
the major version under a backup.

**Teardown is best-effort on both targets**, under constitution §4's
relaxation for continuously archiving workloads: the final base backup
runs and is waited for, and a failure warns loudly without blocking.

**ADR 0013's failure philosophy carries forward.** The recovery branch
has no `initdb` fallback.

**The cutover was additive first.** Both mechanisms ran together for one
AWS cycle, so the first plugin-only bring-up recovered from an S3
generation that already existed and never fell through to `initdb`.

**Cross-provider restore is out of scope.** Buckets are per project, a
shared bucket would let a leaked Civo token reach AWS data through the
ADR 0030 CA-key path, and AWS runs arm64 while Civo runs x86_64:
PostgreSQL does not support physical restore across architectures.

## Consequences

- AWS gains point-in-time recovery, and teardown no longer fences the
  primary or blocks on a backup.
- AWS `make up` now requires `terraform/live/persistent/backups` to be
  applied; `argo-up` reads its SSM parameter and fails hard without it.
- Recovery time grows with database size and WAL volume, unlike a
  snapshot restore. Size `ARGO_UP_WATCH_SECONDS` from measured cycles.
- The plugin sidecar adds its memory request and limit to the Postgres
  pod on the on-demand pool.
- EBS snapshots taken before this change are no longer read by anything.
  `persistent-down` still deletes them.
- The plugin's wildcard `secrets` Role (ADR 0032) now exists on AWS too;
  CIVO-205 covers both targets.
