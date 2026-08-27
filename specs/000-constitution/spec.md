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

All infrastructure MUST belong to exactly one lifecycle class. This applies to the `aws` execution target only — the `local` target's cluster and workloads are not governed by this taxonomy at all; see §18.

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
- VPC (platform-owned, public subnets only, no NAT — see §15)
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
- NLB
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

Exactly one GitHub OIDC provider MUST exist per AWS account, created once as Bootstrap-lifecycle infrastructure (§3) and never recreated or destroyed by `make up`/`make down`/`make bootstrap-down`. It is account-level and region-agnostic — the same provider is reused regardless of which region a given stack deploys into. Individual IAM roles trusting that provider are a separate, per-consumer concern (e.g. a personal-lab deploy role, a privileged CI full-environment-test role) and MAY be created independently by whichever spec needs one; no spec MUST create a second provider (see ADR 0007).

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
- NLB-triggering resources are removed before AWS Load Balancer Controller.
- Gateway resources are removed before Envoy Gateway.

EKS MUST NOT be destroyed while required external-resource cleanup is still pending.

---

## 8. Public Traffic

The intended public path is:

Client
→ Route 53
→ AWS NLB
→ Envoy Gateway
→ Kubernetes workload

The NLB owns AWS ingress and TLS termination (an NLB TLS listener using the
persistent ACM certificate, §14) — there is no AWS-side Ingress/Gateway
routing resource; the NLB forwards directly to Envoy Gateway's own Service.

Envoy owns application-layer routing and traffic policy.

Routing logic SHOULD NOT be duplicated between the NLB and Envoy — the NLB
performs no host/path routing at all.

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

A required GitHub status check MUST NOT itself be path-filtered in a way that lets it stay pending forever — fast validation MUST include an always-running gate job that reports a result (success or explicit skip) for every change category, fanning out to path-filtered sub-jobs rather than exposing them directly as required checks.

CI infrastructure MUST be isolated from the personal lab environment. Full-lifecycle validation runs against one shared, isolated `ci/persistent`/`ci/disposable` environment, tagged `Ephemeral=true` (§16) so a scheduled cleanup job can find leftovers. Runs MUST be serialized — a GitHub Actions concurrency group MUST queue successive triggers rather than let two runs race against the same environment (ADR 0007).

Untrusted public pull requests MUST NOT receive privileged AWS deployment access.

Platform verification against a running environment (kind or real EKS) MUST be expressed as a real test suite (spec 022) reused across both targets, not duplicated bash scripts per environment.

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

The persistent stack's Terraform MAY manage the single NS record set delegating `lab.<root-domain>` from the parent hosted zone, locating the parent zone by name (not by an explicit zone-ID input) and creating/removing only that one record — it MUST NOT create, delete, or otherwise manage the parent zone itself, and MUST NOT manage any other record inside it. `make persistent-up` creates this delegation record as part of applying the `route53` unit; `make persistent-down` removes it as part of destroying that same unit. If the real root domain is not itself a Route 53 hosted zone reachable with the credentials in use, this automated delegation does not apply and delegation remains a one-time external/manual bootstrap step, outside this repository's normal `make up`/`make down` lifecycle.

The platform MUST NOT create or delete the parent/root hosted zone during normal operation, and MUST NOT manage any record inside it other than the single delegation NS record described above.

`make down` MUST NOT delete the delegated `lab.<root-domain>` hosted zone, the ACM certificate, or the parent/root hosted zone.

Disposable DNS records inside the delegated lab hosted zone (for example, a record pointing at the NLB) MAY be created and destroyed as part of normal disposable-lifecycle operation. Ownership of such records MUST be explicit and MUST NOT overlap between Terraform and Kubernetes controllers.

The existing root-domain ACM certificate MUST NOT be reused for the platform, and the ACM certificate MUST be created in the same AWS region as the NLB that uses it, validated via DNS against the delegated `lab.<root-domain>` zone, unless a later ADR changes this decision.

The real root domain value is private configuration, not a security credential — keeping it out of the public repository is repository hygiene, not a security control. It MUST NOT be committed in plaintext anywhere in this repository. It MUST be sourced through the same KMS-encrypted bootstrap mechanism as other bootstrap configuration (§5) — its own dedicated ciphertext file, `secrets/root-domain.enc`, not combined with any other secret — and supplied to Terraform at apply time rather than hardcoded into Terraform variables, tfvars, YAML, Helm values, or documentation.

