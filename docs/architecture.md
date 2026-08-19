# Platform Architecture and Target State

# 1. Purpose

This document defines the target architecture for the AWS/EKS learning platform.

It is the architectural source of truth for implementation specifications under `/specs`.

Individual specifications may add implementation details. Each specification must stay consistent with the boundaries, lifecycle rules, ownership model, security requirements, and invariants in this document.

The platform is intended to provide a realistic, reproducible, observable, dynamically scalable, and cost-conscious environment for experimenting with:

- AWS EKS
- Kubernetes operators
- GitOps with Argo CD
- Kafka
- PostgreSQL
- CDC with Debezium
- dynamic compute with Karpenter
- persistent state
- Envoy Gateway
- AWS ALB
- Route 53 and ACM
- observability
- AWS IAM and Pod Identity
- Secrets Manager and KMS
- GitHub Actions
- Terraform and Terragrunt
- disposable infrastructure lifecycle

The entire running platform must be reproducible from Git plus explicitly persistent AWS state.

---

# 2. Repository Responsibility

This repository is a **platform-only repository**.

It contains:

- infrastructure definitions
- Kubernetes platform configuration
- operators
- shared platform services
- networking
- observability
- persistence infrastructure
- security infrastructure
- platform lifecycle automation
- platform tests
- architecture and specifications

It does **not** contain business application source code.

Application services are developed independently in either:

```text
Option A

applications/
├── service-a/
├── service-b/
└── service-c/

single application monorepo
```

or:

```text
Option B

service-a repository
service-b repository
service-c repository
```

The platform repository must not depend on applications being stored in the same Git repository.

Application repositories may publish container images and provide deployment configuration consumed by this platform.

---

# 3. Primary Goals

The platform must provide:

1. A real AWS EKS environment.
2. Infrastructure defined through Terraform.
3. Terraform stack orchestration through Terragrunt.
4. Kubernetes resources managed through Argo CD.
5. Dynamic workload capacity using Karpenter.
6. Persistent database and Kafka data across EKS destruction.
7. PostgreSQL and Kafka operator-based deployments where applicable.
8. PostgreSQL CDC through Debezium.
9. Metrics, logs, and traces through a unified observability stack.
10. Envoy Gateway as the in-cluster API gateway and reverse proxy.
11. AWS ALB as the public AWS entry point.
12. Route 53 DNS.
13. ACM-managed HTTPS certificates.
14. Secrets stored in AWS Secrets Manager.
15. KMS support for deterministic encrypted bootstrap secret material.
16. No long-lived AWS credentials in GitHub.
17. Simple platform start and stop operations.
18. Equivalent lifecycle behavior locally and through GitHub Actions.
19. Automated fast validation for every platform change.
20. Automated full lifecycle validation for appropriate changes.
21. The ability to prove that platform state survives destruction and recreation.

---

# 4. Non-Goals

The initial platform is not intended to provide:

- production-grade multi-region availability
- production-grade Kafka replication across multiple AZs
- HA for every component
- enterprise multi-tenancy
- support for multiple production teams
- zero-downtime platform shutdown
- very large workloads
- multiple AWS accounts
- enterprise disaster recovery
- deployment lifecycle of application source code

Cost, simplicity, learning value, reproducibility, and architectural correctness take priority over production-scale availability.

---

# 5. Repository Structure

The target repository structure is:

