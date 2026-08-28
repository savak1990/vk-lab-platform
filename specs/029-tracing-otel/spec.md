# 029 — Tracing (Tempo + OpenTelemetry Collector)

**Complexity:** Medium

**Risk:** Low — non-critical observability path; the main risk is scope creep (instrumenting application code that doesn't exist in this platform-only repo).

**Estimated cost:** ~1–1.5 days · AWS runtime cost: incremental compute + storage for Tempo/OTel Collector pods; watch retention (constitution §9).

**Recommended model:** Sonnet — well-documented Helm chart configuration, low ambiguity once a real trace producer exists.

**Depends on:** 009-observability (Prometheus/Grafana/Loki/Alloy already running, Argo-managed pattern established), a real trace producer existing by this point (most likely Debezium from spec 026, or any application workload) — see ADR 0018.

**Lifecycle class(es) touched:** Disposable

## Scope

Completes the observability stack from architecture.md §19 by adding the two components spec 009 deferred per ADR 0018:

- Tempo (traces), Argo-managed, same pattern as the rest of the observability stack.
- OpenTelemetry Collector (telemetry pipeline), Argo-managed, receiving traces from whatever producer exists at implementation time and forwarding to Tempo.
- Grafana wiring so traces are queryable/correlated alongside the existing metrics/logs dashboards.

Excludes: instrumenting application code (no application code lives in this repo — the trace producer, if it's Debezium, emits traces the collector receives, not something this spec builds); S3-backed or otherwise durable trace storage (matches spec 009's `ebs-delete`, disposable-by-design precedent unless explicitly revisited here).

## Requirements

1. Tempo and the OpenTelemetry Collector MUST be Argo-managed (constitution §2) — no new Terraform beyond IAM if the collector needs AWS API access, consistent with spec 009's own constraint.
2. Retention MUST be kept small and cost-conscious (constitution §9), matching spec 009's existing Prometheus/Loki retention discipline — do not default to chart-default production-scale retention.
3. This spec MUST NOT be started before a real trace producer exists in the platform (ADR 0018) — do not stand up tracing infrastructure with nothing to trace; confirm the producer first.
4. Traces MUST be correlated with existing logs/metrics in Grafana (e.g. trace-to-log/trace-to-metric links), not left as an isolated, unintegrated data source.

## Implementation hints

- Revisit ADR 0018 before starting — it records exactly why this was deferred and what "a real trace producer" means in context.
- Tempo's own storage story mirrors Loki's from spec 009 (`SingleBinary`-equivalent mode with `ebs-delete`) unless a durable-trace requirement emerges that justifies more.
- Wire the OTel Collector as the single ingestion point (OTLP) rather than having producers push directly to Tempo — keeps future producers pluggable without re-wiring Tempo itself.

## Testing / acceptance criteria

- A deliberately triggered trace (e.g. from the real producer's own activity) is visible end-to-end in Grafana via Tempo.
- Retention settings verified against actual storage usage after a short soak period.
- Fast validation (Helm rendering, k8s schema); a `make down`/`make up` cycle confirms the stack reconciles back via Argo with no persistence proof required (trace data is disposable/non-critical by design, per spec 009's own precedent).
