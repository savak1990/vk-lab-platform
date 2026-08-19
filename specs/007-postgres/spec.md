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

Excludes: Debezium and its connector configuration (009), observability dashboards (010 covers Postgres metrics, though this spec should expose them).

## Requirements

1. This is a genuine architectural decision the project owes an ADR for: **in-cluster operator-managed Postgres**, not RDS. Record the ADR before or alongside this spec per constitution §13 (architectural decisions must be documented, not silently assumed).
2. Postgres data MUST survive EKS deletion and recreation (constitution §4) — this spec's core acceptance criterion is proving that end to end, following the rebind procedure documented in spec 005.
3. The operator is a controller and MUST be Argo-managed (constitution §2, §7); it MUST remain running until any Postgres CR it manages has completed cleanup — Postgres CRs must be removed before the operator itself is ever removed.
4. Logical replication MUST be enabled and MUST support Debezium's requirements (replication slots, `wal_level = logical`, appropriate `max_replication_slots`/`max_wal_senders`) even though Debezium isn't wired up until spec 009 — get the Postgres-side prerequisites right now.
5. No destructive reclaim policy anywhere in the storage path (constitution §4) — reuse the `Retain` StorageClass from spec 005, don't introduce a new one.
6. Runtime credentials (the Postgres superuser/app passwords) MUST NOT be plaintext in Git — a minimal, temporary secret-handling approach is acceptable here (e.g., operator-generated Secret) as long as it's not committed anywhere; full Secrets Manager integration lands in spec 013.

## Implementation hints

- CloudNativePG is generally the more actively maintained, Kubernetes-native option with strong backup/restore and replication tooling built in — a reasonable default unless there's a specific reason to prefer Zalando's operator; write the ADR either way.
- Size the Postgres pod's resource requests deliberately — this will be one of the first things that forces Karpenter (spec 006) to actually provision a node, which doubles as a live test of that spec.
- Reuse the exact rebind procedure documented in spec 005, applied to a real Postgres data volume: destroy the EKS cluster (`terraform destroy` on disposable), recreate it, reinstall the operator via Argo, and rebind the retained EBS volume to a new Postgres CR/PVC.
- Keep the operator's default backup tooling in mind for later, but don't build a separate backup pipeline in this spec — the goal here is proving the storage contract holds, not building a full backup/DR story (that's a non-goal per architecture.md §4).

## Testing / acceptance criteria

- Full lifecycle proof required (constitution §11/§12 — this is squarely a "stateful and lifecycle-sensitive change"): CREATE → VERIFY Postgres healthy and accepting connections → WRITE real test data (a table with rows, not just a health check) → DESTROY the disposable EKS stack → VERIFY the EBS volume for the Postgres PVC persisted → RECREATE the EKS stack and reinstall the operator via Argo → VERIFY the test data is recoverable via the rebind procedure → confirm replication slot configuration survived (needed for spec 009).
- Argo shows the Postgres operator and CR as `Synced`/`Healthy` after both the initial deploy and the post-recreation rebind.
- Fast validation (Helm/manifest rendering, k8s schema) on every change; full lifecycle test specifically required whenever the Postgres CR, StorageClass reference, or operator version changes.
