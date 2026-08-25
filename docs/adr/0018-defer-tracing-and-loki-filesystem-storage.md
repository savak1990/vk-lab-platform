# ADR 0018: Defer tracing, Loki on filesystem storage, and non-standard acceptance alert for spec 009

## Status

Accepted

## Context

Spec 009 calls for the full observability stack from `docs/architecture.md` §19: Prometheus/Grafana (metrics),
Loki/Alloy (logs), and Tempo/OpenTelemetry Collector (traces) — wired to every major platform component built so
far.

In reality, at implementation time: Kafka/Strimzi was removed (ADR 0017, deferred to spec 024), and Envoy
Gateway/NLB (specs 010/011) were never built. The only running components are EKS, Karpenter, CNPG-managed
PostgreSQL, external-secrets, ebs-csi-driver, and Argo CD itself. There is no application code and no trace
producer anywhere in this platform-only repository.

Loki has two storage modes: "simple scalable" (requires S3 or another object store) and `SingleBinary` with
filesystem storage (no object store, no new IAM). This platform uses EKS Pod Identity exclusively (no IRSA
anywhere) and has no S3 buckets. Introducing one for Loki alone would need new Terraform (a bucket) and a new
Pod Identity association purely to serve a few days of lab log retention.

Spec 009 suggests "Postgres replication slot lag" as the acceptance-test alert. The current CNPG `Cluster` runs
`instances: 1` with no replicas and no Debezium-created logical replication slot (Debezium is spec 025) — there
is nothing for that alert to threaten today.

Separately: Prometheus (via the Prometheus Operator) has no application-aware snapshot/recovery mechanism, unlike
CNPG's `VolumeSnapshot`-based `bootstrap.recovery` (ADR 0013). The only way metrics/log data would survive a full
`make down`/`make up` cycle is the Kafka pattern instead (ADR 0008/0016): a Terraform-owned `aws_ebs_volume` in
the Persistent lifecycle class, `ebs-retain`, and a hand-written PV/PVC pair rebound on every `argo-up`.

## Decision

1. Tempo and the OpenTelemetry Collector are deferred, not implemented in spec 009. Revisit when an actual trace
   producer exists (most likely alongside spec 025's Debezium, or any future application workload).
2. Loki runs in `SingleBinary` deployment mode with `storage.type: filesystem`, backed by an `ebs-delete` PVC,
   not S3-backed "simple scalable" mode. This keeps the whole observability stack Argo-managed with zero new
   Terraform/IAM, consistent with spec 009's "Argo-managed only" requirement. Migrating to S3-backed mode later
   is a fresh install, not an in-place upgrade — do not attempt it as a quick values tweak.
3. The acceptance-test alert is `PodCrashLooping` (`increase(kube_pod_container_status_restarts_total[5m]) > 2`),
   not replication-slot lag, because it can be deliberately and safely triggered in the platform's current state
   (a throwaway imperative pod, e.g. `kubectl run crashloop --image=busybox --restart=Always -- /bin/false`). A
   replication-lag alert can be added once spec 025's Debezium creates a real logical replication slot to
   threaten. `PersistentVolumeNearlyFull` is kept as a standing cost-guard alert but is not used as the trigger —
   deliberately filling a live PVC to 90% risks wedging Prometheus's own TSDB.
4. Prometheus/Loki storage uses `ebs-delete` (data lost on `make down`) rather than the Kafka-style
   Terraform-owned `ebs-retain` static-PV pattern. The Prometheus Operator has no CNPG-style snapshot/recovery to
   build on; matching the Kafka pattern would mean reverse-engineering or hand-writing a StatefulSet-generated
   PVC name, and would move observability storage into the Persistent lifecycle class — a scope/lifecycle change
   spec 009's own "disposable, no persistence proof needed" framing doesn't call for. Metrics/logs survive
   routine pod restarts within a running cluster (the PVC is still there), just not a full teardown.

## Consequences

- No trace data exists until a future spec explicitly reintroduces Tempo/OTel — this is a deliberate gap, revisit
  at spec 025 or whenever application workloads land.
- Loki/Prometheus data does not survive `make down`/`make up` — acceptable per spec 009; only the *configuration*
  (Applications, dashboards-as-ConfigMaps, alert rules) is required to come back via GitOps reconciliation.
- If log volume ever needs to exceed a single filesystem PVC's practical size, migrating Loki to S3-backed mode
  is a breaking storage-config change, not an in-place upgrade.
- `PodCrashLooping`, not `PersistentVolumeNearlyFull`, is the mechanism used for spec 009's acceptance test.
