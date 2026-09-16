# ADR 0032: Physical backups to S3 through the CNPG barman-cloud plugin on Civo

## Status

Accepted. Supersedes ADR 0031.

## Context

ADR 0031 rejected CNPG's Barman Cloud plugin on a single stated premise:

> CNPG has no supported way to add a container of one's own to its managed
> instance pods.

**That premise is false**, and the whole of ADR 0031 rests on it.

The plugin injects its own sidecar into every instance pod. Two facts,
both read from source, make an AWS identity available inside that sidecar
without a permanent key:

- `plugin-barman-cloud` v0.15.0,
  `internal/cnpgi/operator/lifecycle.go`:
  `sidecar.VolumeMounts = ensureVolumeMount(sidecar.VolumeMounts, spec.Containers[i].VolumeMounts...)`.
  The sidecar inherits every volume mount from the `postgres` container.
- CloudNativePG's `Cluster.spec.projectedVolumeTemplate` mounts arbitrary
  Secrets and ConfigMaps into instance pods at `/projected`.

So a Roles Anywhere certificate (ADR 0029) reaches the sidecar as a real
mounted file, and a mounted file updates in place when cert-manager
rotates it. The sidecar image is upstream's plus one binary,
`aws_signing_helper`, invoked through the AWS config file's
`credential_process`. The entrypoint, the user and the PATH are all
inherited unchanged.

This was verified on a live Civo cluster before this ADR was written. The
evidence is recorded in `specs/civo/120-cnpg-on-civo-persistence/spec.md`
§14, including a deliberately short certificate rotating every five
minutes: 12 rotations, 0 archiving failures, with WAL segments written
after the `notAfter` of the certificate present at pod start.

## Decision

**Civo's PostgreSQL backup mechanism is continuous physical backup to a
per-project S3 bucket through the CNPG barman-cloud plugin.** ADR 0031's
logical-dump design is withdrawn before it was implemented. No `pg_dump`
image, CronJob or restore Job is built.

**Point-in-time recovery returns.** ADR 0031 accepted its loss as the
price of removing the permanent-key requirement. That price does not have
to be paid: `credential_process` spawns the signing helper fresh on each
credential fetch, so no AWS key exists at rest anywhere in the design,
and the archive is a continuous WAL stream rather than discrete dump
instants.

**Retention is a recovery window, not a backup count.** The plugin's
`retentionPolicy` field matches `^[1-9][0-9]*[dwm]$` and accepts no other
form, so "keep exactly 2 backups" is not expressible. A daily
`ScheduledBackup` with `retentionPolicy: 2d` keeps roughly two to three
base backups. A 30-day S3 lifecycle rule sits well above that window as a
backstop only — an aggressive rule would delete WAL segments a surviving
base backup still needs.

**`serverName` is scoped to one bring-up.** Each `make up` mints
`lab-postgres-<UTC timestamp>` and recovers from the previous one, which
is recorded in SSM. With a constant `serverName`, a recovered cluster
would archive WAL into the prefix it just recovered from and collide with
that timeline history.

**Teardown never asks for a confirmation and never blocks on a backup
result.** `CI_TEARDOWN_ALLOW_DATA_LOSS` is removed from the repository.
Continuous WAL archiving has already made every committed row durable
before teardown starts, so a failed pre-teardown base backup costs replay
time, not data. The backup runs, it is waited for, and a failure prints a
loud warning naming the archiving condition and continues.

**ADR 0013's failure philosophy carries forward unchanged.** There is no
`initdb` fallback on the recovery path. A pointer to a generation with an
empty bucket fails loudly rather than silently starting an empty database
that looks healthy.

**ADR 0013 still governs AWS.** This ADR changes Civo only. CIVO-185 may
migrate AWS onto the same plugin later, which on AWS needs Pod Identity
with `inheritFromIAMRole: true` and none of the signing-helper machinery.

## Consequences

- Civo gains point-in-time recovery, which ADR 0031 had given up.
- **This repository now builds a container image.** It did not before.
  The image lives in `images/cnpg-barman-sidecar/`, is built by a
  dedicated workflow on pushes that touch it, is published to GHCR as a
  public package, and is pinned by digest in `gitops/values.yaml`. The
  package must stay public: there is no `imagePullSecret` anywhere in
  this repository, so a private package means `ImagePullBackOff` and the
  Postgres pod never starts.
- **This repository now owns an S3 lifecycle rule.** It did not before.
  It is a backstop against orphaned objects, not the retention mechanism.
- The backup bucket is per project (`${project}-postgres-backups`),
  Persistent-lifecycle, and lives under `persistent-civo` rather than
  `persistent`: the latter applies on both providers and would create an
  AWS bucket too.
- The plugin generates a `Role` whose secrets rule carries an empty
  `resourceNames`, which grants read access to every Secret in
  `cnpg-system`. This repository runs no restrictive operator RBAC, so it
  applies cleanly, but it is wider than this platform would write by
  hand. Carried into the least-privilege review, CIVO-205.
- CIVO-186, which rests entirely on `pg_dump --no-owner --no-privileges`
  portability, no longer has a mechanism. Physical base backups plus WAL
  are not portable that way. CIVO-186 was later removed.
