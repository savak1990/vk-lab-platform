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
- AWS NLB
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
11. AWS NLB as the public AWS entry point, TLS-terminated with an ACM certificate.
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
│       ├── kind-integration.yml        # spec 023; cheap GitOps test, trusted-context PRs only
│       ├── platform-integration.yml    # spec 019; full-AWS test; mode=routine|resilience
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
│       ├── state/                      # ADR 0004; own lifecycle class below Bootstrap; make state-up / state-down (ADR 0005, guarded)
│       │
│       ├── bootstrap/
│       │   ├── terragrunt.stack.hcl
│       │   ├── kms/
│       │   ├── github-oidc/            # spec 001; one account-level provider, created once (§17a, ADR 0007)
│       │   └── atlantis/               # spec 017; standalone compute, independent of EKS; own instance/task role, not OIDC
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
│       ├── disposable/            # aws target only; the local target (§10a) has no Terraform-managed equivalent
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
│   │   ├── aws/                   # values-aws.yaml only; omitted from the local target's app list (§10a)
│   │   │   ├── aws-load-balancer-controller/
│   │   │   ├── external-dns/
│   │   │   └── secrets-store-csi/
│   │   │
│   │   ├── autoscaling/
│   │   │   └── karpenter/         # values-aws.yaml only; omitted from the local target's app list (§10a)
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
│   ├── postgres-app-password.enc
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
│   ├── 009-observability/
│   ├── 010-envoy-gateway/
│   ├── 011-nlb-edge/
│   ├── 012-external-dns/
│   ├── 013-secrets/
│   ├── 014-lifecycle/
│   ├── 015-github-actions-lifecycle/
│   ├── 016-branch-protection/
│   ├── 017-atlantis-terraform-automation/
│   ├── 018-ci-fast-validation/
│   ├── 019-ci-full-lifecycle-validation/
│   ├── 020-vpc/
│   ├── 021-local-dev-mode/        # local (minikube/kind) target; shapes specs 004, 006-013 from inception (§10a, ADR 0006)
│   ├── 022-e2e-test-framework/    # Go/Ginkgo/Gomega suite + environment abstraction, reused by 019 and 023
│   ├── 023-ci-kind-integration-test/  # cheap kind-based GitOps CI test consuming 021 and 022
│   ├── 024-kafka/                 # deferred (ADR 0017) - re-implement before 025-debezium
│   └── 025-debezium/              # deliberately implemented last, after CI/CD and local-dev tooling exist
│
├── tests/
│   └── e2e/                       # spec 023; suite_test.go, per-service tests, framework/
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

Infrastructure is divided into four lifecycle classes. These four classes govern the `aws` target only. The `local` target (§10a) sits outside this taxonomy entirely — it is not a fifth class; its cluster and workloads simply are not managed by, or subject to, any of the rules below (constitution §18).

## State

The Terraform remote-state S3 bucket itself — the one resource every other
unit in this repository, including Bootstrap, depends on to store its own
state. See ADR 0004 for why this is its own layer rather than a unit
inside Bootstrap, and ADR 0005 for why a guarded `make state-down` exists
despite that: destroy bypasses Terraform entirely (plain S3 API calls), so
there's no final state write to fail.

Lifecycle:

```text
created once (make state-up)
    ↓
essentially never destroyed (make state-down — guarded, ADR 0005)
```

## Bootstrap

Bootstrap infrastructure establishes the root of trust and infrastructure-management foundation.

Examples:

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
- NLB
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

Argo CD's own installation is bootstrapped by `make argo-up` (a script), run after the disposable EKS cluster exists — not by Terraform (ADR 0012).

## Argo CD owns

Kubernetes-native resources including:

- Karpenter controller/configuration
- AWS Load Balancer Controller
- ExternalDNS
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
                            NLB
                      TLS using ACM
                       (443 only, no routing)
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

