# 006 — Karpenter

**Complexity:** Medium
**Risk:** Low–Medium — disposable-only, and bounded by design, so a misconfiguration mostly costs money rather than data.
**Estimated cost:** ~1 day · AWS runtime cost: bounded by design (~0–2 medium nodes max while workloads need them).
**Recommended model:** Sonnet — well-documented Karpenter NodePool/EC2NodeClass patterns.
**Depends on:** 003-network-and-eks (cluster + IAM), 004-argocd-bootstrap (Karpenter is Argo-installed)
**Lifecycle class(es) touched:** Disposable

## Scope

Installs Karpenter as the dynamic workload-capacity provisioner, bounded tightly per the constitution's cost rules:

- Karpenter controller (Argo-managed) running on the fixed system node group from spec 003.
- `NodePool`/`EC2NodeClass` (or equivalent) definitions bounding instance types and count.
- IAM role for Karpenter-provisioned nodes (the node-level IAM identity, distinct from the controller's own permissions which may need a small Terraform-side IAM piece for the controller's IRSA/Pod Identity role — see implementation hints).

Excludes: any actual workload that triggers scaling (those come with Postgres/Kafka/observability/Envoy in later specs).

## Requirements

1. Karpenter dynamic capacity MUST be bounded to approximately 0 minimum and ~2 medium-size nodes maximum (constitution §9, architecture.md §9) — do not broaden instance type or count constraints without explicit justification recorded in this spec or an ADR.
2. Karpenter itself (the controller) is Argo-managed, not Terraform-managed (constitution §2) — it runs as a workload on the system node group.
3. The IAM role/instance profile that Karpenter attaches to nodes it provisions may need a small Terraform-created piece (since it's an AWS IAM resource) even though the controller and its NodePool CRs are Argo-managed — this is a legitimate AWS-resource/Kubernetes-controller split, not an ownership violation, as long as Terraform only creates the IAM role and Argo only creates the Kubernetes-side CRs referencing it.
4. Node consolidation (scaling down to zero when idle) MUST be enabled — this is the mechanism that keeps disposable compute cost near zero between workload bursts.

## Implementation hints

- Follow the standard Karpenter-on-EKS pattern: a small Terraform snippet (likely added to spec 003's or a dedicated IAM module) creates the node IAM role/instance profile and the controller's own IAM role (via Pod Identity, per the security preference in constitution §5); Argo CD installs the Karpenter Helm chart and the `NodePool`/`EC2NodeClass` manifests.
- Constrain instance types explicitly (e.g., a small allow-list of medium general-purpose instance families) rather than leaving Karpenter free to pick anything — this is what makes the "~2 medium nodes max" bound enforceable rather than aspirational.
- Enable consolidation/expiration settings so idle nodes are terminated promptly — this is a cost control, not just a nicety, per constitution §9.
- Test scaling with a trivial throwaway deployment (e.g., a `Deployment` with a resource request that forces a new node) before any real workload depends on Karpenter.

## Testing / acceptance criteria

- A test workload with resource requests exceeding system-node capacity triggers Karpenter to provision a new node within the bounded instance types.
- Scaling the test workload to zero results in Karpenter terminating the provisioned node (consolidation working).
- Attempting to schedule a workload that would exceed the ~2-medium-node cap either queues/fails predictably rather than silently provisioning larger or more numerous nodes — confirms the bound is enforced, not just configured.
- Fast validation on the Helm/manifest rendering; no persistence proof needed here since Karpenter-provisioned nodes are inherently disposable and stateless.
