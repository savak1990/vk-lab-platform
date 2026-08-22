# ADR 0014: Postgres app-user password pinned via External Secrets Operator

## Status

Accepted

## Context

Live testing of ADR 0013's VolumeSnapshot recovery found a real bug: after a
`disposable-down`/`disposable-up` → `argo-up` cycle that recovered Postgres
from a snapshot, `psql` login as `vkdb` failed with `password authentication
failed`.

CNPG auto-generates a random password for the `lab-postgres-app` Secret on
every `Cluster` CR creation, regardless of bootstrap mode. On `initdb`
bootstrap this is fine — CNPG runs `CREATE ROLE vkdb PASSWORD '<secret's
password>'`, so Secret and role always agree. On `recovery` bootstrap, CNPG
only restores PGDATA files; it never resets any role's password. Confirmed
empirically (no role/password reconciliation activity in operator logs
around a recovery), and via `cloudnative-pg/charts#310`, which shows
pre-existing-app-secret wiring exists only for `bootstrap.initdb`, not
`bootstrap.recovery`. Since `cnpg-system` (and its Secrets) is
Disposable-lifecycle and gets wiped every cycle, this mismatch recurs on
every recovery, not just the first one.

This falsifies `specs/007-postgres/spec.md` line 65's claim that CNPG
"reconciles the `lab-postgres-app` Secret's password into the live role on
every secret-version change... so [it] already holds without pinning" — that
claim predates the recovery path this repo now has.

Two fixes were scoped: a minimal one (decrypt a committed KMS secret file
locally in `argo-up.sh`, `kubectl apply` a fixed-password Secret directly,
matching the existing ArgoCD-admin-password precedent), and pulling forward
the Postgres-relevant slice of spec 013 (External Secrets Operator, AWS
Secrets Manager, EKS Pod Identity). **The user chose the latter explicitly**,
prioritizing the architecturally-correct long-term mechanism over the
smaller patch, given that the actual fix — a password that's stable across
`initdb` and `recovery` — is identical either way; ESO only changes where
that value comes from.

## Decision

Implement External Secrets Operator (ESO), scoped to exactly this one
credential, as spec `007-2-secrets-for-postgres`:

- `secrets/<project>/postgres-app-password.enc` (existing KMS-encrypt
  tooling) → `terraform/live/persistent/secrets` (existing module, one new
  map entry) → the `${project}-secrets` AWS Secrets Manager object,
  alongside `postgres_admin_password`.
- A new `terraform/modules/external-secrets-pod-identity` module (identical
  shape to `ebs-csi-pod-identity`/`karpenter-pod-identity`) creates an IAM
  role trusted by `pods.eks.amazonaws.com`, scoped to
  `secretsmanager:GetSecretValue` on exactly that one ARN, and an
  `aws_eks_pod_identity_association` binding it to the `external-secrets`
  controller's service account. The `eks-pod-identity-agent` addon this
  needs already exists (`terraform/modules/eks/main.tf`) — no new
  cluster-level prerequisite.
- `gitops/templates/platform/aws/external-secrets/application.yaml` — the
  ESO Argo Application (official chart, bundles its own CRDs), sync-wave
  -2.
- `gitops/templates/platform/aws/external-secrets/secretstore.yaml` — a
  `ClusterSecretStore` (AWS Secrets Manager, no explicit `auth:` — Pod
  Identity credentials are ambient) and an `ExternalSecret` populating
  `lab-postgres-app` (`username: vkdb` static, `password` from the Secrets
  Manager value, `refreshInterval: 24h` — no rotation is planned for this
  value), sync-wave 0 (the earliest wave `cnpg-system` is guaranteed to
  exist, one wave after `cnpg-operator`'s own Application creates it — the
  same precedent `recovered-snapshot.yaml` already relies on).
- `cluster.yaml` is unchanged — CNPG detects the pre-existing
  `lab-postgres-app` Secret by name on both `initdb` and `recovery`
  bootstrap without any CR-level wiring.
- No `argo-up.sh`/`argo-down.sh` change — the password now flows entirely
  in-cluster; the scripts' existing snapshot-handle discovery/pruning is
  untouched.

**Open risk, accepted and verified by test, not resolved by construction:**
`ClusterSecretStore`/`ExternalSecret` are root's own resources, but the CRDs
they depend on come from `external-secrets`, a *separate* Argo Application —
structurally identical to `VolumeSnapshotClass` depending on
`external-snapshotter`'s CRDs, which broke twice during this same
investigation (a kustomize-templating bug, then CNPG not restarting after
its CRD appeared). Sync-wave numbers only order when root *creates* each
child Application; they don't reliably gate one Application's controller
readiness on a sibling's health. If `lab-postgres-app` isn't populated
before `Cluster` reconciles, the fix is a `PreSync` hook on
`cnpg-operator`'s Application waiting for that Secret to exist with a
non-empty `password` key — the same pattern already scoped for the CRD race,
gating on a Secret instead of a CRD's `Established` condition.

**Deliberately not pre-populated:** the `lab-postgres-app` Secret's
convenience keys CNPG itself normally generates (`host`, `port`, `dbname`,
`uri`, `jdbc-uri`, `pgpass`) — only `username`/`password` are templated.
Whether CNPG backfills those into a pre-existing Secret is unverified against
this exact operator version; nothing in this repo consumes them today. If a
future consumer needs them and CNPG doesn't backfill, extend the
`ExternalSecret`'s template rather than guessing the exact format now.

## Consequences

- `specs/007-postgres/spec.md` line 65 needed a correction — its "no pinning
  needed" claim didn't survive contact with the recovery path.
- Full spec 013 (Kafka credential migration, broader rotation story) remains
  future work — this ADR only implements the Postgres slice.
- One-time transition: the EKS cluster was already torn down before this
  landed, so the newest surviving snapshot has the old, now-unknown, random
  password baked in. The next `argo-up` recovering from it will still fail
  login with the newly-pinned password — expected, not a regression. Given
  this is a disposable learning platform with no real data at stake, the
  simplest resolution is deleting the existing Postgres snapshot(s) once so
  the next `argo-up` does a fresh `initdb` instead.