EKS Auto Mode is deliberately not used: it provisions node capacity through
AWS's own scheduler, outside Karpenter's ownership, which would collide
with this platform's explicit "Karpenter owns workload capacity" boundary
(§2) rather than compose with it.

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
- NLB
- Karpenter
- RDS (if used)
- EBS
- Pod Identity
- AWS controllers

Unnecessary permanent network costs, especially NAT Gateway costs, should be avoided where practical for the educational environment — this applies both to the current no-VPC state (trivially true, there is no NAT Gateway) and to the future dedicated VPC (a NAT Gateway must be explicitly justified, not added by default).

---

# 10a. Execution Targets: `aws` and `local`

The platform supports two Argo CD execution targets: **`aws`** (real EKS, the
target described throughout the rest of this document unless stated
otherwise) and **`local`** (minikube or kind, AWS-free except where noted).
See ADR 0006 and spec 021 for the full design; this section summarizes the
shape of it so later sections can refer to "the `aws` target" and "the
`local` target" unambiguously.

Both targets share a single `gitops/` tree. Every component under `gitops/`
is one Helm chart with a shared `values.yaml` plus `values-aws.yaml` and
`values-local.yaml` overrides — not a duplicated manifest tree, not
Kustomize overlays. A single root Argo `Application` (spec 004) is
parameterized by a `target` value at install time; an umbrella/app-of-apps
chart uses that value to omit AWS-only components (Karpenter, AWS Load
Balancer Controller, external-dns, EBS CSI driver, RDS) from the rendered
app list entirely when `target=local`.

The two targets diverge in kind, not just in values, on several points:

- **Install path.** Both targets: `make argo-up`/`make argo-down` (scripts)
  install/remove Argo CD and the root Application — no Terraform involved
  for either target (ADR 0012, spec 004 Requirement 1). `aws` additionally
  requires the disposable EKS cluster to exist first (`make cluster-up`);
  `local` entry points are `make minikube-up` and `make kind-up`; there is
  no unified `make local-up` wrapper.
- **Persistence.** `aws`: Postgres/Kafka data is Persistent-lifecycle,
  surviving `make down` (§6, spec 005). `local`: fully throwaway — no
  persistent-lifecycle class, default local StorageClass with `Delete`
  reclaim semantics, no destroy/recreate persistence proof.
- **Public edge.** `aws`: Route53 → NLB → Envoy (§11–12); ExternalDNS
  (spec 012) publishes the Route 53 records, AWS Load Balancer Controller
  (spec 011) provisions the NLB. `local`: no NLB/Route53/ACM/ExternalDNS;
  access is via `kubectl port-forward` directly to Envoy Gateway's Service,
  forced to `ClusterIP` in `values-local.yaml`.
- **Routing.** `aws`: Gateway API `HTTPRoute`s match by hostname
  (`api.lab.<root-domain>`). `local`: routes match by path (`/api`,
  `/grafana`, `/argocd`), since `kubectl port-forward` to `localhost` can't
  present a matching Host header. This is a permanent, accepted divergence.
- **TLS.** `aws`: ACM certificate, terminated at the NLB's TLS listener
  (§12) — Envoy never holds a certificate. `local`: plain HTTP, no TLS
  anywhere in the request path.
- **Secrets.** `aws`: Secrets Manager + Pod Identity (spec 013). `local`:
  placeholder credentials loaded directly into Kubernetes `Secret` objects by
  default, with an opt-in path to decrypt real values from `secrets/*.enc`
  via AWS KMS instead (spec 021) — neither local path touches Secrets
  Manager, Pod Identity, or External Secrets Operator.
- **Sync source.** `aws`: the root Application syncs from the GitHub repo.
  `local`: the root Application syncs from the local working directory on
  disk, so `gitops/` edits reconcile without a commit/push.

The `local` target sits outside the State/Bootstrap/Persistent/Disposable
lifecycle model (§6) entirely — it is not a fifth class, it simply isn't
governed by that taxonomy (constitution §18). A successful `local` run is
never a substitute for the `aws`-target full lifecycle acceptance test (§38)
or constitution §12's Definition of Done; it is a faster inner dev loop, not
a smaller version of the real thing.

