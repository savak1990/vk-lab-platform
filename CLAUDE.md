# CLAUDE.md

## Code comments

Comments are allowed only in very complex parts of code, and must be at most 3 lines. Prefer a single line where a comment is necessary at all. Do not comment straightforward code.

Never reference specific documents (specs, ADRs, tickets) in code comments, e.g. do not write "never the state bucket - ADR 0004". Explain the WHY directly in the comment instead; document links belong in commit messages or PR descriptions, not in code.

## Project purpose

This repository defines and validates a disposable AWS/EKS learning platform.

It is PLATFORM-ONLY.

Business application source code MUST NOT be added to this repository.

Read these documents before making architectural changes:

1. `docs/architecture.md` — target architecture and lifecycle.
2. `specs/000-constitution/` — mandatory engineering constraints.
3. The relevant numbered spec under `specs/`.
4. Relevant ADRs under `docs/adr/`.

The architecture document is the north-star design.
Individual specs define implementation and acceptance criteria.

---

## Core ownership model

Terraform/Terragrunt owns AWS infrastructure.

Argo CD owns Kubernetes resources.

Argo CD is bootstrapped by `make argo-up` (a script), run after the disposable EKS cluster exists — not by Terraform. See ADR 0012 for why Terraform, once used for this, was moved off it.

Terraform and Argo CD MUST NOT manage the same Kubernetes resource.

Prefer:

AWS resource
→ Terraform

Kubernetes resource/controller/operator
→ Argo CD

AWS-managed EKS add-ons may be managed through Terraform.

---

## Infrastructure lifecycle

Infrastructure is divided into three independent lifecycle classes.

### Bootstrap

Long-lived and rarely destroyed:

- Terraform remote state
- GitHub OIDC
- foundational IAM
- KMS

### Persistent

Must survive `make down`:

