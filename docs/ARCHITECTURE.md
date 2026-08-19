# Platform Architecture and Target State

## 1. Purpose

This document defines the target architecture for the AWS/EKS learning platform.

It is the architectural source of truth for implementation specifications under `/specs`.

Individual specifications may introduce implementation details, but they must remain consistent with the architectural boundaries, lifecycle rules, ownership model, security requirements, and invariants defined here.

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
platform/
├── .github/
│   └── workflows/
│       ├── validate.yml
│       ├── terraform-plan.yml
│       ├── platform-integration.yml
│       ├── lab-up.yml
│       ├── lab-down.yml
│       └── cleanup-stale-ci.yml
│
├── terraform/
│   ├── modules/
│   │   ├── terraform-state/
│   │   ├── github-oidc/
│   │   ├── kms/
│   │   ├── secrets-manager/
│   │   ├── vpc/
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
│       │   └── kms/
│       │
│       ├── persistent/
│       │   ├── terragrunt.stack.hcl
│       │   ├── vpc/
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
│   └── lab-secrets.enc
│
├── specs/
│   ├── 000-constitution/
│   ├── 001-bootstrap/
│   ├── 002-persistent-foundation/
│   ├── 003-network-and-eks/
│   ├── 004-storage-contract/
│   ├── 005-argocd-bootstrap/
│   ├── 006-karpenter/
│   ├── 007-postgres/
│   ├── 008-kafka/
│   ├── 009-debezium/
│   ├── 010-observability/
│   ├── 011-envoy-gateway/
│   ├── 012-public-edge/
│   ├── 013-secrets/
│   ├── 014-lifecycle/
│   └── 015-ci-validation/
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

- VPC
- subnets
- Route 53 hosted zone
- ACM certificate
- Secrets Manager
- RDS
- retained EBS volumes
- persistent S3 resources

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

The VPC belongs to the persistent infrastructure layer.

This allows RDS and other persistent infrastructure to survive EKS destruction.

Networking should support:

- EKS
- ALB
- Karpenter
- RDS
- EBS
- Pod Identity
- AWS controllers

Unnecessary permanent network costs, especially NAT Gateway costs, should be avoided where practical for the educational environment.

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
api.lab.example.com
grafana.lab.example.com
argocd.lab.example.com
```

---

# 12. DNS and TLS

Route 53 owns DNS.

ACM owns public TLS certificates.

Both belong to the persistent infrastructure lifecycle.

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

The plaintext secret is encrypted with AWS KMS before entering Git.

```text
plaintext
   ↓
KMS Encrypt
   ↓
ciphertext
   ↓
public Git repository
```

The repository may therefore contain:

```text
secrets/lab-secrets.enc
```

Only authorized AWS identities may decrypt it.

Decrypted values should be written directly to Secrets Manager without unnecessarily persisting plaintext in Terraform state.

For cost optimization, the initial platform may keep multiple related credentials inside one Secrets Manager JSON object.

This is an intentional lab-specific trade-off rather than the preferred isolation model for production systems.

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

# 22. Platform Start

The user-facing command is:

```text
make up
```

Architecturally:

```text
make up
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
disposable Kubernetes resources
disposable AWS resources
```

These must remain:

```text
Terraform state
KMS
Secrets Manager
VPC
Route 53
ACM
RDS where applicable
retained EBS data
persistent S3 resources
```

`terragrunt destroy` returning successfully is not by itself sufficient to declare shutdown successful.

Postconditions must be verified.

---

# 25. CI/CD Philosophy

CI/CD is part of the platform architecture, not an optional afterthought.

The platform uses two validation levels:

```text
FAST VALIDATION
every pull request

FULL VALIDATION
selected infrastructure-relevant changes
```

The goal is to combine fast developer feedback with high confidence in real platform lifecycle behavior.

---

# 26. Fast Validation

Every pull request must perform fast validation that does not require provisioning an EKS environment.

This should include, where applicable:

```text
Terraform formatting
Terraform validation
Terragrunt validation
Terraform/Terragrunt plan
Helm rendering
Kubernetes schema validation
YAML validation
policy checks
security scanning
Argo manifest validation
GitHub workflow validation
```

Fast validation should detect most structural/configuration problems before expensive AWS integration testing is attempted.

Documentation-only changes should normally require only appropriate fast checks.

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