---

# 11. Public Edge

The public request path is:

```text
client
  ↓
Route 53 (ExternalDNS-managed record, spec 012)
  ↓
NLB (AWS Load Balancer Controller, spec 011)
  ↓
Envoy Gateway
  ↓
Kubernetes service
```

There is no AWS-side `Ingress` or `Gateway` resource in this path — the NLB
is provisioned directly from Envoy Gateway's own `Service`/`EnvoyProxy`
object (spec 010/011). Gateway API, via Envoy's `HTTPRoute`s, is the only
routing definition anywhere in this design.

## NLB responsibility

The NLB provides:

- AWS-managed public ingress
- ACM TLS termination (a TLS listener on port 443 using the persistent ACM
  certificate, §12) — no port 80, no HTTP→HTTPS redirect at this layer
- target health checks
- Proxy Protocol v2 to Envoy, so client IP survives the NLB hop
- forwarding to Envoy

The NLB performs no host/path routing at all — not "should not duplicate,"
literally cannot: an NLB operates at L4. All routing logic lives in Envoy.

(An ALB was the initial design; NLB+ACM was chosen instead — see ADR 0011
for the comparison against NLB+cert-manager and why ACM/Terraform-owned
certificates were kept.)

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

Envoy's `Gateway` listener is plain HTTP — it never holds a TLS
certificate; TLS ends at the NLB.

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

The ACM certificate must be created in the same AWS region as the NLB that uses it (§11), and should use DNS validation against the delegated `lab.<root-domain>` hosted zone rather than email validation.

The existing root-domain certificate is not reused for the platform. The lab subdomain gets its own certificate unless a later ADR explicitly changes this decision.

## What the platform does not own

The parent/root hosted zone, and the root domain registration itself, are external infrastructure and outside this repository's lifecycle. The platform:

- MUST NOT create or delete the parent/root hosted zone itself, during normal operation (`make up`/`make down`) or otherwise;
- MUST NOT manage any record in the parent hosted zone other than the single NS record delegating `lab.<root-domain>`;
- manages that one delegation record directly: the persistent stack's `route53` unit locates the parent zone by name (`data "aws_route53_zone"`, `private_zone = false` — not an explicit zone-ID input) and creates/removes the NS record pointing at the lab zone's name servers, as part of `make persistent-up`/`make persistent-down`. This assumes the parent zone is itself a Route 53 hosted zone reachable with the same AWS credentials; where that assumption doesn't hold (the root domain is at a registrar or another DNS provider with no Route 53 API), delegation instead remains a one-time external/manual bootstrap step, performed outside normal platform lifecycle.

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

Route 53 record (ExternalDNS-managed, spec 012)
    ↓
NLB (AWS Load Balancer Controller, spec 011)
    ↓
Envoy Gateway
    ↓