```text
vk-lab-platform/
├── .github/
│   └── workflows/
│       ├── validate.yml
│       ├── platform-integration.yml
│       ├── lab-up.yml
│       ├── lab-down.yml
│       └── cleanup-stale-ci.yml
│
├── atlantis.yaml                  # spec 017; one project per Terragrunt stack
│
├── terraform/
│   ├── modules/
│   │   ├── terraform-state/
│   │   ├── github-oidc/
│   │   ├── kms/
│   │   ├── secrets-manager/
│   │   ├── vpc/                   # not used until spec 020; default VPC used until then
│   │   ├── route53-zone/
│   │   ├── acm-certificate/
│   │   ├── rds/
│   │   ├── ebs-volume/
│   │   ├── eks/
│   │   ├── eks-addons/
│   │   ├── node-group/
│   │   └── karpenter-iam/
│   │
│   └── live/
│       ├── root.hcl
│       │
│       ├── bootstrap/
│       │   ├── terragrunt.stack.hcl
│       │   ├── state/
│       │   ├── github-oidc/
│       │   ├── kms/
│       │   └── atlantis/               # spec 017; standalone compute, independent of EKS
│       │
│       ├── persistent/
│       │   ├── terragrunt.stack.hcl
│       │   ├── vpc/                   # added by spec 020; not present initially
│       │   ├── route53/
│       │   ├── acm/
│       │   ├── secrets/
│       │   ├── rds/
│       │   └── persistent-storage/
│       │
│       ├── disposable/
│       │   ├── terragrunt.stack.hcl
│       │   ├── eks/
│       │   ├── eks-addons/
│       │   ├── system-node-group/
│       │   ├── karpenter/
│       │   └── argocd-bootstrap/
│       │
│       └── ci/
│           ├── persistent/
│           └── disposable/
│
├── gitops/
│   ├── bootstrap/
│   │   └── root-application.yaml
│   │
│   ├── platform/
│   │   ├── argocd/
│   │   │
│   │   ├── aws/
│   │   │   ├── aws-load-balancer-controller/
│   │   │   └── secrets-store-csi/
│   │   │
│   │   ├── autoscaling/
│   │   │   └── karpenter/
│   │   │       ├── nodepool.yaml
│   │   │       └── ec2nodeclass.yaml
│   │   │
│   │   ├── gateway/
│   │   │   ├── envoy-gateway/
│   │   │   ├── gatewayclass/
│   │   │   ├── gateway/
│   │   │   ├── routes/
│   │   │   └── policies/
│   │   │
│   │   └── observability/
│   │       ├── kube-prometheus-stack/
│   │       ├── loki/
│   │       ├── alloy/
│   │       ├── tempo/
│   │       └── otel-collector/
│   │
│   ├── data/
│   │   ├── postgres/
│   │   │   ├── operator/
│   │   │   ├── cluster/
│   │   │   ├── secrets/
│   │   │   ├── monitoring/
│   │   │   └── alerts/
│   │   │
│   │   ├── kafka/
│   │   │   ├── strimzi/
│   │   │   ├── cluster/
│   │   │   ├── storage/
│   │   │   ├── exporter/
│   │   │   ├── monitoring/
│   │   │   └── alerts/
│   │   │
│   │   └── debezium/
│   │
│   └── workloads/
│       └── integration/
│
├── secrets/
│   ├── root-domain.enc
│   ├── postgres-admin-password.enc
│   ├── kafka-cluster-credentials.enc
│   └── ...                        # one KMS-encrypted file per secret/config value
│
├── specs/
│   ├── 000-constitution/
│   ├── 001-bootstrap/
│   ├── 002-persistent-foundation/
│   ├── 003-network-and-eks/
│   ├── 004-argocd-bootstrap/
│   ├── 005-storage-contract/
│   ├── 006-karpenter/
│   ├── 007-postgres/
│   ├── 008-kafka/
│   ├── 009-debezium/
│   ├── 010-observability/
│   ├── 011-envoy-gateway/
│   ├── 012-public-edge/
│   ├── 013-secrets/
│   ├── 014-lifecycle/
│   ├── 015-github-actions-lifecycle/
│   ├── 016-branch-protection/
│   ├── 017-atlantis-terraform-automation/
│   ├── 018-ci-fast-validation/
│   ├── 019-ci-full-lifecycle-validation/
│   └── 020-vpc/
│
├── docs/
│   ├── architecture.md
│   └── adr/
│
├── Makefile
├── README.md
└── .gitignore
```

`gitops/workloads/integration` may contain minimal synthetic workloads needed to test the platform itself. It must not become a home for real business services.

---

# 6. Infrastructure Lifecycle Boundaries

Infrastructure is divided into three lifecycle classes.

## Bootstrap

Bootstrap infrastructure establishes the root of trust and infrastructure-management foundation.

Examples:

- Terraform state infrastructure
- GitHub OIDC provider
- foundational IAM
- KMS

Lifecycle:

```text
created once
    ↓
rarely changed
    ↓
almost never destroyed
```

## Persistent

Persistent resources survive normal platform shutdown.

Examples:

- VPC/subnets (deferred — see note below; the AWS account's default VPC is used initially)
- Route 53 hosted zone
- ACM certificate
- Secrets Manager
- RDS
- retained EBS volumes
- persistent S3 resources

A dedicated, platform-owned VPC is not part of the initial scope. Early specs run EKS in the AWS account's default VPC and default public subnets, prioritizing simplicity over network isolation (§4's "cost, simplicity ... take priority" principle). A dedicated persistent VPC is introduced later by its own spec once the rest of the platform is proven out; until then, "VPC" does not appear as a resource this repository's Terraform creates or destroys.

Lifecycle:

```text
make up
   ↓
unchanged

make down
   ↓
still present
```

## Disposable

Disposable infrastructure exists only while the lab is running.

Examples:

- EKS control plane
- system worker node
- Karpenter-created worker nodes
- Argo CD installation
- Kubernetes workloads
- Envoy
- ALB
- Kafka/Postgres pods
- observability workloads

Lifecycle:

```text
make up
   ↓
created

make down
   ↓
destroyed
```

---

# 7. Infrastructure Ownership

Ownership must remain explicit.

## Terraform / Terragrunt owns

AWS infrastructure including:

- Terraform backend
- VPC
- networking
- EKS
- EKS managed add-ons
- system node group
- IAM
- KMS
- Secrets Manager resources
- RDS
- persistent AWS storage
- Route 53
- ACM
- GitHub OIDC
- AWS-side Karpenter infrastructure

Terraform also performs the initial Argo CD bootstrap.

## Argo CD owns

Kubernetes-native resources including:

- Karpenter controller/configuration
- AWS Load Balancer Controller
- Envoy Gateway
- Strimzi
- Kafka
- PostgreSQL operator
- PostgreSQL cluster where applicable
- Debezium
- Prometheus
- Grafana
- Loki
- Alloy
- Tempo
- OpenTelemetry Collector
- monitoring resources
- gateway routes
- gateway policies
- platform integration-test workloads

## Ownership invariant

Terraform and Argo CD must never own the same Kubernetes resource.

---

# 8. High-Level Architecture

```text
                          Internet
                             │
                             ▼
                          Route 53
                             │
                             ▼
                            ALB
                      TLS using ACM
                             │
                             ▼
                      Envoy Gateway
                             │
                      Gateway API
                             │
               ┌─────────────┼─────────────┐
               ▼             ▼             ▼
         application       Grafana      Argo CD
          workloads
               │
        ┌──────┴───────┐
        ▼              ▼
   PostgreSQL         Kafka
        │
        │ logical replication
        ▼
     Debezium
        │
        ▼
      Kafka
```

Business application workloads may originate from external repositories.

---

# 9. EKS Compute Model

The EKS cluster uses two compute classes.

## System node

A small fixed system node provides capacity for infrastructure required before dynamic provisioning is possible.

It may host:

- Argo CD
- Karpenter controller
- AWS Load Balancer Controller
- critical cluster/platform controllers

## Karpenter workload capacity

Karpenter dynamically provisions general workload capacity.

Initial target:

```text
minimum dynamic nodes: 0
effective maximum: approximately 2 medium-size nodes
```

Allowed EC2 instance types and NodePool resource limits must be constrained such that Karpenter cannot unexpectedly provision large amounts of compute.

When workloads disappear, Karpenter should consolidate and remove unnecessary workload nodes.

---

# 10. Networking

## Initial state: AWS default VPC

A dedicated platform-owned VPC is intentionally out of scope for the initial set of specs. EKS, its system node group, and everything built on top of it run in the AWS account's **default VPC**, using its default public subnets.

This is a deliberate simplicity/cost trade-off, not an oversight: it avoids VPC/subnet/route-table design and NAT Gateway cost entirely while the rest of the platform (Argo CD, storage contract, Postgres, Kafka, observability, public edge) is built out and proven. The accepted consequence is that EKS nodes get public IPs; security groups are scoped tightly to compensate (see spec 003).

The default VPC is not created or destroyed by this platform — it always exists at the AWS account level, independent of any lifecycle class this repository manages.

## Future state: dedicated persistent VPC

A dedicated VPC (public + private subnets, explicit route tables) is planned as a later addition, once the rest of the platform is working. When introduced, it will belong to the persistent infrastructure layer, so that RDS (if ever used) and other persistent infrastructure can survive EKS destruction independent of the VPC lifecycle. Migrating from the default VPC to a dedicated one requires a full disposable-stack recreation and careful handling of AZ-locked EBS volumes (see the VPC spec for the concrete migration plan).

Once introduced, networking should support:

- EKS
- ALB
- Karpenter
- RDS (if used)
- EBS
- Pod Identity
- AWS controllers

Unnecessary permanent network costs, especially NAT Gateway costs, should be avoided where practical for the educational environment — this applies both to the current no-VPC state (trivially true, there is no NAT Gateway) and to the future dedicated VPC (a NAT Gateway must be explicitly justified, not added by default).

---

# 11. Public Edge

The public request path is:

```text
client
  ↓
Route 53
  ↓
ALB
  ↓
Envoy Gateway
  ↓
Kubernetes service
```

## ALB responsibility

ALB provides:

- AWS-managed public ingress
- ACM TLS termination
- target health checks
- forwarding to Envoy

ALB should not duplicate application routing logic.

## Envoy responsibility

Envoy provides:

- Kubernetes Gateway API
- host/path routing
- rate limiting
- retries
- timeouts
- security headers
- traffic policies
- gateway telemetry

Example DNS names may include:

```text
api.lab.<root-domain>
grafana.lab.<root-domain>
argocd.lab.<root-domain>
```

See §12 for how the `lab.<root-domain>` zone these names live in is owned and delegated.

---

# 12. DNS and TLS

## Domain ownership boundary

The platform does not own the root domain or its Route 53 hosted zone. The root domain registration and its parent hosted zone are external, pre-existing infrastructure, managed outside this repository and outside the platform's normal lifecycle.

The platform owns a delegated subdomain:

```text
lab.<root-domain>
```

## What the platform owns

The Terraform persistent layer creates and owns:

- a Route 53 public hosted zone for `lab.<root-domain>`
- an ACM certificate covering:
  - `lab.<root-domain>`
  - `*.lab.<root-domain>`

Both are Persistent-lifecycle: they survive `make down` and EKS destruction/recreation.

The ACM certificate must be created in the same AWS region as the ALB that uses it (§11), and should use DNS validation against the delegated `lab.<root-domain>` hosted zone rather than email validation.

The existing root-domain certificate is not reused for the platform. The lab subdomain gets its own certificate unless a later ADR explicitly changes this decision.

