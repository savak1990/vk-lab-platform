# 007 — PostgreSQL (in-cluster)

**Complexity:** High
**Risk:** High — the first real stateful workload; this is where the storage-contract proof from spec 005 gets exercised against actual data for the first time, and where an in-cluster-vs-RDS mistake would be expensive to unwind later.
**Estimated cost:** ~2–3 days, including a full destroy/recreate proof against real data · AWS runtime cost: one or two small EBS volumes + node cost while running.
**Recommended model:** Opus — operator selection, logical replication configuration, and the persistence proof are the highest-ambiguity work in the roadmap so far.
**Depends on:** 005-storage-contract (Retain StorageClass + rebind procedure), 006-karpenter (compute for the Postgres pod)
**Lifecycle class(es) touched:** Disposable (the operator, the Postgres pods/CRs) / Persistent (the underlying EBS volume data)

## Scope

Deploys PostgreSQL **in-cluster** via an operator (project decision: operator-managed, not RDS, to teach the PVC/EBS persistence pattern directly per architecture.md §13's "operator-managed" option):

- A Kubernetes-native Postgres operator (e.g., CloudNativePG or Zalando Postgres Operator — pick one and record the choice with rationale, since architecture.md explicitly defers this to an ADR).
- A Postgres cluster CR using the `Retain` StorageClass from spec 005.
- Logical replication enabled (`wal_level = logical`), since Debezium (spec 009) requires it.
- Basic connection/auth wiring for later application/integration workloads.

This spec's persistence guarantees (Requirement 2, Retain-based storage) are `aws`-target-only. On the `local` target (spec 021), Postgres runs the same operator/CR but on the default local StorageClass with `Delete` semantics — data is throwaway, and no destroy/recreate persistence proof is required there.

Excludes: Debezium and its connector configuration (009), observability dashboards (010 covers Postgres metrics, though this spec should expose them).

### Storage architecture

```text
PostgreSQL Operator
        ↓
PVC
        ↓
StorageClass (gp3 / EBS CSI, allowVolumeExpansion: true — spec 005)
        ↓
AWS EBS volume
```

Initial volume size: **20–30 GiB** gp3, not larger, unless a concrete workload estimate justifies more — storage is designed to grow on demand (see Requirement 7), so there is no cost benefit to overprovisioning up front.

## Requirements

1. This is a genuine architectural decision the project owes an ADR for: **in-cluster operator-managed Postgres**, not RDS. Record the ADR before or alongside this spec per constitution §13 (architectural decisions must be documented, not silently assumed).
2. Postgres data MUST survive EKS deletion and recreation (constitution §4) — this spec's core acceptance criterion is proving that end to end, following the rebind procedure documented in spec 005.
3. The operator is a controller and MUST be Argo-managed (constitution §2, §7); it MUST remain running until any Postgres CR it manages has completed cleanup — Postgres CRs must be removed before the operator itself is ever removed.
4. Logical replication MUST be enabled and MUST support Debezium's requirements (replication slots, `wal_level = logical`, appropriate `max_replication_slots`/`max_wal_senders`) even though Debezium isn't wired up until spec 009 — get the Postgres-side prerequisites right now.
5. No destructive reclaim policy anywhere in the storage path (constitution §4) — reuse the `Retain` StorageClass from spec 005, don't introduce a new one.
6. Runtime credentials (the Postgres superuser/app passwords) MUST NOT be plaintext in Git — a minimal, temporary secret-handling approach is acceptable here (e.g., operator-generated Secret) as long as it's not committed anywhere; full Secrets Manager integration lands in spec 013.
7. Storage capacity increases MUST be applied declaratively through the Postgres operator's CR (e.g., conceptually `spec.storage.size: 30Gi` → `50Gi` — the exact field name depends on the operator chosen per Requirement 1), not by manually resizing or replacing the underlying EBS volume. This relies on the `allowVolumeExpansion: true` StorageClass from spec 005 and MUST NOT require data migration or volume replacement; downtime should not be required either, to the extent the chosen operator/CSI/filesystem combination supports online resize (implementation note — confirm and document the actual behavior of the chosen operator once selected, see Implementation hints).
8. Storage is grow-only: `30Gi → 50Gi → 100Gi` is supported; shrinking (e.g., `100Gi → 50Gi`) is NOT supported and MUST NOT be attempted — EBS/PVC-backed Postgres storage is treated as monotonically increasing capacity only.

## Implementation hints

- CloudNativePG is generally the more actively maintained, Kubernetes-native option with strong backup/restore and replication tooling built in — a reasonable default unless there's a specific reason to prefer Zalando's operator; write the ADR either way.
- Size the Postgres pod's resource requests deliberately — this will be one of the first things that forces Karpenter (spec 006) to actually provision a node, which doubles as a live test of that spec.
- Reuse the exact rebind procedure documented in spec 005, applied to a real Postgres data volume: destroy the EKS cluster (`terraform destroy` on disposable), recreate it, reinstall the operator via Argo, and rebind the retained EBS volume to a new Postgres CR/PVC.
- Keep the operator's default backup tooling in mind for later, but don't build a separate backup pipeline in this spec — the goal here is proving the storage contract holds, not building a full backup/DR story (that's a non-goal per architecture.md §4).
- **Open decision — confirm at operator-selection time:** the exact CR field and resize behavior differ by operator and aren't yet locked in. CloudNativePG exposes `spec.storage.size` and, per its docs, expands the underlying PVC in place (subject to the StorageClass supporting expansion) without recreating the pod; Zalando's operator uses `spec.volume.size` with broadly similar PVC-resize behavior. Whichever operator the ADR selects, verify against its current docs: (a) that it actually triggers a PVC/EBS resize rather than requiring manual PVC edits, (b) whether a pod restart is required to pick up the new filesystem size, and (c) any minimum-increment or in-flight-resize constraints. Record the confirmed behavior here once verified — don't assume it matches CloudNativePG's behavior if Zalando is chosen, or vice versa.

## Testing / acceptance criteria

- Full lifecycle proof required (constitution §11/§12 — this is squarely a "stateful and lifecycle-sensitive change"): CREATE → VERIFY Postgres healthy and accepting connections → WRITE real test data (a table with rows, not just a health check) → DESTROY the disposable EKS stack → VERIFY the EBS volume for the Postgres PVC persisted → RECREATE the EKS stack and reinstall the operator via Argo → VERIFY the test data is recoverable via the rebind procedure → confirm replication slot configuration survived (needed for spec 009).
- Argo shows the Postgres operator and CR as `Synced`/`Healthy` after both the initial deploy and the post-recreation rebind.
- Storage expansion proof required: with the cluster running and holding test data, increase the CR's declared size (e.g., 20Gi → 30Gi) and verify the PVC, the underlying EBS volume, and the filesystem visible inside the Postgres pod all reflect the new size, no data is lost, and no PVC/volume replacement occurred.
- Fast validation (Helm/manifest rendering, k8s schema) on every change; full lifecycle test specifically required whenever the Postgres CR, StorageClass reference, or operator version changes.
