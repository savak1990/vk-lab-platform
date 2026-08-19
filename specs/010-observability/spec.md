# 010 — Observability

**Complexity:** Medium–High
**Risk:** Low — non-critical path; the main risk is cost/retention creep, not correctness-critical failure.
**Estimated cost:** ~2–3 days (breadth, not depth — many components to wire, each individually simple) · AWS runtime cost: incremental compute + storage for the stack itself; watch retention settings closely (constitution §9).
**Recommended model:** Sonnet — mostly well-documented Helm chart configuration across many components.
**Depends on:** 003 through 009 (there must be something to observe: EKS, Karpenter, Postgres, Kafka, Debezium all exist by now)
**Lifecycle class(es) touched:** Disposable

## Scope

Deploys the full observability stack from architecture.md §19, wired to every platform component built so far:

- Prometheus (metrics), Grafana (visualization), Loki (logs), Alloy (Kubernetes log collection), Tempo (traces), OpenTelemetry Collector (telemetry pipeline) — all Argo-managed.
- Dashboards/scrape configs covering: Kubernetes cluster health, Karpenter, Envoy (dashboards ready even though Envoy itself lands in spec 011 — wire it there, stub here), AWS Load Balancer Controller, Kafka/Strimzi, PostgreSQL + operator, Debezium.
- Basic alerting for the invariants that matter most in a lab (e.g., replication slot lag, disk pressure), not a full production alerting suite.

Excludes: Envoy/ALB-specific dashboards' actual data source (those land with spec 011/012 — this spec should leave the scrape config ready, wired in once those exist), tracing instrumentation of any application code (out of scope — no application code in this repo).

## Requirements

1. Every major platform component built so far MUST be observable (constitution §10) — Kubernetes, Karpenter, Kafka/Strimzi, PostgreSQL/operator, Debezium at minimum, per the explicit list in both the constitution and architecture.md §19.
2. The stack itself is Argo-managed (constitution §2) — nothing in `terraform/` for this spec beyond IAM if OTel or an exporter needs AWS API access.
3. Observability retention MUST be kept small and cost-conscious (constitution §9) — this is explicitly named as something to avoid over-provisioning ("unnecessarily large observability retention").
4. New major components added later (Envoy in 011, ALB-facing metrics in 012, secrets-related audit logging in 013) SHOULD be wired into this stack as they're added, per constitution §10 — don't treat observability as a one-time setup that later specs are exempt from extending.

## Implementation hints

- The kube-prometheus-stack Helm chart (Prometheus + Grafana + Alertmanager + standard exporters) is a reasonable default backbone; add Loki/Alloy and Tempo/OTel Collector as separate charts alongside it rather than trying to force everything into one umbrella chart.
- Set retention explicitly and conservatively (e.g., a few days of metrics/logs, not the chart defaults which often assume production scale) — tie this directly to the cost-consciousness requirement rather than leaving it as a chart default.
- Scrape Strimzi's and the Postgres operator's own exported metrics rather than reinventing exporters — most mature operators already expose Prometheus-compatible metrics.
- Build dashboards incrementally per component rather than one monolithic dashboard — makes it easier to extend when Envoy/ALB/secrets observability land in later specs.
- Debezium/replication-slot-lag and Kafka consumer-lag dashboards deserve particular attention given spec 009's warning about WAL bloat from stalled slots.

## Testing / acceptance criteria

- Grafana shows live dashboards for Kubernetes node/pod health, Karpenter scaling activity, Kafka broker/topic metrics, Postgres connection/replication metrics, and Debezium connector health.
- Loki shows aggregated logs from at least the operators/controllers (Strimzi, Postgres operator, Argo CD) via Alloy.
- A basic alert (e.g., replication slot lag exceeding a threshold) fires correctly when deliberately triggered (e.g., pause a consumer and let lag grow).
- Retention settings are verified against actual storage usage after a short soak period — confirm they don't balloon disk/cost silently.
- Fast validation (Helm rendering, k8s schema) on every change; no persistence proof needed for the observability stack itself (its data is disposable/non-critical by design), though a `make down`/`make up` cycle should confirm dashboards and alerts come back automatically via Argo reconciliation.
