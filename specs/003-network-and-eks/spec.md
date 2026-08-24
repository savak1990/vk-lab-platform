# 003 — Network and EKS

**Complexity:** Medium
**Risk:** Medium — disposable-lifecycle, so mistakes cost a destroy/recreate cycle rather than lasting damage; running in the default VPC's public subnets trades some network isolation for simplicity, an accepted trade-off for now (see Requirements).
**Estimated cost:** ~1 day · AWS runtime cost: EKS control plane ~$0.10/hr + system node instance cost while `make up` is active. No NAT Gateway cost, since default-VPC public subnets are used directly.
**Recommended model:** Sonnet — standard EKS Terraform module usage; escalate to Opus only if IAM role trust or security-group edge cases get gnarly.
**Depends on:** 001-bootstrap (IAM/OIDC)
**Lifecycle class(es) touched:** Disposable

## Scope

Creates the EKS cluster and its fixed system capacity, **in the AWS account's default VPC** — a dedicated persistent VPC is explicitly out of scope until spec 020:

- EKS control plane, launched into the default VPC's default (public) subnets.
- One fixed-size system managed node group, sized only for critical controllers (Argo CD, Karpenter controller, AWS Load Balancer Controller — installed in later specs, but this node group must exist for them to land on).
- EKS-managed add-ons appropriate to manage through Terraform (e.g., VPC CNI, kube-proxy, CoreDNS) per architecture.md §7 ("AWS-managed EKS add-ons may be managed through Terraform").
- IAM roles for the cluster and node group, and security groups scoped tightly enough to compensate for running in a public, shared-by-default network.

Excludes: any dedicated/custom VPC (spec 020), Karpenter itself (006 — Karpenter is Argo-managed, this spec only provides the fixed system capacity it runs on), Argo CD installation (004), any workload.

## Requirements

1. EKS control plane and system node group are Disposable-lifecycle — created by `terraform/live/disposable/` and destroyed by `make down` (constitution §3, architecture.md §6).
2. The cluster and node group MUST run in the AWS account's **default VPC**, using its default public subnets — no VPC is created by this repository yet. This is an intentional, temporary simplification (see architecture.md §10): nodes will have public IPs as a result. A dedicated, more isolated persistent VPC is deferred to spec 020 and MUST NOT be built prematurely here.
3. Because nodes sit in public subnets, security groups MUST be scoped tightly (cluster/node communication only, no broad inbound access) to partially compensate for the lack of network-layer isolation — this is not a substitute for a real VPC, just a mitigation until spec 020.
4. System node group MUST be sized only for controllers, not workloads — Karpenter (spec 006) is responsible for workload capacity, kept separately bounded per constitution §9.
5. EKS-managed add-ons handled here (CNI, kube-proxy, CoreDNS) are the only Kubernetes-adjacent things Terraform owns at this layer — everything else installed onto the cluster is Argo CD's responsibility from spec 004 onward (constitution §2).
6. IAM roles created here MUST be scoped to only what the cluster/node group needs — no broad admin roles.
7. Every resource here MUST carry the platform's standard tags (constitution §16) with `Lifecycle=disposable`, inherited from this stack's `default_tags` provider block — this also makes it easy to confirm, via a tag-based resource search, that a `terraform destroy` actually removed everything disposable-tagged.

## Implementation hints

- `terraform/live/disposable/` is its own Terragrunt stack/state, separate from bootstrap and persistent, so `make down` can destroy this without touching the Route 53 zone/ACM certificate from spec 002.
- Use a well-maintained community EKS Terraform module rather than hand-rolling control-plane/node-group resources — reduces surface area for IAM/security-group mistakes. Most such modules accept an existing VPC/subnet ID list, so pointing them at the default VPC's subnets (via a data source, not a hardcoded ID) is a small, well-supported configuration, not a workaround.
- Keep the system node group small (e.g., 1–2 small/medium instances) — it only needs to run controllers, not application or data workloads.
- Note for spec 020: record which AZs the default VPC's subnets used here, since any EBS volumes created later (specs 005/007/024) will be locked to those AZs — this matters when planning the eventual move to a dedicated VPC.
- This is the first spec where a full `make up` produces a real, billable AWS resource that must be cleanly destroyed — get comfortable with `terraform destroy` on this stack before building anything on top.

## Testing / acceptance criteria

- `terraform apply` produces a healthy EKS cluster reachable via `kubectl` (using the OIDC/IAM auth wired in spec 001), running in the default VPC.
- System node group registers as `Ready` in `kubectl get nodes`, and nodes are confirmed to be in the default VPC's public subnets (expected, not a bug, per requirement 2).
- Security groups are confirmed to deny unexpected inbound access despite the public subnet placement (e.g., a port scan from outside the cluster's own security groups finds nothing open beyond what's intentionally exposed).
- `terraform destroy` on the disposable stack removes the cluster and node group cleanly, with zero effect on the Route 53 zone/ACM resources from spec 002 (verify by re-`terraform plan`-ing the persistent stack afterward — it should show no drift), and with zero effect on the default VPC itself (it's not owned by this repo, so nothing here should attempt to modify or destroy it).
- Fast validation (fmt, validate, plan) on every change; this spec's own destroy/recreate is exercised manually now, and folded into the full lifecycle test once spec 014 exists.
