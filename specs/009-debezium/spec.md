# 009 — Debezium (CDC)

**Complexity:** High
**Risk:** Medium — functional correctness of a multi-system pipeline, not a persistence-safety risk (Debezium itself is stateless beyond its Kafka Connect offsets).
**Estimated cost:** ~1.5–2 days · AWS runtime cost: incremental (Kafka Connect worker pod(s)).
**Recommended model:** Opus — multi-system integration (Postgres WAL → Debezium → Kafka) is where subtle wiring bugs concentrate; this is exactly the kind of cross-component debugging that benefits from stronger reasoning.
**Depends on:** 007-postgres (logical replication enabled), 008-kafka (topics to publish into)
**Lifecycle class(es) touched:** Disposable

## Scope

Wires Debezium's PostgreSQL connector into a Kafka Connect deployment, completing the CDC pipeline described in architecture.md §15:

- Kafka Connect worker (Strimzi-managed `KafkaConnect`/`KafkaConnector` CRs, or standalone — prefer Strimzi's CRs to stay consistent with spec 008's operator).
- Debezium PostgreSQL connector configuration pointing at the Postgres cluster from spec 007's replication slot.
- Verification that committed transactions produce corresponding Kafka messages.

This pipeline runs unchanged on the `local` target (spec 021) — Debezium itself holds no persistent state, so the `aws`/`local` storage divergence in specs 005/007/008 doesn't affect it directly, though a `local` run inherits those specs' throwaway-data posture (no destroy/recreate proof needed).

Excludes: any application-side consumer of the CDC topics (out of scope — this is a platform capability, not an application), Debezium dashboards (010 covers monitoring, though this spec should expose connector health metrics).

## Requirements

1. The pipeline MUST be `Postgres WAL → logical decoding (pgoutput) → Debezium → Kafka`, exactly as architecture.md §15 specifies — no alternative CDC mechanism (e.g., polling) substitutes for this.
2. Only committed transactions MUST be represented in the CDC stream; consumers of these topics MUST be able to assume at-least-once delivery (architecture.md §15) — verify this explicitly rather than assuming Debezium's defaults are correct without checking.
3. Replication-slot health and WAL retention MUST be observable (architecture.md §15) — expose whatever metrics Debezium/Postgres provide for slot lag and WAL disk usage, ready for spec 010 to dashboard.
4. Kafka Connect / the Debezium connector is Argo-managed like everything else at this layer (constitution §2).
5. Debezium connector configuration (database credentials) MUST NOT contain plaintext secret values in Git — reference whatever minimal secret mechanism spec 007 used, pending the full Secrets Manager wiring in spec 013.

## Implementation hints

- Use Strimzi's `KafkaConnect` + `KafkaConnector` CRs rather than a bare Kafka Connect deployment — keeps the operator model consistent with spec 008 and gives you the same Argo-managed lifecycle.
- A replication slot that isn't actively consumed accumulates WAL and can fill disk — this is the most common way a Debezium lab setup silently breaks Postgres later; make slot/WAL monitoring a first-class requirement now, not an afterthought in spec 010.
- Test with a deliberately simple table first (a few columns, no exotic types) before assuming the pipeline handles the full range of Postgres data types Debezium supports.
- If the Kafka topics were pre-created in spec 008, confirm the connector's topic-naming convention matches; if left to auto-creation, confirm the auto-created topics get sane partition/replication settings for a lab (not defaults meant for production scale).

## Testing / acceptance criteria

- Insert/update/delete a row in the Postgres test table; confirm the corresponding CDC event appears on the expected Kafka topic with correct before/after payloads.
- Kill and restart the Kafka Connect worker; confirm it resumes from the correct offset/replication slot position without duplicating or dropping already-committed events (validates the at-least-once guarantee holds across a restart).
- Verify replication slot lag/WAL retention metrics are exposed and sane under normal load.
- No independent persistence proof needed here (Debezium itself holds no data that must survive EKS destruction — its state is Kafka Connect offsets, which live in Kafka, already covered by spec 008's persistence proof) — but the pipeline should be re-verified end-to-end as part of spec 007/008's destroy/recreate tests once this spec exists.
- Fast validation (Helm/manifest rendering, k8s schema) on connector configuration changes.
