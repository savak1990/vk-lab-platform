# 004 — Argo CD Bootstrap

**Complexity:** Medium
**Risk:** Medium — the Terraform itself is simple, but this is the single most-cited failure mode in ADR 0001 (Terraform/Argo CD ownership overlap). Worth a deliberate review pass even though the code is small.
**Estimated cost:** ~0.5–1 day · AWS runtime cost: none beyond the EKS cluster already running.
**Recommended model:** Sonnet, with an Opus review pass focused specifically on the ownership boundary.
**Depends on:** 003-network-and-eks (a cluster to install into)
**Lifecycle class(es) touched:** Disposable

## Scope

Terraform installs Argo CD onto the cluster and creates exactly one root ("app-of-apps") Application pointing at `gitops/`. After that, Terraform's job here is done — everything else in Kubernetes is Argo CD's responsibility.

Excludes: any Argo `Application`/`ApplicationSet` beyond the single root one (those live in `gitops/` and are reconciled by Argo itself), Karpenter/AWS LB Controller/Envoy/etc. installation (those are Argo-managed from here on).

## Requirements

1. Terraform MUST install Argo CD and the root Application, and MUST NOT manage any other Kubernetes resource — this is the exact boundary constitution §2 and architecture.md §7 draw, and the exact mistake ADR 0001 flags from `bg-tf-app` (Argo CD Helm release applied directly alongside application resources from Terraform, blurring ownership).
2. The root Application MUST point at the `gitops/` directory in this repo and use Argo's own reconciliation (sync waves, app-of-apps) for everything beneath it — no imperative post-install scripting of Kubernetes resources from Terraform or CI.
3. Once the root Application exists, any further change to what's installed on the cluster MUST go through Git + Argo sync, not through a second Terraform apply touching Kubernetes objects.
4. Manual `kubectl` changes to anything Argo manages are drift, not state — the same rule Argo will enforce on every later spec starts here (constitution §6).

## Implementation hints

- Terraform installs Argo CD via its official Helm chart (or raw manifests) — pin a version, don't track `latest`.
- The root `Application` resource is genuinely the only "app" Terraform creates; its `spec.source.path` points at `gitops/` (or a `gitops/bootstrap` entry point per the repo layout in architecture.md §5), and its `spec.source.repoURL` points at this repo.
- Decide now whether Argo CD's own config (RBAC, SSO if any, resource exclusions) lives in the Terraform-applied Helm values or is handed off to Argo-managed config immediately after bootstrap — leaning toward the latter keeps the Terraform footprint minimal and matches the "Terraform bootstraps, then gets out of the way" principle.
- `gitops/bootstrap/` (per the repo structure) is a reasonable place for the root Application's own target, if the app-of-apps pattern needs a stable entry point independent of `gitops/platform`, `gitops/data`, `gitops/workloads` reorganizing later.

## Testing / acceptance criteria

- After `terraform apply`, Argo CD is reachable (port-forward or later via the real ALB/Envoy path from spec 012) and shows the root Application as `Synced`/`Healthy` even with an empty or near-empty `gitops/` tree.
- Adding a trivial manifest under `gitops/` and pushing it causes Argo to reconcile it without any further Terraform involvement — this is the acceptance test that proves the boundary holds.
- `terraform plan` on the disposable stack after an Argo-driven change shows zero drift — confirms Terraform truly stopped managing Kubernetes resources after bootstrap.
- Fast validation (Terraform validate/plan, Argo manifest validation on whatever's in `gitops/`) — no full lifecycle test needed yet since there's no stateful data at this point.