platform/application workloads
```

## Records inside the lab zone

Individual DNS records inside the delegated `lab.<root-domain>` zone (for
example, the record pointing at the NLB) are disposable — they are created
and removed as part of normal `make up`/`make down` operation. Ownership of
these records is explicit and does not overlap between Terraform and
Kubernetes controllers: ExternalDNS (spec 012, Argo-managed) owns
application-hostname record lifecycle, reading hostnames directly from
Envoy's `HTTPRoute`s (`--source=gateway-httproute`); Terraform owns only the
hosted zone, the certificate, and the certificate's own DNS-validation
record. ExternalDNS runs with a TXT ownership registry
(`--registry=txt`, a unique `--txt-owner-id`, `--domain-filter` scoped to
`lab.<root-domain>`) specifically so its sync-mode reconciliation cannot
touch records it doesn't recognize as its own — including that ACM
validation record. `--policy=upsert-only` is not used as a substitute for
this guard, since it would leave orphaned records behind on `make down`.

The hosted zone and certificate are never deleted by `make down` (§23–24).

## Domain value handling

The real root domain value is private configuration, not a security credential. Keeping it out of the public repository is repository hygiene — avoiding exposure of personal infrastructure details — not a security control. See §18 for how the value is stored and supplied to Terraform.

## TLS termination

TLS termination occurs at the NLB's TLS listener, using the ACM certificate
above. Envoy Gateway never holds a certificate — its `Gateway` listener is
plain HTTP (spec 010).

End-to-end TLS between the NLB and Envoy is not implemented — the NLB
forwards plaintext, and client IP is preserved via Proxy Protocol v2 (spec
011) rather than by re-establishing TLS to Envoy.

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

PostgreSQL storage must support online, grow-only capacity expansion (`StorageClass` with `allowVolumeExpansion: true`, resized declaratively through the operator's CR, not by hand-editing the EBS volume). See spec 007 for the full storage-expansion lifecycle.

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

`StorageClass`es backing persistent workloads (Postgres, Kafka) must also set `allowVolumeExpansion: true`, since EBS/its CSI driver support online expansion — capacity growth must never require volume replacement or data migration. Growth is one-directional: a shrink is not supported and is not a platform requirement.

Before destructive lifecycle operations, the platform must verify that persistent data will not be deleted.

The recreation process must define how persistent volumes are rediscovered, rebound, or restored.

This behavior must be covered by full lifecycle CI.

---

# 17. Secrets and Identity

This section describes the `aws` target. The `local` target does not use Secrets Manager, Pod Identity, or External Secrets Operator at all — see §10a and spec 021 for its placeholder-by-default, KMS-decrypt-opt-in secrets mechanism.

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

# 17a. Account Bootstrap and GitHub OIDC

The GitHub OIDC provider (`token.actions.githubusercontent.com`) is
account-level, region-agnostic AWS IAM infrastructure: AWS permits exactly
one such provider per provider URL per account, and the same provider
authenticates GitHub Actions runs deploying into any AWS region. It is
created exactly once, as part of Bootstrap (§6, spec 001), and is never
recreated or destroyed by `make up`/`make down`/`make bootstrap-down` — it
sits alongside the KMS key as foundational, essentially-permanent account
infrastructure (ADR 0007).

Individual **IAM roles** trusting that provider are a separate concern.
Each role belongs to the spec that uses it. Each role is scoped to only
the state paths and actions it needs:

```text
one GitHub OIDC provider (spec 001, Bootstrap, created once)
        │
        ├── personal-lab role (spec 015) — "normal deploy"
        │     scoped to the personal lab's persistent/disposable state
        │
        └── CI role (spec 019) — "privileged full-environment test"
              scoped to ci/* state paths only
```

Atlantis (spec 017) does not use this provider at all — it authenticates via
its own compute's instance/task role, never OIDC (ADR 0003).

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
├── postgres-app-password.enc
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

## GitHub Actions' path to the domain value

The KMS-encrypted `secrets/root-domain.enc` mechanism above is for
workstation/local use (Terraform apply from a laptop, `scripts/secret-decrypt.sh`).
GitHub Actions workflows that need the root domain value (spec 002, 014, 018)
instead read it from a GitHub Actions secret (`ROOT_DOMAIN`, §24a) supplied
directly by the repository/environment configuration — a separate delivery
path for the same value, not a replacement for the committed ciphertext file.
This avoids granting every consuming workflow KMS decrypt permission just to
learn a non-secret hostname.

---

# 19. Observability

This section describes the full `aws`-target stack. The `local` target runs the same components but with a reduced, explicitly-stated sizing/retention posture for laptop scale (§10a); any component omitted for `local` must be stated explicitly, not silently dropped — see spec 021 for specifics.

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

```text
Terraform: EKS
 ↓
make argo-up (script): Argo CD
 ↓
root Application
```

Terraform bootstraps EKS; `make argo-up` (not Terraform — ADR 0012) then
installs Argo CD and creates the root Application once the cluster exists.
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
   ↓ deletes NLB resources
controller deleted afterward
```

---

# 21a. Lifecycle Command Surface

Each lifecycle class (State, Bootstrap, Persistent, Disposable — §6) gets its own explicit create command. No command implicitly creates or destroys a different lifecycle class's resources; see constitution §17 for the binding rule.

```text
make state-up           creates the State layer (the Terraform state S3 bucket)
make state-down         destroys it — guarded, expected to run essentially never (ADR 0004, ADR 0005)

make bootstrap-up      verifies the State layer exists (fails if not, never creates it), then creates Bootstrap-lifecycle resources (OIDC, IAM, KMS, Atlantis)
make bootstrap-down    destroys them — guarded, expected to run essentially never

make persistent-up     creates Persistent-lifecycle resources (lab DNS zone, ACM cert, Secrets Manager, retained EBS)
make persistent-down   destroys them — guarded, deliberate, rarely used, real and permanent data loss

make up                creates Disposable-lifecycle resources (EKS, then argo-up: Argo, workloads)
make down              destroys them — argo-down (Argo cascade) then Terragrunt destroy — the routine, frequently-used command
```

`make up`/`make down` compose `cluster-up`/`argo-up` and `argo-down`/`cluster-down` respectively (ADR 0012, spec 006-1) — `argo-down`'s Argo-driven cascade must complete before `cluster-down` touches the EKS cluster, since only Argo/Karpenter's own controllers can clean up the AWS resources they provisioned outside Terraform.

`make minikube-up` and `make kind-up` (the `local` target, §10a) are separate commands outside this lifecycle-class command surface entirely — they don't create or destroy any State/Bootstrap/Persistent/Disposable resource, so they aren't governed by the "one command per class" rule below.

`make up` verifies that Persistent-lifecycle resources already exist before doing anything else. If they do not, it fails with an actionable error telling the operator to run `make persistent-up` first — it never creates Persistent resources on the caller's behalf. This keeps the "what survives `make down`" boundary (§6) visible at the command layer, not just in Terraform state layout.

`make persistent-down` and `make bootstrap-down` are destructive, rarely-used escape hatches, not part of the routine up/down cycle:

- `make persistent-down` MUST refuse to run while any Disposable-lifecycle resource still exists (mirroring the controller-cleanup ordering in §21 — Disposable resources that reference Persistent ones, such as DNS records inside the lab hosted zone, must be gone first) and MUST require an explicit confirmation step, since it deletes the lab DNS zone (and its parent-zone NS delegation record), certificate, Secrets Manager contents, and retained EBS volumes permanently. It MUST verify afterward that every unit's Terraform state is actually empty before reporting success, rather than trusting a possibly-partial destroy.
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
AWS Load Balancer Controller provisions NLB
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
AWS LB Controller removes NLB
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
NLB
Envoy
Kafka/Postgres pods
observability pods
disposable Route 53 records inside the lab hosted zone (e.g., the NLB's DNS record)
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

# 24a. Fork Configurability

A forked repository must be runnable against the fork owner's own AWS
account and domain with **zero source-code changes**. Constitution §19 is
the binding statement of the required setup steps and the GitHub
variable/secret contract — this section only adds the rationale: this is
what makes the repository genuinely forkable rather than personally-owned
infrastructure with a public mirror.

`AWS_ROLE_ARN` and `AWS_REGION` are configuration, not credentials — plain
GitHub variables are appropriate. `ROOT_DOMAIN` is private/hygiene data
(§12, §18) delivered to GitHub Actions as a secret directly (§18's "GitHub
Actions' path to the domain value"), never a hardcoded value in workflow
YAML, Terraform, Helm values, or documentation (constitution §19, ADR 0007).

---

# 25. CI/CD Philosophy

CI/CD is part of the platform architecture, not an optional afterthought.

All changes reach `main` through a reviewed pull request — direct pushes to `main` are disabled (spec 016). The platform uses four complementary mechanisms on top of that, chosen by what actually changed (change-aware CI, §26):

```text
FAST VALIDATION
every pull request — lint/format/schema checks only, no AWS credentials

TERRAFORM PLAN/APPLY AUTOMATION
every pull request touching terraform/** — plan on PR, apply on merge

KIND-BASED GITOPS INTEGRATION TEST
pull requests touching gitops/** (or the disposable stack) — real Argo CD
reconciliation and E2E assertions against a kind cluster, no AWS at all

FULL LIFECYCLE VALIDATION
manually triggered, or on infrastructure-relevant changes to main — a real,
shared, serialized AWS/EKS environment
```

The goal is to combine fast developer feedback, safe and auditable Terraform changes, and high confidence in real platform lifecycle behavior — at a cost proportional to what the change actually touches, not a fixed cost per PR.

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

## Change-aware gate

Because different checks apply to different changes (path filters), a
required GitHub status check must not itself be path-filtered — a
path-filtered job that never runs leaves a required check permanently
pending, blocking merge indefinitely. Fast validation therefore includes an
always-running gate job that determines which change categories (Terraform,
GitOps/Helm, documentation-only) apply to the PR and always reports a
result — success or explicit skip — for each, fanning out to the relevant
path-filtered sub-jobs rather than letting them stand as required checks on
their own.

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

# 26b. Kind-Based GitOps Integration Test

Pull requests touching `gitops/**` (or anything in the disposable stack that
affects what Argo CD reconciles) get a cheap, AWS-free integration test
(spec 023): create a kind cluster, install Argo CD via the `local` target's
plain-script install path (§10a, spec 021), apply the repository's normal
GitOps bootstrap with the root Application's `targetRevision` pointed at the
PR's exact commit (not `main`), let Argo reconcile the platform, then run the
same Go/Ginkgo E2E suite (§27, spec 022) used against real EKS.

Tests never install Postgres/Kafka/Grafana themselves — Argo CD owns
installation here exactly as it does for the `aws` target; the point is to
test the actual GitOps reconciliation path, not to re-implement it in test
setup code.

This test cannot faithfully exercise AWS-specific integrations: NLB,
Route 53, ACM, EBS/EFS CSI, Pod Identity, or AWS Secrets Manager integration.
Those remain Full Lifecycle Validation's job (§27–28). It runs only in a
trusted GitHub context (§30) — even though it touches no AWS resources, it
still spends real runner compute on PR-controlled code.

---

# 27. Full Platform Validation

Infrastructure-relevant changes should be capable of triggering a complete platform lifecycle test.

Verification against the real platform, here and in the kind-based test
(§26b), is expressed as a Go test suite (Ginkgo v2/Gomega, `client-go` for
Kubernetes access, `pgx` for PostgreSQL, `net/http` for HTTP API checks —
spec 022), not a bash script re-implemented per environment. An
`Environment` abstraction lets the same assertions run against a kind
cluster or real EKS by changing only how a service is reached (port-forward
vs. real ingress/DSN), not what is asserted.

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
   - NLB healthy
   - HTTPS works

4. Write known data to PostgreSQL.

5. Produce known data to Kafka.

6. Verify CDC where applicable.

7. Run platform shutdown.

8. Verify:
   - EKS absent
   - compute absent
   - NLB absent
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
├── persistent     CI's own delegated subdomain (ci.lab.<root-domain>)
│                  and certificate (*.ci.lab.<root-domain>)
└── disposable     one shared ephemeral environment, torn down after
                   each run
```

CI lifecycle tests must never operate on personal persistent volumes,
databases, or state. CI's persistent layer (the `ci.lab.<root-domain>` zone
and certificate) and its disposable layer are both shared, single
environments — not one per PR. A full-lifecycle run tags its disposable
resources `Ephemeral=true` (§16) so a stale-resource cleanup job can find
them (§31).

Only one full-lifecycle run proceeds at a time (§32) — full lifecycle tests
already require a trusted/maintainer trigger (§30), not every fork PR, so
one shared, serialized environment keeps the design simple without a real
concurrency cost at that trigger frequency.

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

The CI architecture must prevent two workflows from mutating the same Terraform state simultaneously. One GitHub Actions `concurrency:` group, with `cancel-in-progress: false`, covers the full-lifecycle workflow as a whole: successive triggers queue behind each other rather than racing against the same shared `ci/disposable` environment (§29). Terraform state locking (native S3 lockfile locking, per stack) provides the underlying guarantee that two runs can never write the same state concurrently even if the GitHub-side concurrency group were somehow bypassed.

Cheap, stateless jobs (fast validation, the kind-based GitOps test) use ordinary PR-scoped concurrency with `cancel-in-progress: true` instead — nothing is lost by cancelling a superseded run of a check that holds no infrastructure.

---

# 32a. Test Frequency and Confidence Levels

Not every change deserves the same test cost. Roughly:

```text
GitOps/Argo/Helm/Kubernetes config change
    → kind-based GitOps integration test (§26b) + Go/Ginkgo E2E suite

Terraform/full-infra pull request
    → apply → E2E suite → idempotency check (plan shows no diff) → destroy
    (the shared ci/disposable environment, §29)

scheduled (e.g. nightly) or manually triggered
    → recreate-after-destroy resilience test:
      create → E2E → destroy → create → E2E → destroy
      (platform-integration.yml, run with mode=resilience)
```

The recreate-after-destroy resilience proof is deliberately not run on every
full-infra PR — it primarily validates teardown/recreation behavior, which
doesn't change with every Terraform edit, and it costs roughly twice a
routine full-infra run. Running it on a schedule (or on demand) rather than
per-PR keeps routine infra review fast without losing that proof entirely.

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

# 34. Workstation-Initiated and GitHub Lifecycle Equivalence

The platform must expose the same high-level lifecycle interface whether initiated from a developer's workstation (running `make up`/`make down` against real AWS) or from GitHub Actions. "Workstation-initiated" here means the `aws` target (§10a) run from a laptop — this is distinct from the `local` target (minikube/kind, §10a), which has no AWS equivalence requirement to satisfy.

Workstation-initiated:

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

Workstation-initiated execution may authenticate through AWS IAM Identity Center/SSO or another approved temporary credential mechanism.

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
10. The NLB provides AWS ingress and TLS termination; Envoy owns all application traffic policy and routing.
11. Significant platform components expose useful telemetry.
12. The platform is reconstructable from Git and persistent state.
13. Workstation-initiated and GitHub lifecycle operations behave equivalently (§34).
14. Lifecycle operations are idempotent where practical.
15. Every PR receives appropriate fast validation.
16. Infrastructure-critical changes can be proven through a real lifecycle test.
17. Full lifecycle CI must validate creation, deletion, persistence, recreation, and cleanup.
18. CI must not endanger the personal persistent environment.
19. Failed CI runs must make a best effort to clean up their disposable infrastructure.
20. A successful Terraform destroy does not alone prove successful platform shutdown.
21. `make up` never creates Persistent resources implicitly; `make down` never destroys Persistent or Bootstrap resources. Removing those is a separate, explicitly-confirmed command (§21a).
22. Exactly one GitHub OIDC provider exists per account, created once in Bootstrap (§17a); every consumer gets its own role trusting it, never its own provider.
23. No workflow, module, or spec hardcodes an account ID, role ARN, region, or domain value — forking requires only account bootstrap plus the configuration values in §24a, never a source change.

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
NLB healthy
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
NLB absent
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
Lifecycle   = state | bootstrap | persistent | disposable
ManagedBy   = terraform
```

`Project` and `Scope` exist specifically so that, looking at any resource in the AWS account, it is unambiguous that it belongs to this platform and not to a business/application service — reinforcing §2's repository-scope boundary at the infrastructure level, not only in source control.

These defaults should be set once, at the provider level (a `default_tags` block established in the bootstrap stack, §1 of the specs roadmap), so every later stack inherits them automatically rather than relying on each resource remembering to tag itself.

Where Kubernetes controllers create AWS resources on Terraform's behalf (the AWS Load Balancer Controller's NLB, ExternalDNS's Route 53 records, the EBS CSI driver's volumes), the same tags/labels should be applied where the controller supports it, so identification holds consistently across the Terraform/Argo ownership boundary (§7).