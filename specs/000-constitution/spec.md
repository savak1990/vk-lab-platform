# Platform Constitution

## 1. Repository Scope

This repository is platform-only.

It may contain:
- Terraform/Terragrunt
- GitOps configuration
- Kubernetes operators/controllers
- shared platform services
- CI/CD
- platform tests
- specifications and architecture documentation

It MUST NOT contain business application source code.

---

## 2. Infrastructure Ownership

Terraform/Terragrunt owns AWS infrastructure.

Argo CD owns Kubernetes-native resources after bootstrap.

Terraform may install the initial Argo CD instance and root Application.

Terraform and Argo CD MUST NOT manage the same Kubernetes resource.

---

## 3. Lifecycle Separation

All infrastructure MUST belong to exactly one lifecycle class:

### State
Essentially never destroyed (see ADR 0004, amended by ADR 0005):
- the Terraform remote-state S3 bucket itself

This is the one resource that cannot remote-store its own Terraform state
on a true first run (the bucket it would store state in doesn't exist
yet). Splitting it into its own layer below Bootstrap avoids the
self-referential problem: destroy (`make state-down`, guarded, essentially
never run) bypasses Terraform entirely, so there is no final state write to
fail. See `terraform/live/state/README.md`, ADR 0004, and ADR 0005.

### Bootstrap
Rarely destroyed:
- Terraform backend
- GitHub OIDC
- foundational IAM
- KMS