Documentation and examples MUST use placeholders (`<root-domain>`, `lab.<root-domain>`, `api.lab.<root-domain>`) instead of any real domain value.

Because the domain value is used to create real Route 53 and ACM resources, it will necessarily appear in the persistent stack's Terraform state. This constitution does not claim the domain can be fully hidden from Terraform state — the persistent stack's remote state MUST be treated as a private, access-controlled artifact as a result.

---

## 15. VPC Ownership

The platform owns a dedicated, Persistent-lifecycle VPC (`terraform/live/persistent/vpc`, spec 020), replacing the AWS account's default VPC used by earlier specs. Public subnets only, no NAT Gateway, no VPC interface endpoints — see ADR 0020 for the cost rationale.

This keeps the same public-IP/tight-security-group trade-off as before (§9); EKS nodes still have public IPs, and security groups MUST be scoped tightly to compensate. What changed is ownership and tagging, not network isolation.

The AWS account's default VPC is no longer used by this platform and is never created or destroyed by it — it is not a resource in any lifecycle class this repository manages.

A future migration to private subnets, if ever cost-justified, is a separate change, not a reopening of this one.

---

## 16. Resource Tagging

Every AWS resource created by this repository's Terraform MUST be tagged so it is identifiable as belonging to this platform, distinguishable from any future business/service infrastructure, and traceable to its lifecycle class. Tagging is an identity and ownership requirement, not only a lifecycle-tracking convenience.

At minimum, every Terraform-managed resource MUST carry:

- `Project = vk-lab-platform` — identifies the resource as belonging to this repository/platform, distinct from any other project or unrelated resource in the same AWS account.
- `Scope = platform` — marks the resource as platform infrastructure, not a business/application service, reinforcing at the AWS resource level the repository-scope rule in §1 (this repository contains platform code only).
- `Lifecycle = state | bootstrap | persistent | disposable` — the resource's lifecycle class (§3).
- `ManagedBy = terraform` — distinguishes Terraform-owned resources from resources created indirectly by Argo CD-managed Kubernetes controllers (e.g., an NLB created by the AWS Load Balancer Controller), reinforcing the ownership boundary in §2.

Default tags SHOULD be applied at the provider level (e.g., a Terraform `default_tags` block established in the bootstrap stack and inherited by every later stack) rather than repeated per resource, so the rule cannot be silently skipped when a new resource is added.

Resources created indirectly by Kubernetes controllers (NLB, Route 53 records via `external-dns`, EBS volumes via the CSI driver) SHOULD carry equivalent tags or labels where the controller supports it, so the same identification standard holds across the Terraform/Argo ownership boundary, not only for Terraform-created resources.

---

## 17. Lifecycle Command Surface

Each lifecycle class (State, Bootstrap, Persistent, Disposable — §3) MUST have its own explicit create command. No command may implicitly create or destroy a different lifecycle class's resources.

- `make state-up` creates the State layer (the Terraform state S3 bucket). `make state-down` destroys it — see §3, ADR 0004, and ADR 0005. This is expected to run essentially never; it MUST require an explicit confirmation step and MUST refuse to run while Bootstrap, Persistent, Disposable, or CI state still exists. Never invoked by `make bootstrap-down` or any other command.
- `make bootstrap-up` creates Bootstrap-lifecycle resources; it MUST verify the State layer already exists first and MUST fail with an actionable error if it does not — it MUST NOT create the State layer on the caller's behalf. `make bootstrap-down` destroys Bootstrap resources; this repository does not expect `make bootstrap-down` to run against a live environment in normal operation. It MUST require an explicit, separate confirmation step and MUST refuse to run while Persistent or Disposable resources still exist.
- `make persistent-up` creates Persistent-lifecycle resources. `make persistent-down` destroys them — including retained EBS volumes and everything in Secrets Manager — permanently. This is a deliberate, rarely-used, explicit action, never a side effect of `make down`. `make persistent-down` MUST require an explicit confirmation step and MUST refuse to run while any Disposable-lifecycle resource still exists (the same controller-cleanup ordering principle as §7: Disposable resources that reference Persistent ones, such as DNS records inside the lab hosted zone, MUST be gone first).
- `make up` creates Disposable-lifecycle resources. It MUST verify Persistent-lifecycle resources already exist before proceeding, and MUST fail with an actionable error if they do not — it MUST NOT create Persistent resources on the caller's behalf. `make down` destroys Disposable-lifecycle resources only (§3); it MUST NOT touch Persistent or Bootstrap resources.
- `make full-up` and `make full-down` are convenience compositions of the commands above (`state-up` → `bootstrap-up` → `persistent-up` → `up`, and the exact reverse), for bringing up or tearing down the entire platform from nothing. They change no individual command's own contract or guards — each step still enforces its own precondition/confirmation exactly as if invoked on its own, so `full-down` still pauses on `persistent-down`'s and `state-down`'s own confirmation prompts. They exist only to save typing the routine full sequence; they are not a fifth lifecycle class.
- `make minikube-up` and `make kind-up` (the `local` target, §18) are separate, non-lifecycle-class commands. They MUST NOT create or destroy any State/Bootstrap/Persistent/Disposable resource, and are not governed by this section's "one command per class" rule.