- VPC/subnets (deferred — spec 020; the AWS account's default VPC/public subnets are used until then)
- Route 53 (the delegated `lab.<root-domain>` subdomain zone — never the parent/root zone)
- ACM (the lab subdomain certificate — never the root domain's existing certificate)
- Secrets Manager
- RDS where configured
- retained EBS data volumes
- persistent S3 resources

### Disposable

Created by `make up` and removed by `make down`:

- EKS
- system worker capacity
- Karpenter workload nodes
- Argo CD
- NLB
- Envoy Gateway
- Kubernetes workloads
- observability workloads
- Kafka/Postgres pods

Never move a resource between these lifecycle classes without explicitly
documenting and justifying the architecture change.

---

## Platform architecture

Public traffic:

Client
→ Route 53
→ NLB
→ Envoy Gateway
→ Kubernetes workloads

The NLB is responsible for AWS ingress and TLS termination (an NLB TLS
listener using the persistent ACM certificate) — no AWS-side Ingress or
Gateway resource exists; the NLB forwards plaintext directly to Envoy
Gateway's own Service.

Envoy Gateway is responsible for:

- Gateway API routing
- rate limiting
- retries
- timeouts
- headers/policies
- gateway telemetry

Do not duplicate routing logic between the NLB and Envoy — the NLB performs
no host/path routing at all.

---

## DNS and domain ownership

The platform does NOT own the root domain or its parent Route 53 hosted zone — both are external infrastructure managed outside this repository.

The platform owns a delegated subdomain, `lab.<root-domain>`, plus an ACM certificate for `lab.<root-domain>` and `*.lab.<root-domain>`. Both are Persistent-lifecycle and are never deleted by `make down`.

The persistent stack's `route53` unit manages the single NS record delegating `lab.<root-domain>` from the parent zone directly — located by name (`data "aws_route53_zone"`, `private_zone = false`, not an explicit zone-ID input), never by creating/deleting the parent zone or touching any other record inside it. This assumes the parent zone is itself a Route 53 hosted zone reachable with the same credentials; otherwise delegation remains a one-time external/manual bootstrap step. The platform MUST NOT create, delete, or otherwise manage the parent/root hosted zone itself, or any record inside it other than that one delegation record, and MUST NOT reuse the existing root-domain ACM certificate.

Records inside the lab zone (e.g., the NLB's record) are disposable; the zone and certificate are not.

Never use a real root domain in code, tfvars, Helm values, or docs — use placeholders like `<root-domain>` or `lab.<root-domain>`. The domain is private configuration, not a secret — keep it out of the public repo for hygiene reasons, not as a security control. See `docs/adr/0002-delegated-lab-subdomain.md` and `specs/000-constitution/spec.md` §14.

---

## Resource tagging

Every Terraform-managed AWS resource MUST carry: `Project=vk-lab-platform`, `Scope=platform` (marks it as platform infra, not a business/service resource), `Lifecycle=bootstrap|persistent|disposable`, `ManagedBy=terraform`. Set these once via a provider-level `default_tags` block (bootstrap stack) rather than per-resource. See `specs/000-constitution/spec.md` §16.

---

## Compute model

EKS has:

1. Small fixed system capacity for critical controllers.
2. Karpenter-managed workload capacity.

Karpenter must be constrained to approximately:

- minimum dynamic nodes: 0
- maximum dynamic capacity: ~2 medium-size nodes

Do not broaden Karpenter instance constraints or capacity limits without
explicit justification.

Optimize for educational use and low AWS cost.

---

## Stateful workloads

Kafka uses Strimzi.

PostgreSQL uses the architecture selected by the corresponding ADR/spec.

Debezium provides PostgreSQL CDC through logical replication.

Persistent data MUST survive normal EKS destruction.

For Kubernetes-backed persistent data:

- never use destructive storage semantics for retained data;
- verify reclaim behavior explicitly;
- test destruction and recreation;
- ensure retained EBS volumes can be rebound/restored.

Do not assume a PVC surviving logically means the EBS volume will survive.
Verify the actual AWS lifecycle.

---

## Kubernetes deletion ordering

Prefer Argo CD and Kubernetes reconciliation for dependency-aware shutdown.

Creation generally proceeds:

operators/controllers
→ platform components
→ stateful workloads
→ dependent workloads
→ public exposure

Deletion should occur in reverse.

Use appropriate:

- Argo sync waves
- cascading deletion
- PreDelete/PostDelete hooks where needed
- Kubernetes finalizers

A controller must remain running until resources it manages have completed
cleanup.

Examples:

Kafka CR must be removed before Strimzi is removed.

NLB-triggering Kubernetes resources must be removed while
AWS Load Balancer Controller is still running.

`make down` should coordinate only the boundary between:

Argo/Kubernetes cleanup
and
Terragrunt/AWS destruction.

Do not reimplement the entire Kubernetes deletion graph in shell scripts.

---

## Secrets and authentication

No plaintext secrets may be committed to Git.

No long-lived AWS credentials may be required by GitHub Actions.

GitHub Actions → AWS authentication MUST use OIDC and temporary credentials.

Kubernetes workloads should use EKS workload identity / Pod Identity.

Runtime secrets live in AWS Secrets Manager.

Helm/GitOps configuration contains only secret references.

The repository may contain KMS-encrypted deterministic bootstrap ciphertext.
Each secret or private config value gets its own committed ciphertext file
under `secrets/<project>/`, named after its contents, for example:

`secrets/vk-lab-platform/root-domain.enc`
`secrets/vk-lab-platform/postgres-admin-password.enc`

Never commit the plaintext equivalent, and never combine multiple secrets
or config values into one committed ciphertext file.

The root domain (`secrets/<project>/root-domain.enc`) is private/hygiene
data, not a credential — do not claim obscuring it is a security control.

Avoid unnecessarily putting decrypted secret values into Terraform state.

---

## Observability

Platform observability consists of:

- Prometheus — metrics
- Grafana — visualization
- Loki — logs
- Alloy — Kubernetes log collection
- Tempo — traces
- OpenTelemetry Collector — telemetry pipeline

Observability should cover:

- Kubernetes
- Karpenter
- Envoy
- AWS Load Balancer Controller
- Kafka / Strimzi
- PostgreSQL
- Debezium
- platform integration workloads

When adding a new major platform component, include monitoring/logging
integration unless the spec explicitly excludes it.

---

## Repository layout

Expected high-level structure:

.platform-specific config omitted

`terraform/modules/`
Reusable Terraform modules.

`terraform/live/bootstrap/`
Bootstrap lifecycle.

`terraform/live/persistent/`
Persistent lifecycle.

`terraform/live/disposable/`
Disposable personal-lab lifecycle.

`terraform/live/ci/`
CI-specific infrastructure.

`gitops/`
Argo-managed Kubernetes desired state.

`specs/`
Spec-driven-development requirements.

`docs/architecture.md`
Target architecture.

`docs/adr/`
Architectural decisions.

`.github/workflows/`
CI and platform lifecycle workflows.

Do not add business service implementation directories.

---

## Spec-driven development workflow

For non-trivial work:

1. Read `docs/architecture.md`.
2. Read `specs/000-constitution/`.
3. Read the relevant numbered spec.
4. Inspect existing implementation.
5. Produce an implementation plan.
6. Implement incrementally.
7. Run validation.
8. Fix failures before declaring completion.
9. Record material architecture decisions as ADRs.

Do not silently change architecture requirements to make implementation easier.

If requirements are ambiguous, prefer the interpretation most consistent with:

1. architecture invariants,
2. persistence safety,
3. security,
4. low cost,
5. simplicity.

---

## Exploration and planning tools

When exploring the codebase to understand existing patterns before planning or implementing, prefer dispatching read-only subagents in parallel over ad hoc reading, so each area gets focused context.

When designing an implementation approach for non-trivial work, prefer consulting the advisor tool before committing to a plan, and again before declaring the work complete.

The advisor is expected to run on a strong model for planning-quality work; this is set per-session by the operator, not something these instructions can guarantee on their own.

---

## Validation

Every change should run the fastest relevant validation.

Expected fast checks include, as applicable:

- Terraform formatting
- Terraform validate
- Terragrunt validation
- Terraform/Terragrunt plan
- Helm template rendering
- Kubernetes schema validation
- YAML linting
- security scanning
- Argo manifest validation
- GitHub Actions validation

Do not consider generated configuration complete simply because syntax validation passes.

---

## Full lifecycle acceptance test

Infrastructure-critical changes must remain compatible with:

CREATE
→ VERIFY
→ WRITE PERSISTENT DATA
→ DESTROY
→ VERIFY PERSISTENCE
→ RECREATE
→ VERIFY RECOVERY
→ FINAL DESTROY
→ VERIFY NO LEAKS

The intended end-to-end test is:

1. `make up`
2. verify EKS/Argo/Karpenter/Kafka/Postgres/Debezium/observability/Envoy (Debezium is deliberately implemented last, spec 024 — until it lands, run this test without it)
3. write PostgreSQL test data
4. write Kafka test data
5. verify CDC (once spec 024 lands; deferred until then)
6. `make down`
7. verify disposable infrastructure is absent
8. verify persistent state remains
9. `make up`
10. verify state recovery
11. `make down`
12. verify no disposable AWS resources leaked

A successful `terraform destroy` alone does NOT prove successful shutdown.

---

## CI rules

Every PR receives fast validation.

Full AWS lifecycle validation is reserved for infrastructure-relevant changes
or explicitly triggered trusted runs.

The public repository MUST NOT expose privileged AWS access to untrusted fork
pull requests.

CI must use a separate environment/state from the personal lab.

Full CI tests must attempt cleanup even after failures.

Use GitHub concurrency and Terraform state locking where shared resources are
involved.

Keep a stale-CI-resource cleanup mechanism as a safety net.

---

## Cost rules

This is an educational platform.

Prefer inexpensive designs.

Do NOT introduce without explicit justification:

- unnecessary NAT Gateways
- oversized EC2 instances
- unbounded Karpenter provisioning
- production-grade HA that materially increases cost
- unnecessarily large observability retention
- expensive managed services when a smaller lab alternative is sufficient

Persistent inexpensive storage is preferable to keeping expensive compute
running.

---

## Working rules for Claude

Before changing infrastructure:

- inspect dependencies;
- determine resource ownership;
- determine lifecycle class;
- consider destroy/recreate behavior;
- consider CI behavior;
- consider cost impact.

When modifying stateful resources, explicitly analyze the failure and deletion
path.

When adding an operator/controller, explicitly determine:
- who installs it;
- what external resources it creates;
- how those resources are cleaned up;
- where it belongs in Argo creation/deletion ordering;
- how it is observed.

Do not use broad AWS IAM permissions when narrower permissions are practical.

Do not modify persistent infrastructure during normal disposable lifecycle
work unless the task explicitly requires it.

Do not add application business code to this repository.