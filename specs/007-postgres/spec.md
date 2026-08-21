# 007 — PostgreSQL (in-cluster)

**Complexity:** High
**Risk:** High — the first real stateful workload; this is where the storage-contract proof from spec 005 gets exercised against actual data for the first time, and where an in-cluster-vs-RDS mistake would be expensive to unwind later.
**Estimated cost:** ~2–3 days, including a full destroy/recreate proof against real data · AWS runtime cost: one or two small EBS volumes + node cost while running.
**Recommended model:** Opus — operator selection, logical replication configuration, and the persistence proof are the highest-ambiguity work in the roadmap so far.
**Depends on:** 005-storage-contract (Retain StorageClass + rebind procedure), 006-karpenter (compute for the Postgres pod)
**Lifecycle class(es) touched:** Disposable (the operator, the Postgres pods/CRs) / Persistent (the EBS volume itself, Terraform-owned per ADR 0010 — a deliberate, documented exception to "Argo owns everything downstream of a PVC": the volume is the AWS resource, Terraform's domain; the PVC/PV binding is the Kubernetes resource, still Argo/CNPG's)

## Scope

Deploys PostgreSQL **in-cluster** via an operator (project decision: operator-managed, not RDS, to teach the PVC/EBS persistence pattern directly per architecture.md §13's "operator-managed" option):

- A Kubernetes-native Postgres operator (e.g., CloudNativePG or Zalando Postgres Operator — pick one and record the choice with rationale, since architecture.md explicitly defers this to an ADR).
- A Postgres cluster CR using the `Retain` StorageClass from spec 005.
- Logical replication enabled (`wal_level = logical`), since Debezium (spec 024) requires it.
- Basic connection/auth wiring for later application/integration workloads.

This spec's persistence guarantees (Requirement 2, Retain-based storage) are `aws`-target-only. On the `local` target (spec 021), Postgres runs the same operator/CR but on the default local StorageClass with `Delete` semantics — data is throwaway, and no destroy/recreate persistence proof is required there.

Excludes: Debezium and its connector configuration (023), observability dashboards (009 covers Postgres metrics, though this spec should expose them).

### Storage architecture

Per ADR 0010, the EBS volume is Terraform-owned (persistent lifecycle),
not dynamically provisioned by the CSI driver:

```text
Terraform (persistent/postgres-volume)
        ↓ creates, tags Component=postgres
AWS EBS volume  ←──────────────┐
        ↑ statically bound via  │ volume_id/AZ flow automatically:
        │ hand-written PV       │ Terraform output → argocd-bootstrap →
PostgreSQL Operator (CNPG)      │ gitops/values.yaml → Cluster CR/PV
        ↓ pvcTemplate binds ────┘
PVC (operator-created, bound to the static PV)
        ↓
StorageClass (ebs-retain, gp3 / EBS CSI, allowVolumeExpansion: true — spec 005)
```

`storage.size` on the CR remains the sole, authoritative growth mechanism
(Requirement 7) — Terraform's `aws_ebs_volume.size` is set once at creation
and never reconciled afterward (`ignore_changes = [size]`, ADR 0010).

Initial volume size: **10–30 GiB** gp3, not larger, unless a concrete workload estimate justifies more — storage is designed to grow on demand (see Requirement 7), so there is no cost benefit to overprovisioning up front. 10 GiB is the chosen starting point for this educational lab.

## Requirements

1. This is a genuine architectural decision the project owes an ADR for: **in-cluster operator-managed Postgres**, not RDS. Record the ADR before or alongside this spec per constitution §13 (architectural decisions must be documented, not silently assumed).
2. Postgres data MUST survive EKS deletion and recreation (constitution §4) — this spec's core acceptance criterion is proving that end to end. Recovery is automatic (ADR 0010): the Terraform-owned volume's ID/AZ flow into the gitops values with no manual step, and CNPG binds to it via static provisioning (ADR 0009) — not spec 005's manual hand-written-PV+PVC rebind procedure, which does not apply to CNPG's operator-managed PVCs.
3. The operator is a controller and MUST be Argo-managed (constitution §2, §7); it MUST remain running until any Postgres CR it manages has completed cleanup — Postgres CRs must be removed before the operator itself is ever removed.
4. Logical replication MUST be enabled and MUST support Debezium's requirements (replication slots, `wal_level = logical`, appropriate `max_replication_slots`/`max_wal_senders`) even though Debezium isn't wired up until spec 024 — get the Postgres-side prerequisites right now.
5. No destructive reclaim policy anywhere in the storage path (constitution §4) — reuse the `Retain` StorageClass from spec 005, don't introduce a new one.
6. Runtime credentials (the Postgres superuser/app passwords) MUST NOT be plaintext in Git — a minimal, temporary secret-handling approach is acceptable here (e.g., operator-generated Secret) as long as it's not committed anywhere; full Secrets Manager integration lands in spec 013.
7. Storage capacity increases MUST be applied declaratively through the Postgres operator's CR — CloudNativePG's `spec.storage.size` field (e.g. `20Gi` → `30Gi`), per ADR 0009 — not by manually resizing or replacing the underlying EBS volume. This relies on the `allowVolumeExpansion: true` StorageClass from spec 005 and MUST NOT require data migration or volume replacement; no downtime or pod restart is required, since CNPG's CSI-backed expansion is confirmed online — the change is applied in place, immediately, when the StorageClass supports online expansion (`ebs-retain` does). `spec.storage.size` remains authoritative for resize even when `spec.storage.pvcTemplate` is also set (used by the recovery path, Requirement 2) — see ADR 0009.
8. Storage is grow-only: `30Gi → 50Gi → 100Gi` is supported; shrinking (e.g., `100Gi → 50Gi`) is NOT supported and MUST NOT be attempted — EBS/PVC-backed Postgres storage is treated as monotonically increasing capacity only.

## Implementation hints

- **Operator selected: CloudNativePG** — see ADR 0009 for full rationale (CNCF trajectory, native arm64/Graviton operand images, `wal_level=logical` default, simpler single-CRD model than Zalando/Patroni) and the rejected Terraform-owned-EBS-volume alternative.
- Resource requests/limits and `shared_buffers`/`max_connections` tuning are **deliberately deferred** for the initial implementation pass — see ADR 0009's "Scope narrowing" section. They will be sized once the disposable cluster is up and `kubectl describe node` gives real Allocatable/Allocated numbers, rather than guessed in advance. This still needs to happen before this spec is considered fully done — spec 006's Karpenter-provisioning proof and Guaranteed-QoS OOM-avoidance both depend on it.
- **Recovery procedure does NOT reuse ADR 0008's generic hand-written-PV+PVC rebind.** CNPG creates and labels its own data PVC and does not adopt a foreign one — there is no PVC-adoption mechanism. The procedure is CNPG's own documented **static provisioning of persistent volumes**: a `PersistentVolume` templated into the gitops tree, pointing at the volume's `volumeHandle`, with the `Cluster` CR's `spec.storage.pvcTemplate` binding the operator-created PVC to that specific PV. See ADR 0009 for full detail and the caveats below.
- **Volume ownership moved to Terraform, and recovery is now automatic (ADR 0010), superseding ADR 0009's manual-values-edit description above.** The volume is created by `terraform/live/persistent/postgres-volume` (module: `terraform/modules/ebs-volume`), not dynamically provisioned by the CSI driver. Its ID/AZ flow automatically — Terraform output → a new `persistent → disposable` Terragrunt `dependency` → `terraform/modules/argocd-bootstrap` → `gitops/bootstrap/templates/root-application.yaml`'s Helm parameters → `gitops/values.yaml`'s `postgres.existingVolumeHandle`/`existingVolumeAz` — with no manual `aws ec2 describe-volumes` lookup or values-file edit required on any `disposable-down`/`disposable-up` cycle. The `{{- if .Values.postgres.existingVolumeHandle }}` branch in `cluster.yaml`/`recovered-pv.yaml` is always true in practice now, since the volume exists from the first `persistent-up` onward.
- Keep the operator's default backup tooling in mind for later, but don't build a separate backup pipeline in this spec — the goal here is proving the storage contract holds, not building a full backup/DR story (that's a non-goal per architecture.md §4).
- **App-user password is operator-generated and intentionally not pinned to a fixed value for this pass.** CNPG reconciles the `lab-postgres-app` Secret's password into the live role on every secret-version change (confirmed from CNPG's GHSA-w3gf-xc94-wvmj advisory text), not only at bootstrap — so a fresh random password after a `disposable-down`/`disposable-up` cycle never desyncs from the recovered database; Requirement 6 already holds without pinning. Pinning to a stable value was considered and deferred: doing it without landing the password somewhere `kubectl`-readable (ruling out the `existingVolumeHandle`-style Helm-parameter chain) or in Git plaintext requires something Argo-owned to decrypt a committed secret into a Kubernetes Secret before CNPG bootstraps — i.e. External Secrets Operator, which is spec 013's job. Revisit there.
- **Resolved — CloudNativePG's resize behavior (was an open decision, now confirmed, ADR 0009):** `spec.storage.size` triggers a PVC/EBS resize in place via the CSI driver, with no pod restart, when the StorageClass supports online expansion (`ebs-retain` does, `allowVolumeExpansion: true`). No documented minimum-increment constraint from CNPG itself, but AWS rate-limits EBS volume modifications to roughly one per 6-hour rolling window — sequence acceptance tests accordingly (expansion proof last).
- **Still open, must be verified empirically before the real acceptance run touches real data:** whether CNPG's instance manager starts against an already-initialized PGDATA on a `pvcTemplate`-bound pre-existing volume, or re-runs `initdb` and overwrites it. CNPG's docs don't settle this (the closest thing to guidance is an open, maintainer-unanswered GitHub discussion). Dry-run this on a throwaway volume — delete just the `Cluster` CR, not the whole EKS stack — before trusting it in the destroy/recreate proof.
- **`local` target is out of scope for this implementation pass.** Spec 020 (the `local` execution target) is not yet implemented on disk, so this spec's manifests are `aws`-only for now (`gitops/templates/platform/aws/postgres/`), matching the existing `karpenter`/`ebs-csi` convention. Revisit when spec 021 lands.

## Testing / acceptance criteria

- Full lifecycle proof required (constitution §11/§12 — this is squarely a "stateful and lifecycle-sensitive change"): CREATE → VERIFY Postgres healthy and accepting connections → WRITE real test data (a table with rows, not just a health check) → DESTROY the disposable EKS stack → VERIFY the EBS volume persisted (Terraform-tracked, per ADR 0010 — `persistent-down` was never run) → RECREATE the EKS stack and reinstall the operator via Argo → VERIFY the test data is recovered automatically, with no manual values edit → confirm replication slot configuration survived (needed for spec 024).
- Argo shows the Postgres operator and CR as `Synced`/`Healthy` after both the initial deploy and the post-recreation rebind.
- Storage expansion proof required: with the cluster running and holding test data, increase the CR's declared size (e.g., 20Gi → 30Gi) and verify the PVC, the underlying EBS volume, and the filesystem visible inside the Postgres pod all reflect the new size, no data is lost, and no PVC/volume replacement occurred.
- Fast validation (Helm/manifest rendering, k8s schema) on every change; full lifecycle test specifically required whenever the Postgres CR, StorageClass reference, or operator version changes.
