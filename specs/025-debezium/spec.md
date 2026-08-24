# 025 — Debezium (CDC)

**Complexity:** High
**Risk:** Medium — functional correctness of a multi-system pipeline, not a persistence-safety risk (Debezium itself is stateless beyond its Kafka Connect offsets).
**Estimated cost:** ~1.5–2 days · AWS runtime cost: incremental (Kafka Connect worker pod(s)).
**Recommended model:** Opus — multi-system integration (Postgres WAL → Debezium → Kafka) is where subtle wiring bugs concentrate; this is exactly the kind of cross-component debugging that benefits from stronger reasoning.
**Depends on:** 007-postgres (logical replication enabled), 024-kafka (topics to publish into), 012-secrets (this spec lands after secrets, so it consumes the real Secrets Manager mechanism directly rather than a placeholder), 009-observability and 013-lifecycle (both were deliberately implemented without Debezium coverage since this spec lands last — this spec retroactively adds Debezium's dashboards to 009 and its CDC verification step back into 013's and 018's lifecycle tests)
**Lifecycle class(es) touched:** Disposable

## Scope

Wires Debezium's PostgreSQL connector into a Kafka Connect deployment, completing the CDC pipeline described in architecture.md §15:

- Kafka Connect worker (Strimzi-managed `KafkaConnect`/`KafkaConnector` CRs, or standalone — prefer Strimzi's CRs to stay consistent with spec 024's operator).
- Debezium PostgreSQL connector configuration pointing at the Postgres cluster from spec 007's replication slot.
- Verification that committed transactions produce corresponding Kafka messages.

This pipeline runs unchanged on the `local` target (spec 021) — Debezium itself holds no persistent state, so the `aws`/`local` storage divergence in specs 005/007/024 doesn't affect it directly, though a `local` run inherits those specs' throwaway-data posture (no destroy/recreate proof needed).

Excludes: any application-side consumer of the CDC topics (out of scope — this is a platform capability, not an application). Debezium dashboards themselves are in scope here (not excluded): spec 009 (observability) was implemented without them, on the understanding that this spec adds them once it lands.

## Requirements

1. The pipeline MUST be `Postgres WAL → logical decoding (pgoutput) → Debezium → Kafka`, exactly as architecture.md §15 specifies — no alternative CDC mechanism (e.g., polling) substitutes for this.
2. Only committed transactions MUST be represented in the CDC stream; consumers of these topics MUST be able to assume at-least-once delivery (architecture.md §15) — verify this explicitly rather than assuming Debezium's defaults are correct without checking.
3. Replication-slot health and WAL retention MUST be observable (architecture.md §15) — expose whatever metrics Debezium/Postgres provide for slot lag and WAL disk usage, and add the corresponding dashboards to spec 009's Grafana stack (deferred there, delivered here).
4. Kafka Connect / the Debezium connector is Argo-managed like everything else at this layer (constitution §2).
5. Debezium connector configuration (database credentials) MUST NOT contain plaintext secret values in Git — this spec lands after spec 013 (Secrets Manager + Pod Identity), so it MUST use that real mechanism directly from the start; no placeholder-then-migrate step applies here, unlike Postgres (007) and Kafka (024), which predate spec 013.
6. This spec MUST retroactively amend spec 014 (Lifecycle) and spec 019 (CI Full Lifecycle Validation): both were implemented with CDC verification deliberately deferred, and this spec restores the "write Kafka test data → verify CDC" step to their acceptance-test sequences.

## Implementation hints

- Use Strimzi's `KafkaConnect` + `KafkaConnector` CRs rather than a bare Kafka Connect deployment — keeps the operator model consistent with spec 024 and gives you the same Argo-managed lifecycle.
- A replication slot that isn't actively consumed accumulates WAL and can fill disk — this is the most common way a Debezium lab setup silently breaks Postgres later; make slot/WAL monitoring a first-class requirement now, wired into spec 009's dashboards, not an afterthought.
- Test with a deliberately simple table first (a few columns, no exotic types) before assuming the pipeline handles the full range of Postgres data types Debezium supports.
- If the Kafka topics were pre-created in spec 024, confirm the connector's topic-naming convention matches; if left to auto-creation, confirm the auto-created topics get sane partition/replication settings for a lab (not defaults meant for production scale).

## Testing / acceptance criteria

- Insert/update/delete a row in the Postgres test table; confirm the corresponding CDC event appears on the expected Kafka topic with correct before/after payloads.
- Kill and restart the Kafka Connect worker; confirm it resumes from the correct offset/replication slot position without duplicating or dropping already-committed events (validates the at-least-once guarantee holds across a restart).
- Verify replication slot lag/WAL retention metrics are exposed and sane under normal load.
- No independent persistence proof needed here (Debezium itself holds no data that must survive EKS destruction — its state is Kafka Connect offsets, which live in Kafka, already covered by spec 024's persistence proof) — but the pipeline should be re-verified end-to-end as part of spec 007/024's destroy/recreate tests once this spec exists.
- Fast validation (Helm/manifest rendering, k8s schema) on connector configuration changes.
- Grafana (spec 009) shows live Debezium connector-health and replication-slot-lag dashboards — confirms the retroactive amendment to spec 009 (Requirement 3 above).
- A full `make up` → write Postgres/Kafka test data → verify CDC → `make down` → `make up` → verify CDC still works run, per spec 014's restored lifecycle-test steps, passes end to end (Requirement 6 above).