### Persistent
Must survive normal `make down`:
- VPC (deferred — see §15; the AWS account's default VPC is used until a dedicated VPC spec is implemented)
- Route 53 (the delegated `lab.<root-domain>` hosted zone — see §14; NOT the parent/root hosted zone, which is external)
- ACM (the lab subdomain certificate — see §14)
- Secrets Manager
- RDS
- retained EBS data
- persistent S3 resources

### Disposable
Created by `make up`, removed by `make down`:
- EKS
- worker nodes
- Karpenter nodes
- Argo CD
- ALB
- Envoy
- Kubernetes workloads
- observability workloads

A normal disposable-stack destroy MUST NOT destroy persistent resources.

---

## 4. Persistence Safety

Persistent data MUST survive EKS deletion and recreation.

For stateful Kubernetes workloads:
- destructive reclaim policies MUST NOT be used for data intended to persist;
- persistent-volume lifecycle MUST be explicitly tested;
- recreation and reattachment/restoration MUST be documented;
- shutdown MUST fail safely if persistence invariants are not satisfied.

Persistence assumptions MUST be verified against actual AWS resources, not only Kubernetes objects.

---

## 5. Security

No plaintext secrets may be committed to Git.

No long-lived AWS access keys may be required by GitHub Actions.

GitHub Actions MUST authenticate to AWS through OIDC and temporary credentials.

Kubernetes workloads SHOULD use EKS Pod Identity or an equivalent workload identity mechanism.

Runtime secrets MUST be stored in AWS Secrets Manager.

Helm and GitOps configuration may contain secret identifiers but MUST NOT contain secret values.

Where a secret or private configuration value is committed to Git in KMS-encrypted form, each value MUST be its own ciphertext file under `secrets/` (e.g. `secrets/root-domain.enc`). Secrets MUST NOT be combined into a single committed ciphertext file (see §14).

---

## 6. GitOps

Argo CD is the source of truth for Kubernetes desired state.

Manual modifications to Argo-managed resources are considered temporary drift.

Kubernetes dependency ordering SHOULD be expressed through:
- sync waves
- hooks
- finalizers
- controller reconciliation

Custom scripts MUST NOT duplicate dependency logic that belongs naturally in Argo CD or Kubernetes controllers.

---

## 7. Controller Cleanup

A controller MUST remain alive until resources it manages have completed cleanup.

Examples:
- Kafka resources are removed before Strimzi.
- PostgreSQL CRs are removed before the PostgreSQL operator.
- ALB-triggering resources are removed before AWS Load Balancer Controller.
- Gateway resources are removed before Envoy Gateway.

EKS MUST NOT be destroyed while required external-resource cleanup is still pending.

---

## 8. Public Traffic

The intended public path is:

Client
→ Route 53
→ AWS ALB
→ Envoy Gateway
→ Kubernetes workload

ALB owns AWS ingress and TLS termination.

Envoy owns application-layer routing and traffic policy.

Routing logic SHOULD NOT be duplicated between ALB and Envoy.

Route 53 in this path refers to the platform's delegated `lab.<root-domain>` hosted zone, not the external parent/root hosted zone — see §14.

---

## 9. Compute and Cost

The platform is an educational environment and MUST be cost-conscious.

Karpenter dynamic capacity MUST be bounded.

The initial target is approximately:
- 0 minimum dynamic worker nodes
- maximum capacity equivalent to about 2 medium-sized worker nodes

New always-on or expensive AWS resources require explicit justification.

Unnecessary NAT Gateways, oversized compute, and production-grade HA SHOULD be avoided unless required by a spec.

---

## 10. Observability

Major platform components MUST be observable.

The standard stack is:
- Prometheus
- Grafana
- Loki
- Alloy
- Tempo
- OpenTelemetry Collector

New major components SHOULD provide:
- metrics
- logs
- health information
- alerts where operationally important

---

## 11. CI/CD

Every pull request MUST receive appropriate fast validation.

Fast validation SHOULD include applicable:
- Terraform formatting and validation
- Terragrunt validation
- Terraform plan
- Helm rendering
- Kubernetes schema validation
- YAML linting
- security/static checks

Infrastructure-critical changes MUST remain compatible with the full lifecycle test:

CREATE
→ VERIFY
→ WRITE DATA
→ DESTROY
→ VERIFY PERSISTENCE
→ RECREATE
→ VERIFY RECOVERY
→ DESTROY
→ VERIFY NO LEAKS

CI infrastructure MUST be isolated from the personal lab environment.

Untrusted public pull requests MUST NOT receive privileged AWS deployment access.

---

## 12. Definition of Done

A platform feature is not complete merely because configuration renders or Terraform validates.

The relevant acceptance criteria and tests MUST pass.

For stateful or lifecycle-sensitive changes, destruction and recreation behavior MUST be explicitly considered and tested.

---

## 13. Architectural Changes

If implementation requires violating or changing this constitution:

1. Do not silently work around the rule.
2. Document the conflict.
3. Create or update an ADR.
4. Update the constitution/architecture intentionally before implementation proceeds.

---

## 14. DNS Domain Ownership and Configuration

The platform does NOT own the root domain or its parent Route 53 hosted zone. Both are external, pre-existing infrastructure managed outside this repository.

The platform owns a delegated subdomain, `lab.<root-domain>`, and an ACM certificate covering `lab.<root-domain>` and `*.lab.<root-domain>`. Both are Persistent-lifecycle (§3).

Delegating `lab.<root-domain>` from the parent hosted zone (creating NS records in the parent zone) is a one-time external/manual bootstrap step, outside this repository's normal `make up`/`make down` lifecycle, unless an existing documented bootstrap mechanism already covers it.

The platform MUST NOT require write access to the parent/root hosted zone during normal operation.

`make down` MUST NOT delete the delegated `lab.<root-domain>` hosted zone, the ACM certificate, or the parent/root hosted zone.

Disposable DNS records inside the delegated lab hosted zone (for example, a record pointing at the ALB) MAY be created and destroyed as part of normal disposable-lifecycle operation. Ownership of such records MUST be explicit and MUST NOT overlap between Terraform and Kubernetes controllers.

The existing root-domain ACM certificate MUST NOT be reused for the platform, and the ACM certificate MUST be created in the same AWS region as the ALB that uses it, validated via DNS against the delegated `lab.<root-domain>` zone, unless a later ADR changes this decision.

The real root domain value is private configuration, not a security credential — keeping it out of the public repository is repository hygiene, not a security control. It MUST NOT be committed in plaintext anywhere in this repository. It MUST be sourced through the same KMS-encrypted bootstrap mechanism as other bootstrap configuration (§5) — its own dedicated ciphertext file, `secrets/root-domain.enc`, not combined with any other secret — and supplied to Terraform at apply time rather than hardcoded into Terraform variables, tfvars, YAML, Helm values, or documentation.

Documentation and examples MUST use placeholders (`<root-domain>`, `lab.<root-domain>`, `api.lab.<root-domain>`) instead of any real domain value.

Because the domain value is used to create real Route 53 and ACM resources, it will necessarily appear in the persistent stack's Terraform state. This constitution does not claim the domain can be fully hidden from Terraform state — the persistent stack's remote state MUST be treated as a private, access-controlled artifact as a result.

---

## 15. VPC Deferral

A dedicated, platform-owned VPC is intentionally out of scope for the initial specs. EKS and everything built on it run in the AWS account's default VPC and default public subnets until a dedicated VPC spec is implemented.

This is a deliberate simplicity/cost trade-off (§9), not an oversight. The accepted consequence is that EKS nodes have public IPs; security groups MUST be scoped tightly to compensate in the meantime.

The default VPC is not created or destroyed by this platform — it is not itself a resource in any lifecycle class this repository manages.

When a dedicated VPC is introduced, it MUST be Persistent-lifecycle (§3). Migrating from the default VPC to a dedicated one requires a full disposable-stack recreation (EKS cannot move VPCs in place) and MUST account for AZ-locked EBS volumes holding retained data (§4) — either by matching the new VPC's subnets to the AZs already in use, or by a documented volume-migration procedure.

---

## 16. Resource Tagging

Every AWS resource created by this repository's Terraform MUST be tagged so it is identifiable as belonging to this platform, distinguishable from any future business/service infrastructure, and traceable to its lifecycle class. Tagging is an identity and ownership requirement, not only a lifecycle-tracking convenience.

At minimum, every Terraform-managed resource MUST carry:

- `Project = vk-lab-platform` — identifies the resource as belonging to this repository/platform, distinct from any other project or unrelated resource in the same AWS account.
- `Scope = platform` — marks the resource as platform infrastructure, not a business/application service, reinforcing at the AWS resource level the repository-scope rule in §1 (this repository contains platform code only).
- `Lifecycle = state | bootstrap | persistent | disposable` — the resource's lifecycle class (§3).
- `ManagedBy = terraform` — distinguishes Terraform-owned resources from resources created indirectly by Argo CD-managed Kubernetes controllers (e.g., an ALB created by the AWS Load Balancer Controller), reinforcing the ownership boundary in §2.

Default tags SHOULD be applied at the provider level (e.g., a Terraform `default_tags` block established in the bootstrap stack and inherited by every later stack) rather than repeated per resource, so the rule cannot be silently skipped when a new resource is added.

Resources created indirectly by Kubernetes controllers (ALB, Route 53 records via `external-dns`, EBS volumes via the CSI driver) SHOULD carry equivalent tags or labels where the controller supports it, so the same identification standard holds across the Terraform/Argo ownership boundary, not only for Terraform-created resources.

---

## 17. Lifecycle Command Surface

Each lifecycle class (State, Bootstrap, Persistent, Disposable — §3) MUST have its own explicit create command. No command may implicitly create or destroy a different lifecycle class's resources.

- `make state-up` creates the State layer (the Terraform state S3 bucket). `make state-down` destroys it — see §3, ADR 0004, and ADR 0005. This is expected to run essentially never; it MUST require an explicit confirmation step and MUST refuse to run while Bootstrap, Persistent, Disposable, or CI state still exists. Never invoked by `make bootstrap-down` or any other command.
- `make bootstrap-up` creates Bootstrap-lifecycle resources; it MUST verify the State layer already exists first and MUST fail with an actionable error if it does not — it MUST NOT create the State layer on the caller's behalf. `make bootstrap-down` destroys Bootstrap resources; this repository does not expect `make bootstrap-down` to run against a live environment in normal operation. It MUST require an explicit, separate confirmation step and MUST refuse to run while Persistent or Disposable resources still exist.
- `make persistent-up` creates Persistent-lifecycle resources. `make persistent-down` destroys them — including retained EBS volumes and everything in Secrets Manager — permanently. This is a deliberate, rarely-used, explicit action, never a side effect of `make down`. `make persistent-down` MUST require an explicit confirmation step and MUST refuse to run while any Disposable-lifecycle resource still exists (the same controller-cleanup ordering principle as §7: Disposable resources that reference Persistent ones, such as DNS records inside the lab hosted zone, MUST be gone first).
- `make up` creates Disposable-lifecycle resources. It MUST verify Persistent-lifecycle resources already exist before proceeding, and MUST fail with an actionable error if they do not — it MUST NOT create Persistent resources on the caller's behalf. `make down` destroys Disposable-lifecycle resources only (§3); it MUST NOT touch Persistent or Bootstrap resources.

A command that destroys Persistent or Bootstrap resources is a different, explicit, rarely-invoked action from the routine `make up`/`make down` cycle, and MUST be presented and guarded as such — not folded into, or reachable as a side effect of, routine shutdown.