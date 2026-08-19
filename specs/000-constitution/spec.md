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

### Bootstrap
Rarely destroyed:
- Terraform backend
- GitHub OIDC
- foundational IAM
- KMS

### Persistent
Must survive normal `make down`:
- VPC
- Route 53
- ACM
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