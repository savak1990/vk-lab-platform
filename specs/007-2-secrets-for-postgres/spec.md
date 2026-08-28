# 007-2 — Secrets for Postgres (External Secrets Operator, scoped)

**Status:** Implemented

**Complexity:** Medium
**Risk:** Medium — narrow IAM permission design for one Secrets Manager ARN, plus a new Argo-managed controller whose cross-Application startup ordering relative to CNPG is unverified.
**Estimated cost:** ~0.5 day, given `terraform/modules/ebs-csi-pod-identity`/`karpenter-pod-identity` and `terraform/modules/secrets-manager-secret` already exist and are reused as-is.
**Depends on:** 007-1-postgres-persistence-recovery (ADR 0013, the recovery bootstrap this fixes credentials for), 013-secrets (this spec pulls forward exactly the Postgres-app-password slice of it)
**Lifecycle class(es) touched:** Persistent (the Secrets Manager value) / Disposable (Pod Identity association, the `external-secrets` controller, the `ExternalSecret`/`ClusterSecretStore` CRs)

## Scope

Fixes a real bug found while testing ADR 0013's VolumeSnapshot recovery:
CNPG auto-generates a random password for the `lab-postgres-app` Secret on
every `Cluster` CR creation. On `initdb` bootstrap this is applied to the
role correctly; on `recovery` bootstrap CNPG never resets any role's
password (confirmed empirically, and via `cloudnative-pg/charts#310`, which
shows pre-existing-secret wiring exists only for `initdb`, not `recovery`).
Since the whole `cnpg-system` namespace is Disposable-lifecycle, every
recovery cycle regenerates a random password that doesn't match what's
already baked into the recovered PGDATA — this falsified
`specs/007-postgres/spec.md` line 65's claim that CNPG's own reconciliation
made pinning unnecessary; that claim predates the recovery path.

Rather than a minimal script-based fix, this spec pulls forward exactly the
Postgres-relevant slice of spec 013 (External Secrets Operator, Secrets
Manager, EKS Pod Identity) — the user's explicit choice, prioritizing the
architecturally-correct mechanism over the smaller patch, given the
underlying fix (a stable password) is identical either way. Out of scope:
migrating Kafka/spec 025 credentials (spec 013's job when that spec lands),
secret rotation automation beyond ESO's default polling, and any change to
`argo-up.sh`/`argo-down.sh` — the password now flows entirely in-cluster.

## Requirements

1. The `vkdb` app-user password MUST be a fixed value stored once in
   `secrets/<project>/postgres-app-password.enc` (existing KMS-encrypt
   tooling) and MUST NOT be plaintext in Git at any point.
2. The value MUST live in AWS Secrets Manager (constitution §5) — extend
   the existing `${project}-secrets` object (`terraform/live/persistent/secrets`)
   with a `postgres_app_password` key, reusing `terraform/modules/secrets-manager-secret`
   unchanged.
3. A Kubernetes workload MUST sync that Secrets Manager value into the
   `lab-postgres-app` Kubernetes `Secret` using EKS Pod Identity
   (constitution §5, ADR 0001) — no static AWS credentials in the cluster.
   The IAM role backing this MUST be scoped to exactly
   `secretsmanager:GetSecretValue` (and whatever else is strictly required)
   on the one `${project}-secrets` ARN — no wildcard `secretsmanager:*`.
4. `cluster.yaml`'s `Cluster` CR MUST NOT change — CNPG detects the
   pre-existing `lab-postgres-app` Secret by name on both `initdb` and
   `recovery` bootstrap without any CR-level wiring.
5. The `external-secrets` controller and its `ExternalSecret`/`ClusterSecretStore`
   CRs MUST reach a synced/populated state before `cluster.yaml`'s `Cluster`
   (sync-wave 1) reconciles, on every cycle including recovery — verified
   empirically, not assumed from sync-wave numbers alone (see Testing below).

## Implementation hints

- Reuse `terraform/modules/ebs-csi-pod-identity`'s shape exactly for the new
  `terraform/modules/external-secrets-pod-identity` module (trust policy,
  role, `aws_eks_pod_identity_association`) — only the inline policy's
  actions/resources differ.
- The `external-secrets` Helm chart (`https://charts.external-secrets.io`)
  bundles its own CRDs in the chart's `crds/` directory, unlike
  `external-snapshotter` — no separate CRD Application is needed, and
  Helm's own CRD-before-templates ordering applies within that one chart
  install.
- `ClusterSecretStore`'s AWS provider needs no explicit `auth:` block when
  using EKS Pod Identity — ambient credentials from the controller pod's
  association are enough.
- `ExternalSecret`'s target namespace (`cnpg-system`) doesn't exist until
  `cnpg-operator`'s own Application (wave -1) creates it — the
  `ExternalSecret`/`ClusterSecretStore` sit at wave 0, one wave after that,
  matching the precedent `recovered-snapshot.yaml` already relies on for the
  same namespace.

## Open risk, accepted and to verify (not resolved by this spec's design alone)

`ClusterSecretStore`/`ExternalSecret` are root's own resources, but the CRDs
they depend on come from a separate Argo Application (`external-secrets`) —
structurally identical to `VolumeSnapshotClass` depending on
`external-snapshotter`'s CRDs, which broke twice during ADR 0013's own
testing (a manifest bug, then CNPG not restarting after its CRD appeared).
Sync-wave numbers order when root *creates* each child Application; they do
not reliably gate one Application's controller readiness on a sibling's
health. This spec accepts that risk and verifies it by test rather than by
construction. If `lab-postgres-app` isn't populated before `Cluster`
reconciles, the fix is a `PreSync` hook on `cnpg-operator`'s Application
waiting for that Secret to exist with a non-empty `password` key.

## Testing / acceptance criteria

- `terragrunt validate` on the two new/changed Terraform units;
  `helm template gitops` renders cleanly on both the `initdb` and `recovery`
  branches.
- After `persistent-up`, `${project}-secrets` in Secrets Manager has a
  `postgres_app_password` key.
- After `cluster-up`, the Pod Identity association for
  `external-secrets`/`external-secrets` exists.
- Fresh `argo-up` (no snapshot): `external-secrets` and `lab-postgres-app`'s
  `ExternalSecret` reach `Synced`, `lab-postgres-app` has the
  Secrets-Manager-sourced password *before* `Cluster` leaves "Setting up
  primary," and `psql` login succeeds.
- The real regression test: `argo-down` → `cluster-down` →
  `cluster-up` → `argo-up`, three cycles total (per ADR 0013's own
  testing note), confirming `recovery` bootstrap and the same pinned
  password keep working — not just the first cycle.
- Explicit check of the open ordering risk on at least one cycle: watch
  whether `lab-postgres-app` is correctly populated before CNPG's `Cluster`
  starts reconciling.
