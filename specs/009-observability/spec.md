# 009 — Observability

**Status:** Implemented (aws target) — Tempo/OpenTelemetry Collector deferred to spec 029 per ADR 0018 (no trace producer exists yet); `local`-target `values-local.yaml` tracked under spec 022

**Complexity:** Medium–High
**Risk:** Low — non-critical path; the main risk is cost/retention creep, not correctness-critical failure.
**Estimated cost:** ~2–3 days (breadth, not depth — many components to wire, each individually simple) · AWS runtime cost: incremental compute + storage for the stack itself; watch retention settings closely (constitution §9).
**Recommended model:** Sonnet — mostly well-documented Helm chart configuration across many components.
**Depends on:** 003 through 025 (there must be something to observe: EKS, Karpenter, Postgres, Kafka all exist by now). Debezium (spec 026) lands after this spec — its dashboards are added retroactively, not a dependency of this spec's initial implementation.
**Lifecycle class(es) touched:** Disposable

## Scope

Deploys the full observability stack from architecture.md §19, wired to every platform component built so far:

- Prometheus (metrics), Grafana (visualization), Loki (logs), Alloy (Kubernetes log collection), Tempo (traces), OpenTelemetry Collector (telemetry pipeline) — all Argo-managed.
- Dashboards/scrape configs covering: Kubernetes cluster health, Karpenter, Envoy (dashboards ready even though Envoy itself lands in spec 010 — wire it there, stub here), AWS Load Balancer Controller, Kafka/Strimzi, PostgreSQL + operator. Debezium dashboards are deferred to spec 026 (Debezium lands last, after this spec) — added retroactively when that spec is implemented, not part of this spec's initial acceptance criteria.
- Basic alerting for the invariants that matter most in a lab (e.g., replication slot lag, disk pressure), not a full production alerting suite.

On the `local` target (spec 022), this stack runs a trimmed, laptop-scale subset (reduced replica counts, resource requests, and retention) — any component omitted for `local` MUST be stated explicitly in `values-local.yaml`, not silently dropped. See spec 022 for specifics.

Excludes: Envoy/NLB-specific dashboards' actual data source (those land with spec 010/011 — this spec should leave the scrape config ready, wired in once those exist), tracing instrumentation of any application code (out of scope — no application code in this repo), Debezium connector-health dashboards (deferred until spec 026 lands).

## Requirements

1. Every major platform component built so far MUST be observable (constitution §10) — Kubernetes, Karpenter, Kafka/Strimzi, PostgreSQL/operator at minimum, per the explicit list in both the constitution and architecture.md §19. Debezium is observable per the same rule once spec 026 adds it — not required of this spec's own acceptance criteria, since Debezium lands after this spec.
2. The stack itself is Argo-managed (constitution §2) — nothing in `terraform/` for this spec beyond IAM if OTel or an exporter needs AWS API access.
3. Observability retention MUST be kept small and cost-conscious (constitution §9) — this is explicitly named as something to avoid over-provisioning ("unnecessarily large observability retention").
4. New major components added later (Envoy in 010, NLB-facing metrics in 011, secrets-related audit logging in 012, Debezium connector/replication metrics in 024) SHOULD be wired into this stack as they're added, per constitution §10 — don't treat observability as a one-time setup that later specs are exempt from extending.

## Implementation hints

- The kube-prometheus-stack Helm chart (Prometheus + Grafana + Alertmanager + standard exporters) is a reasonable default backbone; add Loki/Alloy and Tempo/OTel Collector as separate charts alongside it rather than trying to force everything into one umbrella chart.
- Set retention explicitly and conservatively (e.g., a few days of metrics/logs, not the chart defaults which often assume production scale) — tie this directly to the cost-consciousness requirement rather than leaving it as a chart default.
- Scrape Strimzi's and the Postgres operator's own exported metrics rather than reinventing exporters — most mature operators already expose Prometheus-compatible metrics.
- Build dashboards incrementally per component rather than one monolithic dashboard — makes it easier to extend when Envoy/NLB/secrets observability land in later specs.
- Kafka consumer-lag dashboards deserve particular attention now; Debezium/replication-slot-lag dashboards follow the same pattern when spec 026 adds them, given that spec's warning about WAL bloat from stalled slots.

## Testing / acceptance criteria

- Grafana shows live dashboards for Kubernetes node/pod health, Karpenter scaling activity, Kafka broker/topic metrics, and Postgres connection/replication metrics. Debezium connector health is added to this list when spec 026 lands.
- Loki shows aggregated logs from at least the operators/controllers (Strimzi, Postgres operator, Argo CD) via Alloy.
- A basic alert (e.g., replication slot lag exceeding a threshold) fires correctly when deliberately triggered (e.g., pause a consumer and let lag grow).
- Retention settings are verified against actual storage usage after a short soak period — confirm they don't balloon disk/cost silently.
- Fast validation (Helm rendering, k8s schema) on every change; no persistence proof needed for the observability stack itself (its data is disposable/non-critical by design), though a `make down`/`make up` cycle should confirm dashboards and alerts come back automatically via Argo reconciliation.