A command that destroys Persistent or Bootstrap resources is a different, explicit, rarely-invoked action from the routine `make up`/`make down` cycle, and MUST be presented and guarded as such — not folded into, or reachable as a side effect of, routine shutdown.

---

## 18. Local Execution Target Scope

The platform supports a second execution target, `local` (minikube or kind), alongside the `aws` target described everywhere else in this constitution unless stated otherwise. See ADR 0006 and spec 021 for the full design.

The `local` target is AWS-free except for one deliberate, opt-in exception: decrypting real secret values from `secrets/*.enc` via AWS KMS, when explicitly requested instead of the default placeholder credentials (spec 021). No other AWS API call exists anywhere in the `local` path.

Because the `local` target does not fit the assumptions several sections above make unconditionally, the following sections apply to the `aws` target only, per §13's rule that a conflict with this constitution MUST be recorded and the constitution updated intentionally rather than silently worked around:

- **§3 (Lifecycle Separation)** — the `local` target's cluster and workloads are not State, Bootstrap, Persistent, or Disposable; they are not governed by this taxonomy at all, and are not a fifth class.
- **§4 (Persistence Safety)** — `local` data (Postgres, Kafka) is fully throwaway. There is no local persistence guarantee, no destructive-reclaim-policy prohibition, and no destroy/recreate proof requirement for `local`. Deleting the local cluster is expected to delete everything in it.
- **§5 (Security)** — the `local` target MUST NOT use AWS Secrets Manager or EKS Pod Identity. Its secrets mechanism (placeholder-by-default, KMS-decrypt-opt-in, loaded directly into Kubernetes `Secret` objects) is defined in spec 021, not this section.
- **§8 (Public Traffic)** — the `local` target has no Route 53, NLB, or ACM. Access is via `kubectl port-forward` directly to Envoy Gateway's Service; there is no TLS termination in the `local` path at all.

The following sections' requirements are vacuously satisfied for `local` and need no separate enforcement there, since the resources they govern simply don't exist on that target:

- **§9 (Compute and Cost)** — no Karpenter, no dynamic AWS compute, locally.
- **§14 (DNS Domain Ownership)** — no Route 53 hosted zone, delegation record, or ACM certificate locally.
- **§16 (Resource Tagging)** — no AWS resources are created by the `local` target to tag.

A successful `local` run is never a substitute for the `aws`-target full lifecycle test (§11) or §12's Definition of Done — it is a faster inner development loop, not a smaller version of the real thing.

---

## 19. Fork Configurability

A forked copy of this repository MUST be runnable against the fork owner's own AWS account and domain with zero source-code changes. The only setup steps a fork owner needs are: run account bootstrap (§17's `make bootstrap-up`, creating the account-level GitHub OIDC provider per §5) once against their own AWS account; set `AWS_ROLE_ARN` and `AWS_REGION` as GitHub Environment/repository variables; set `ROOT_DOMAIN` as a GitHub Environment/repository secret.

`AWS_ROLE_ARN` and `AWS_REGION` are configuration, not credentials. `ROOT_DOMAIN` is private/hygiene data (§14), delivered to GitHub Actions workflows as a secret directly — a separate delivery path from the KMS-encrypted `secrets/root-domain.enc` ciphertext (§14, §5), which remains the mechanism for workstation/local use only.

No workflow, module, or spec MUST hardcode an AWS account ID, IAM role ARN, AWS region, or domain value (see ADR 0007).