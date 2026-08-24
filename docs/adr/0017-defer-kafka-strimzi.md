# ADR 0017: Kafka/Strimzi removed from the running platform, deferred to spec 024

## Status

Accepted

## Context

Kafka/Strimzi (originally spec 008, see ADR 0016 for its storage design) had no consumer yet — Debezium/CDC, its only planned reason to exist on this platform, hasn't landed. A running Strimzi operator, `Kafka`/`KafkaNodePool` CR, and their Terraform-owned EBS volume(s) cost on-demand node runtime and EBS storage continuously, for a workload nothing was reading from or writing to.

## Decision

Remove Kafka/Strimzi entirely from the running platform (GitOps templates, the `persistent/kafka-volumes` Terraform unit and its now-unused `ebs-volume` module, the committed cluster-ID file, and every script hook that referenced them), and destroy the EBS volume that had been provisioned.

The spec is renumbered `008-kafka` → `024-kafka` so it sits immediately before its only consumer, `025-debezium` (renumbered up from `024-debezium` to make room). `specs/024-kafka/spec.md` is marked deferred and should be re-implemented before work starts on `025-debezium`.

`karpenter.onDemand.az`, which existed solely to pin the on-demand Karpenter `NodePool`'s `topology.kubernetes.io/zone` to match Kafka's EBS volume AZ, is also removed rather than rewired to a new AZ source. It was redundant: the `EC2NodeClass` already restricts scheduling to a single subnet (and therefore a single AZ) via `karpenter.sh/discovery` tags, which are applied only to the one AZ-pinned EKS node subnet (itself derived from `root.hcl`'s `postgres_az` local, independent of Kafka). Postgres, the on-demand pool's remaining tenant, carries no AZ-pinning logic of its own and was never at risk from this removal.

ADR 0016's clusterId-pinning design (the committed constant, the `PostSync` patch Job, the documented pin-vs-Strimzi-reconcile race) remains valid and should be reused as-is when spec 024-kafka is re-implemented — nothing about that design was wrong, it just has no running workload to protect right now.

## Consequences

- No Kafka/Strimzi cost (compute or storage) while the platform has no CDC pipeline.
- `specs/024-kafka/spec.md` carries a status header pointing back here; re-implementing it should treat ADR 0016 as the reference design, not start over.
- Every cross-reference to "spec 008" (Kafka) and "spec 024" (Debezium, pre-renumbering) across specs/, docs/, and tests/ was updated in the same change that made this decision, so the spec dependency graph stays internally consistent rather than drifting into two inconsistent numbering schemes.
- `argo-up.sh`/`argo-down.sh`/`persistent-down.sh` no longer reference Kafka at all; re-implementing spec 024-kafka will need to re-add that plumbing (the `kafka_volumes_output` pattern in ADR 0016 is still the right shape to copy).
