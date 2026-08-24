# 024 — Kafka

> **Status: Deferred (2026-08-24).** Kafka/Strimzi was removed from the
> running platform — see ADR 0017 — because nothing consumes it yet
> (Debezium, spec 025, is its only planned consumer and hasn't landed).
> Re-implement this spec before starting spec 025-debezium.

**Complexity:** High
**Risk:** Medium–High — same persistence-proof burden as Postgres, plus a real architectural choice (KRaft vs. ZooKeeper mode).
**Estimated cost:** ~2 days · AWS runtime cost: EBS volumes per broker + node cost while running.
**Recommended model:** Opus for the persistence proof and KRaft/ZooKeeper decision; Sonnet is fine for routine Strimzi CR boilerplate once the decision is made.
**Depends on:** 005-storage-contract (Retain StorageClass + rebind procedure), 006-karpenter (compute for brokers)
**Lifecycle class(es) touched:** Disposable (Strimzi operator, Kafka CRs) / Persistent (broker EBS volume data)

## Scope

Deploys Kafka via Strimzi, per architecture.md §14:

- Strimzi operator (Argo-managed).
- A `Kafka` CR in KRaft mode (no separate ZooKeeper — simpler, and the current upstream direction; record the choice) with persistent storage on the `Retain` StorageClass from spec 005.
- Broker sizing appropriate for a single-broker or minimal-multi-broker lab setup (no multi-AZ replication requirement — explicitly a non-goal per architecture.md §4).

This spec's persistence guarantee (Requirement 1, Retain-based storage) is `aws`-target-only. On the `local` target (spec 021), the same Strimzi/Kafka CR runs on the default local StorageClass with `Delete` semantics — data is throwaway, no rebind procedure needed.

Excludes: Debezium and its Kafka Connect deployment (023), Kafka-specific Grafana dashboards (009 covers this, though this spec should expose the metrics).

## Requirements

1. Kafka data MUST survive EKS deletion and recreation (constitution §4), using a Terraform-owned list of EBS volumes (`terraform/live/persistent/kafka-volumes`) statically bound to broker(s) via the raw PV/PVC rebind model spec 005 proves out, on the `Retain` StorageClass from spec 005. This is a deliberate divergence from Postgres (spec 007/007-1), which now uses CNPG's native VolumeSnapshot recovery instead (ADR 0013) — see ADR 0016 for why Kafka does not follow that same path.
2. Strimzi is a controller and MUST be Argo-managed (constitution §2); it MUST remain running until the `Kafka` CR it manages has completed cleanup — the constitution explicitly calls out "Kafka CR must be removed before Strimzi is removed" as a worked example (constitution §7).
3. KRaft vs. ZooKeeper mode is an architectural choice worth a one-line rationale in this spec (KRaft recommended: fewer moving parts, no separate ZooKeeper persistence/lifecycle to manage, and it's Strimzi's forward direction).
4. No multi-AZ replication or full HA is required or expected (architecture.md §4 non-goals) — a single-broker or small fixed-broker-count setup is appropriate for a lab.
5. No destructive reclaim policy in the storage path (constitution §4) — reuse the `Retain` StorageClass, don't introduce a new one.

## Implementation hints

- KRaft mode removes an entire persistence/lifecycle-ordering problem (ZooKeeper's own data and shutdown ordering relative to brokers) — strongly prefer it over ZooKeeper mode for this lab unless there's a specific reason to teach the older architecture.
- Broker resource sizing again exercises Karpenter (spec 006) — keep it inside the ~2-medium-node budget alongside whatever Postgres already needs, or plan for Postgres and Kafka to time-share capacity rather than both being resident simultaneously if the budget is tight.
- Topic creation for Debezium's eventual output topics can either be pre-created here or left to Debezium's auto-topic-creation in spec 025 — document whichever choice is made so spec 025 doesn't have to re-derive it.
- Kafka is spec 005's raw PV/PVC rebind procedure's first real production consumer (Postgres moved off it under ADR 0013) — the volume side is Terraform-owned (ADR 0016) rather than hand-run, but the underlying storage-layer mechanism is spec 005's, unmodified.

## Testing / acceptance criteria

- Full lifecycle proof required, same shape as spec 007: CREATE → VERIFY Kafka healthy (broker(s) `Ready`, can produce/consume a test topic) → WRITE test messages to a test topic → DESTROY the disposable EKS stack → VERIFY broker EBS volume(s) persisted → RECREATE and reinstall Strimzi via Argo → VERIFY the test topic and its messages are recoverable via the rebind procedure. See `tests/manual/024-kafka.md` for the step-by-step walkthrough.
- Deletion-ordering check: deleting the `Kafka` CR while Strimzi is still running cleans up broker resources correctly; Strimzi itself is only removed afterward (constitution §7's own example, made concrete).
- Fast validation (Helm/manifest rendering, k8s schema) on every change; full lifecycle test required whenever the `Kafka` CR, StorageClass reference, or Strimzi version changes.