## What the platform does not own

The parent/root hosted zone, and the root domain registration itself, are external infrastructure and outside this repository's lifecycle. The platform:

- MUST NOT require write access to the parent/root hosted zone during normal operation (`make up`/`make down`);
- MUST NOT manage records in the parent hosted zone;
- treats delegation of `lab.<root-domain>` from the parent zone (creating the NS records in the parent zone that point at the lab zone's name servers) as a one-time external/manual bootstrap step, performed outside normal platform lifecycle, unless an existing documented bootstrap mechanism already covers it.

## Desired DNS model

```text
Existing external infrastructure:

<root-domain>
└── parent Route 53 hosted zone
      └── NS delegation for lab.<root-domain>

Platform persistent infrastructure:

lab.<root-domain> hosted zone
├── ACM certificate:
│   ├── lab.<root-domain>
│   └── *.lab.<root-domain>
│
├── api.lab.<root-domain>
├── grafana.lab.<root-domain>
├── argocd.lab.<root-domain>
└── other platform DNS records

Disposable runtime:

Route 53 record
    ↓
ALB
    ↓
Envoy Gateway
    ↓
platform/application workloads
```

## Records inside the lab zone

Individual DNS records inside the delegated `lab.<root-domain>` zone (for example, the record pointing at the ALB) are disposable — they are created and removed as part of normal `make up`/`make down` operation. Ownership of these records must be explicit and must not overlap between Terraform and Kubernetes controllers: in practice, a controller such as `external-dns` (Argo-managed) owns record lifecycle tied to Kubernetes/AWS resource lifecycle, while Terraform owns only the hosted zone and certificate themselves.

The hosted zone and certificate are never deleted by `make down` (§23–24).

## Domain value handling

The real root domain value is private configuration, not a security credential. Keeping it out of the public repository is repository hygiene — avoiding exposure of personal infrastructure details — not a security control. See §18 for how the value is stored and supplied to Terraform.

## TLS termination

Initial TLS termination occurs at ALB.

End-to-end TLS between ALB and Envoy is not required for the initial implementation.

---

# 13. PostgreSQL

PostgreSQL must support persistent state.

The final implementation may use:

- RDS PostgreSQL, or
- PostgreSQL operated inside Kubernetes.

The chosen architecture must be recorded in an ADR.

If PostgreSQL runs inside Kubernetes:

```text
Postgres
   ↓
PVC
   ↓
EBS
```

the EBS data must survive EKS destruction.

PostgreSQL must support logical replication for Debezium.

Monitoring must include relevant database health and CDC-related metrics such as:

- connections
- transaction activity
- replication slots
- WAL retention
- disk usage
- failures

---

# 14. Kafka

Kafka runs in Kubernetes using Strimzi.

```text
Strimzi
   ↓
Kafka
   ↓
persistent EBS
```

Kafka data storage must survive normal EKS destruction.

Monitoring must include:

- broker health
- partition health
- throughput
- JVM
- disk usage
- consumer lag

---

# 15. CDC

Debezium consumes PostgreSQL logical replication:

```text
Postgres WAL
    ↓
logical decoding / pgoutput
    ↓
Debezium
    ↓
Kafka
```

Only committed PostgreSQL transactions should be represented in CDC.

Consumers must assume at-least-once semantics.

Replication-slot health and WAL retention must be observable.

---

# 16. Persistent Storage Contract

Persistent state safety is a platform invariant.

For persistent workloads:

```text
Kubernetes resources may disappear
            ↓
underlying AWS data must remain
```

Required persistent volumes must use retention semantics appropriate for EKS destruction.

Before destructive lifecycle operations, the platform must verify that persistent data will not be deleted.

The recreation process must define how persistent volumes are rediscovered, rebound, or restored.

This behavior must be covered by full lifecycle CI.

---

# 17. Secrets and Identity

No plaintext runtime secret may exist in Git.

GitHub Actions authenticate to AWS through:

```text
GitHub Actions
      ↓
OIDC
      ↓
AWS STS
      ↓
temporary credentials
```

No permanent AWS access key is required.

Kubernetes workloads access AWS through workload identity such as EKS Pod Identity.

Runtime secrets live in AWS Secrets Manager.

```text
Pod
 ↓
Pod Identity
 ↓
IAM
 ↓
Secrets Manager
```

Helm and GitOps configuration contain references to secret resources, never plaintext values.

---

# 18. Deterministic Secrets

This educational environment may use user-selected deterministic secret material.

Each secret or private configuration value is encrypted independently with AWS KMS before entering Git — one plaintext value produces one committed ciphertext file, never a combined blob:

```text
plaintext value
   ↓
KMS Encrypt
   ↓
ciphertext
   ↓
one file under secrets/
```

The repository therefore contains one committed ciphertext file per value, for example:

```text
secrets/
├── root-domain.enc
├── postgres-admin-password.enc
├── kafka-cluster-credentials.enc
└── ...
```

Secrets and private configuration values MUST NOT be combined into a single committed ciphertext file. One file per value keeps blast radius and lifecycle independent — a value can be added, rotated, or removed without touching unrelated ciphertext, and a diff on one file never reveals that an unrelated value also changed.

Only authorized AWS identities may decrypt any of these files.

Decrypted values should be written directly to Secrets Manager without unnecessarily persisting plaintext in Terraform state.

This one-file-per-secret rule governs only the Git-committed layout. It is independent of how values are grouped once they reach Secrets Manager: for cost optimization, the platform may still keep multiple related *runtime* credentials inside one Secrets Manager JSON object (e.g., a single Postgres credentials secret with several fields). That AWS-side grouping is an intentional lab-specific trade-off rather than the preferred isolation model for production systems, and it does not change the one-file-per-secret rule for what's committed to Git.

## Non-secret private configuration

The same per-file encrypted mechanism also carries non-secret private configuration values, such as the platform's root domain name (§12) — for example, `secrets/root-domain.enc`. These values are committed to Git only in KMS-encrypted form for repository-hygiene reasons — to avoid exposing personal infrastructure details in a public repository — not because the value itself is a security credential.

Terraform must obtain the decrypted domain value through this same secure bootstrap/runtime mechanism (for example, a decrypted value supplied as a Terraform variable at apply time from Secrets Manager), without unnecessarily persisting private configuration into committed files.

Because the domain value is used to create real Route 53 and ACM resources, it will necessarily appear in the persistent stack's Terraform state. Remote state for the persistent stack must therefore remain private and access-controlled; the domain cannot be fully hidden from Terraform state, and this document does not claim otherwise.

---

# 19. Observability

The platform uses:

```text
Prometheus
    metrics

Grafana
    visualization

Loki
    logs

Alloy
    Kubernetes log collection

Tempo
    traces

OpenTelemetry Collector
    telemetry processing
```

Observability must cover:

- Kubernetes
- EKS workloads
- Karpenter
- Envoy
- AWS Load Balancer Controller
- Kafka
- Strimzi
- PostgreSQL
- PostgreSQL operator
- Debezium
- platform integration workloads

Important platform behavior should be diagnosable through metrics and logs.

---

# 20. GitOps

Terraform bootstraps:

```text
EKS
 ↓
Argo CD
 ↓
root Application
```

After that, Argo CD reconciles Kubernetes desired state from Git.

Argo is responsible for both deployment and dependency-aware Kubernetes cleanup.

Manual changes to Argo-managed Kubernetes resources are considered temporary drift.

---

# 21. Argo Ordering and Cleanup

Kubernetes dependency ordering should be expressed primarily through Argo CD and Kubernetes controllers rather than custom imperative shutdown scripts.

Creation should approximately follow:

```text
operators/controllers
        ↓
platform components
        ↓
stateful workloads
        ↓
dependent workloads
        ↓
public exposure
```

Deletion should occur in reverse:

```text
public exposure
        ↓
dependent workloads
        ↓
Debezium
        ↓
stateful workloads
        ↓
platform services
        ↓
operators/controllers
```

Argo mechanisms may include:

- sync waves
- cascading deletion
- PreDelete hooks
- PostDelete hooks
- Kubernetes finalizers

Critical invariant:

> A controller must remain running until resources it manages have completed their cleanup.

Examples:

```text
Kafka CR
   ↓ deleted
Strimzi
   ↓ remains available for cleanup
Strimzi deleted afterward
```

and:

```text
external exposure object
   ↓ deleted
AWS Load Balancer Controller
   ↓ deletes ALB resources
controller deleted afterward
```

---

# 21a. Lifecycle Command Surface

Each lifecycle class (Bootstrap, Persistent, Disposable — §6) gets its own explicit create and destroy command. No command implicitly creates or destroys a different lifecycle class's resources; see constitution §17 for the binding rule.

```text
make bootstrap-up      creates Bootstrap-lifecycle resources (state, OIDC, IAM, KMS, Atlantis)
make bootstrap-down    destroys them — guarded, expected to run essentially never

make persistent-up     creates Persistent-lifecycle resources (lab DNS zone, ACM cert, Secrets Manager, retained EBS)
make persistent-down   destroys them — guarded, deliberate, rarely used, real and permanent data loss

make up                creates Disposable-lifecycle resources (EKS, Argo, workloads)
make down              destroys them — the routine, frequently-used command
```

`make up` verifies that Persistent-lifecycle resources already exist before doing anything else. If they do not, it fails with an actionable error telling the operator to run `make persistent-up` first — it never creates Persistent resources on the caller's behalf. This keeps the "what survives `make down`" boundary (§6) visible at the command layer, not just in Terraform state layout.

`make persistent-down` and `make bootstrap-down` are destructive, rarely-used escape hatches, not part of the routine up/down cycle:

- `make persistent-down` MUST refuse to run while any Disposable-lifecycle resource still exists (mirroring the controller-cleanup ordering in §21 — Disposable resources that reference Persistent ones, such as DNS records inside the lab hosted zone, must be gone first) and MUST require an explicit confirmation step, since it deletes the lab DNS zone/certificate, Secrets Manager contents, and retained EBS volumes permanently.
- `make bootstrap-down` MUST refuse to run while Persistent or Disposable state still exists, and MUST require its own explicit confirmation step. This repository does not expect it to run against a live environment in normal operation.

---

# 22. Platform Start

The user-facing command is:

```text
make up
```

Architecturally:

```text
make up
   ↓
verify Persistent-lifecycle resources exist (fail fast, with a clear error, if not — see §21a)
   ↓
Terragrunt apply disposable infrastructure
   ↓
EKS created
   ↓
system capacity available
   ↓
Argo CD bootstrapped
   ↓
root Application created
   ↓
Argo reconciles platform
   ↓
Karpenter provisions dynamic capacity
   ↓
Kafka/Postgres/observability become healthy
   ↓
Envoy becomes healthy
   ↓
AWS Load Balancer Controller provisions ALB
   ↓
public HTTPS endpoint becomes usable
```

`make up` should be idempotent.

---

# 23. Platform Shutdown

The user-facing command is:

```text
make down
```

`make down` only ever targets Disposable-lifecycle resources (§6); it never touches Persistent or Bootstrap resources. Removing those is a separate, rarely-used, explicitly-confirmed action (`make persistent-down`, `make bootstrap-down` — §21a), not a side effect of routine shutdown.

The Kubernetes cleanup phase should primarily be handled by Argo CD.

Architecturally:

```text
make down
   ↓
request cascading Argo platform deletion
   ↓
Argo executes dependency-safe reverse cleanup
   ↓
public exposure disappears
   ↓
AWS LB Controller removes ALB
   ↓
applications stop
   ↓
Debezium stops
   ↓
stateful workloads terminate cleanly
   ↓
persistent EBS remains
   ↓
operators/controllers clean managed resources
   ↓
Argo-managed platform becomes empty
   ↓
Terragrunt destroys disposable AWS infrastructure
   ↓
EKS and EC2 compute disappear
   ↓
post-destroy leak checks
```

The outer lifecycle command should coordinate only the boundary between:

```text
Argo-managed Kubernetes lifecycle
            and
Terraform/Terragrunt-managed AWS lifecycle
```

It should not independently recreate Argo's dependency graph in Bash or Go.

---

# 24. Shutdown Postconditions

After successful shutdown, these resources must be absent:

```text
EKS
system worker
Karpenter workload instances
ALB
Envoy
Kafka/Postgres pods
observability pods
disposable Route 53 records inside the lab hosted zone (e.g., the ALB's DNS record)
disposable Kubernetes resources
disposable AWS resources
```

These must remain:

```text
Terraform state
KMS
Secrets Manager
VPC
Route 53 — the delegated `lab.<root-domain>` hosted zone (the parent/root hosted zone is external and is never managed by this platform)
ACM — the lab subdomain certificate
RDS where applicable
retained EBS data
persistent S3 resources
```

`terragrunt destroy` returning successfully is not by itself sufficient to declare shutdown successful.

Postconditions must be verified.

---

# 25. CI/CD Philosophy

CI/CD is part of the platform architecture, not an optional afterthought.

All changes reach `main` through a reviewed pull request — direct pushes to `main` are disabled (spec 016). The platform uses three complementary mechanisms on top of that:

```text
FAST VALIDATION
every pull request — lint/format/schema checks only, no AWS credentials

TERRAFORM PLAN/APPLY AUTOMATION
every pull request touching terraform/** — plan on PR, apply on merge

FULL LIFECYCLE VALIDATION
manually triggered, or on infrastructure-relevant changes to main
```

The goal is to combine fast developer feedback, safe and auditable Terraform changes, and high confidence in real platform lifecycle behavior.

---

# 26. Fast Validation

Every pull request must perform fast validation that does not require provisioning an EKS environment and does not require AWS credentials.

This should include, where applicable:

```text
Terraform formatting
Terraform validation
Terragrunt validation
Helm rendering
Kubernetes schema validation
YAML validation
policy checks
security scanning
Argo manifest validation
GitHub workflow validation
```

Fast validation should detect most structural/configuration problems before expensive AWS integration testing is attempted. It does not run `terraform plan` against real state — that is Terraform Plan/Apply Automation's job (§26a), so plan output is never produced by two different tools on the same PR.

Documentation-only changes should normally require only appropriate fast checks.

---

# 26a. Terraform Plan/Apply Automation

Every pull request that changes a file under `terraform/**` receives an automatic `terraform plan` comment, and merging the pull request (after review) triggers `terraform apply` for the affected stack — using a PR-driven Terraform automation service (Atlantis; see spec 017), not a person running `terraform apply` from a laptop.

This service must:

```text
plan automatically on PR open/update
apply only after PR approval and merge (or an explicit apply command)
hold one least-privilege IAM role per lifecycle stack
run independently of the disposable EKS cluster
```

The last point matters specifically: this service must remain available to apply the Terraform that creates, modifies, or destroys the disposable EKS cluster, so it cannot itself run on that cluster (see ADR 0003).

This mechanism only touches Terraform/Terragrunt-managed AWS state. It never applies anything under `gitops/` — that boundary belongs to Argo CD (§7).

---

# 27. Full Platform Validation

Infrastructure-relevant changes should be capable of triggering a complete platform lifecycle test.

Typical triggers include changes under:

```text
terraform/**
gitops/**
secrets/**
.github/workflows/platform-*
specs affecting lifecycle-critical behavior
```

Full validation exercises the real AWS/EKS platform.

The canonical test is:

```text
CREATE
  ↓
VERIFY
  ↓
WRITE PERSISTENT DATA
  ↓
DESTROY
  ↓
VERIFY PERSISTENCE
  ↓
RECREATE
  ↓
VERIFY RECOVERY
  ↓
DESTROY
  ↓
VERIFY NO LEAKS
```

---

# 28. Full Validation Scenario

A complete integration run should approximately perform:

```text
1. Create disposable EKS environment.

2. Wait for Argo reconciliation.

3. Verify:
   - EKS healthy
   - Argo healthy
   - Karpenter healthy
   - Kafka healthy
   - PostgreSQL healthy
   - Debezium healthy
   - observability healthy
   - Envoy healthy
   - ALB healthy
   - HTTPS works

4. Write known data to PostgreSQL.

5. Produce known data to Kafka.

6. Verify CDC where applicable.

7. Run platform shutdown.

8. Verify:
   - EKS absent
   - compute absent
   - ALB absent
   - persistent storage remains

9. Recreate platform.

10. Verify:
    - Argo reconstructs platform
    - PostgreSQL test data remains
    - Kafka persistent data remains/recoverable
    - HTTPS becomes healthy again

11. Perform final shutdown.

12. Verify no disposable AWS resources leaked.
```

---

# 29. CI Isolation

CI infrastructure must be isolated from the personal lab environment.

Conceptually:

```text
AWS account

personal/
├── persistent
└── disposable

ci/
├── persistent
└── disposable
```

CI lifecycle tests must never operate on personal persistent volumes, databases, or state.

A dedicated CI persistent layer may be shared between CI runs where doing so reduces cost, provided test isolation is maintained.

---

# 30. Public Repository CI Security

Because the repository is public, untrusted pull requests must not automatically receive privileged AWS deployment access.

Untrusted/fork PRs should run:

```text
fast validation
static checks
safe planning where possible
```

Privileged full AWS integration tests should execute only in a trusted GitHub context.

GitHub OIDC trust must be constrained appropriately.

Full platform testing may initially require explicit approval before assuming the privileged AWS CI role.

---

# 31. CI Cleanup Guarantees

Full integration tests must clean up even when a test fails.

Conceptually:

```text
platform creation
    ↓
test fails
    ↓
cleanup still executes
```

CI cleanup must run unconditionally where practical.

In addition, a scheduled stale-resource cleanup workflow should identify disposable CI resources that exceed an allowed lifetime.

This protects against:

- cancelled GitHub Actions
- runner crashes
- failed shutdown workflows
- bugs in lifecycle logic
- network failures

---

# 32. CI Concurrency

Destructive lifecycle tests must be protected against conflicting concurrent runs.

The CI architecture must prevent two workflows from mutating the same Terraform state or shared persistent CI environment simultaneously.

Terraform state locking and GitHub Actions concurrency controls must both be used where appropriate.

---

# 33. Terraform State

Terraform state must be remote.

Both:

```text
GitHub Actions
```

and:

```text
developer workstation
```

must use the same state for a given environment.

Separate state boundaries must exist for:

```text
bootstrap
persistent
disposable
CI persistent
CI disposable
```

This ensures that routine cluster destruction cannot accidentally destroy persistent resources.

State locking must prevent concurrent infrastructure mutations.

---

# 34. Local and GitHub Lifecycle Equivalence

The platform must expose the same high-level lifecycle interface locally and in GitHub Actions.

Local:

```text
make up
make down
```

GitHub:

```text
lab-up.yml
    ↓
make up

lab-down.yml
    ↓
make down
```

The environment initiating the operation must not affect infrastructure semantics.

GitHub authenticates through OIDC.

Local execution may authenticate through AWS IAM Identity Center/SSO or another approved temporary credential mechanism.

---

# 35. Application Integration Boundary

Application repositories are external consumers of this platform.

The platform may expose standardized interfaces such as:

- container image deployment
- DNS
- TLS
- Gateway API routes
- secrets references
- observability
- PostgreSQL access
- Kafka access

The platform should not require application source code to reside in this repository.

Application deployment strategies may later include:

```text
application repository
       ↓
build image
       ↓
container registry
       ↓
update deployment reference
       ↓
Argo reconciles platform
```

The exact application delivery workflow is outside the initial scope of this architecture.

---

# 36. Cost Principles

The platform is educational and should minimize idle cost.

Principles:

- destroy EKS when not needed
- dynamically scale workload nodes with Karpenter
- cap dynamic compute
- preserve inexpensive storage instead of expensive compute
- avoid unnecessary NAT Gateways
- minimize observability retention
- use appropriately small component configurations
- avoid unnecessary managed-service costs
- use a combined Secrets Manager object where appropriate for the lab
- avoid running full AWS lifecycle CI unnecessarily

Full integration testing should be triggered intelligently rather than blindly for every textual change.

---

# 37. Platform Invariants

All implementation specifications must preserve the following:

1. The repository contains platform code only.
2. Application source code is external to the platform repository.
3. No plaintext secret may be committed to Git.
4. GitHub Actions require no long-lived AWS credential.
5. Terraform and Argo CD must not own the same Kubernetes resource.
6. Persistent data must survive normal `make down`.
7. EKS and disposable compute must disappear after successful shutdown.
8. Controllers remain available until owned resources finish cleanup.
9. Kubernetes-side deletion ordering is primarily encoded through Argo/Kubernetes.
10. ALB provides AWS ingress; Envoy owns application traffic policy.
11. Significant platform components expose useful telemetry.
12. The platform is reconstructable from Git and persistent state.
13. Local and GitHub lifecycle operations behave equivalently.
14. Lifecycle operations are idempotent where practical.
15. Every PR receives appropriate fast validation.
16. Infrastructure-critical changes can be proven through a real lifecycle test.
17. Full lifecycle CI must validate creation, deletion, persistence, recreation, and cleanup.
18. CI must not endanger the personal persistent environment.
19. Failed CI runs must make a best effort to clean up their disposable infrastructure.
20. A successful Terraform destroy does not alone prove successful platform shutdown.
21. `make up` never creates Persistent resources implicitly; `make down` never destroys Persistent or Bootstrap resources. Removing those is a separate, explicitly-confirmed command (§21a).

---

# 38. Definition of Platform Success

The platform is considered successfully implemented when the following scenario can be executed automatically:

```text
START:
No EKS cluster exists.

        ↓

make up

        ↓

VERIFY:
EKS ready
Argo healthy
Karpenter healthy
Kafka healthy
PostgreSQL healthy
Debezium healthy
Prometheus healthy
Envoy healthy
ALB healthy
HTTPS reachable

        ↓

WRITE DATA:
PostgreSQL test data
Kafka test data

        ↓

VERIFY:
CDC works
metrics available
logs available
traces available where applicable

        ↓

make down

        ↓

VERIFY:
EKS absent
EC2 nodes absent
ALB absent
persistent state present

        ↓

make up

        ↓

VERIFY:
platform reconstructed automatically
PostgreSQL data recovered
Kafka data recovered
HTTPS healthy again

        ↓

make down

        ↓

VERIFY:
no disposable infrastructure leaked
persistent infrastructure remains
```

The same scenario must eventually be executable by the full GitHub Actions validation pipeline.

This end-to-end lifecycle is the ultimate acceptance criterion for the platform.

---

# 38a. Full Teardown Including Persistent

A second, deliberately rare scenario proves the Persistent-lifecycle destroy path (`make persistent-down`, §21a) actually works — it is not part of the routine two-pass scenario in §38, and is not run on every change:

```text
START:
Disposable stack already torn down via make down (§38's routine scenario).

        ↓

make persistent-down (with disposable resources still present)

        ↓

VERIFY:
refused — disposable resources must be gone first

        ↓

make down (confirm disposable is fully torn down)

        ↓

make persistent-down (explicit confirmation step)

        ↓

VERIFY:
lab.<root-domain> hosted zone deleted
ACM certificate deleted
every Secrets Manager secret deleted
every retained EBS volume deleted
parent/root hosted zone untouched throughout
only Bootstrap-lifecycle resources remain
```

This scenario is exercised once per material change to specs 001/002/013 — for example, in a disposable/throwaway AWS account — never as a routine check against the real personal-lab account.

---

# 39. Resource Tagging Standard

Every AWS resource this repository's Terraform creates must be identifiable as platform infrastructure, distinct from any future business/service infrastructure, and traceable to its lifecycle class (§6). This is an ownership/identity requirement, not just a lifecycle-tracking convenience — see constitution §16 for the binding rule.

Minimum tag set, applied to every Terraform-managed resource:

```text
Project     = vk-lab-platform
Scope       = platform
Lifecycle   = bootstrap | persistent | disposable
ManagedBy   = terraform
```

`Project` and `Scope` exist specifically so that, looking at any resource in the AWS account, it is unambiguous that it belongs to this platform and not to a business/application service — reinforcing §2's repository-scope boundary at the infrastructure level, not only in source control.

These defaults should be set once, at the provider level (a `default_tags` block established in the bootstrap stack, §1 of the specs roadmap), so every later stack inherits them automatically rather than relying on each resource remembering to tag itself.

Where Kubernetes controllers create AWS resources on Terraform's behalf (the AWS Load Balancer Controller's ALB, `external-dns`'s Route 53 records, the EBS CSI driver's volumes), the same tags/labels should be applied where the controller supports it, so identification holds consistently across the Terraform/Argo ownership boundary (§7).