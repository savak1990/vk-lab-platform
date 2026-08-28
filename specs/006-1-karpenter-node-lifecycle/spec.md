# 006-1 — Karpenter Node Lifecycle on Teardown

**Status:** Implemented

**Complexity:** Medium
**Risk:** Medium — a stuck teardown blocks every subsequent `cluster-up`/`cluster-down` cycle until manually unblocked; the failure is silent until AWS's own `DependencyViolation` error surfaces it.
**Estimated cost:** ~0.5–1 day.
**Recommended model:** Sonnet, with an Opus/advisor review pass on the finalizer/cascade-ordering assumptions specifically.
**Depends on:** 004-argocd-bootstrap (the root Application and its cascade-delete mechanism), 006-karpenter (the NodePool this spec drains)
**Lifecycle class(es) touched:** Disposable

## Scope

Fixes an ordering gap between Karpenter-provisioned EC2 instances (created directly by Karpenter's controller, never tracked in Terraform state) and Terraform-driven disposable teardown: nothing today guarantees Karpenter's controller drains and terminates its own nodes before the EKS cluster it runs on disappears.

This spec covers:

- Making Argo CD's app-of-apps cascade deletion actually cascade (it currently doesn't — see Problem below).
- A general drain-before-destroy mechanism, expressed once via Argo sync-wave ordering and cascade finalizers, not a one-off script for Karpenter specifically.
- A hard precondition guard on `cluster-down` that refuses to proceed while the graceful drain hasn't run, rather than a cleanup pass after the fact.

**Adopted prerequisite, not out of scope:** this spec's Requirement 3 only works because Argo CD's own installation moves out of Terraform, onto `scripts/argo-up.sh`/`scripts/argo-down.sh` — that decision is recorded in ADR 0012 (accepted) and supersedes spec 004 Requirement 1. This spec assumes that mechanism exists; it does not re-describe why it was chosen.

Out of scope: any change to Karpenter's NodePool sizing/instance-type bounds (spec 006 already sets those).

## Problem

Karpenter-provisioned EC2 instances exist only as live AWS resources plus Kubernetes `NodeClaim` objects — Terraform never creates them and has no record of their instance IDs. Only Karpenter's own controller can clean them up: deleting a `NodeClaim`/`NodePool` triggers the controller to cordon, drain, and terminate the matching instance, gated by the `karpenter.sh/termination` Kubernetes finalizer on that object.

`terragrunt destroy` on the disposable stack has no awareness of this. It tears down the EKS cluster — and with it, the Karpenter controller pod — at Terraform's own pace. If the controller dies before it finishes draining, its EC2 instances are orphaned: never in Terraform state, so Terraform can't delete them, and their only cleanup path (the controller) is gone. Their network interfaces keep referencing the shared node security group, so `aws_security_group.node`'s destroy fails with `DependencyViolation`, and the entire disposable teardown gets stuck — observed repeatedly in practice, including with EC2 sweep backstops added but not reliably invoked (see Consequences below for the concrete bug this uncovered).

The obvious-looking fix — "delete the Argo CD root Application; that cascades away everything, including Karpenter" — does not work today. No Application in `gitops/` carries the `resources-finalizer.argocd.argoproj.io` finalizer, so deleting an Application deletes only that Kubernetes object; every Helm release, CR, and controller Deployment it owns is left running, orphaned in exactly the way this spec is trying to prevent.

This is not Karpenter-specific. Any future controller that provisions AWS resources outside Terraform — the AWS Load Balancer Controller creating an ALB from an `Ingress`/Gateway API resource, cert-manager requesting an ACM/Let's Encrypt certificate — has the identical shape: an AWS resource that only its owning controller can clean up, and a controller that dies with the cluster if nothing orders its shutdown first.

## Requirements

1. Every Argo Application that owns AWS-resource-creating Kubernetes objects (today: `root`, `karpenter`, `cnpg-operator`, `ebs-csi-driver`) MUST carry `metadata.finalizers: [resources-finalizer.argocd.argoproj.io]`, so deleting the Application actually removes what it manages rather than orphaning it.
2. Resources whose deletion must trigger AWS-side cleanup before their owning controller disappears (e.g. `NodePool`/`EC2NodeClass`) MUST be assigned a higher `argocd.argoproj.io/sync-wave` than the Application installing that controller, so Argo's wave-reversed prune order deletes them first — the same mechanism already used for creation ordering, not a new one.
3. Teardown MUST perform, before any Terraform/Terragrunt destroy of disposable AWS infrastructure: `kubectl delete application root -n argocd --cascade=foreground --wait --timeout=<n>` (or equivalent), and MUST treat a skip of this step (cluster unreachable, controller unavailable) as a loud, visible condition — not a silently-swallowed log line — since a silent skip is indistinguishable from a successful drain until the destroy fails downstream.
4. `cluster-down` MUST refuse to proceed to any Terraform/Terragrunt destroy if the cluster is reachable and the Argo `root` Application still exists — that condition means the graceful drain (Requirement 3) has not completed, and proceeding anyway is exactly what causes the `DependencyViolation` failure this spec fixes. `cluster-down` MUST proceed if the cluster is unreachable — there is nothing to verify against in that state, and destroy must stay resumable after a prior partial/interrupted run rather than being permanently blocked by a guard it can no longer satisfy.
5. This mechanism MUST generalize without new code per component: a future ALB-via-`Ingress` or cert-manager `Certificate` uses the same finalizer + sync-wave pattern, not a bespoke drain script.
6. The design MUST hold in the future `local` target (spec 022, minikube/kind) with no cloud-specific logic — `kubectl delete application root --cascade=foreground` is the same command regardless of where the cluster runs.

## Implementation hints

- Verify the load-bearing assumption empirically before relying on it: does Argo's wave-reversed prune *block* until each wave's resources are actually gone (finalizer cleared), or does it just issue the delete calls in order? Test by deleting `root` and watching `kubectl get nodepool -w` / `kubectl get application karpenter -n argocd -w` — the `karpenter` Application must not start disappearing until `NodePool` is fully gone. If it doesn't block, this spec's Requirement 3 needs an explicit wait loop around each wave instead of relying on cascade delete alone.
- See ADR 0012 for why this mechanism is implemented as `scripts/argo-up.sh`/`scripts/argo-down.sh` rather than folded into the existing Terraform-driven `cluster-up`/`cluster-down` — the ordering guarantee this spec needs is not one `terraform-provider-helm` can reliably give (see that ADR's Context for the specific upstream issues found).
- No EC2 sweep — the guard (Requirement 4) plus a genuinely completing cascade (verified per the first bullet above) means there should be nothing left to sweep by the time `cluster-down` runs. Don't reintroduce one silently if the empirical verification above ever fails; surface that instead.

## Testing / acceptance criteria

- With a Postgres workload scheduled on a Karpenter-provisioned node, running `argo-down` then `cluster-down` (or the future `make down`) leaves zero Karpenter-tagged EC2 instances running, and the disposable stack's `terragrunt destroy` completes without a `DependencyViolation` retry loop.
- Running `cluster-down` directly, skipping `argo-down`, while the cluster is reachable and `root` still exists: it refuses with a clear, actionable message rather than proceeding.
- Running `cluster-down` after an interrupted prior destroy (cluster already unreachable, some AWS resources still present): it proceeds rather than getting stuck on the guard.
- The skip condition (cluster/controller unreachable) is visible in the run's primary output, not only in a log line easy to miss inside `terragrunt run --all destroy` noise.
- Repeating the full sequence twice back-to-back (per spec 014's idempotency expectation) produces the same clean result both times.
