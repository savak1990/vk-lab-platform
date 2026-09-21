---
id: "LOCAL-022"
status: "IN_PROGRESS"
updated: "2026-09-21"
---
# 022 — Local Development Mode (kind)

**Complexity:** Medium — no single hard problem, but many small divergences
(install path, routing kind, secrets, storage, sizing) that must all cohere,
across a chart four targets share.
**Risk:** Medium — the risk is not a broken kind cluster, it is the `aws`,
`civo` or `hetzner` targets regressing while this is un-gated. The golden
render diff is the guard.
**Estimated cost:** ~2 days · Cloud runtime cost: none. This target makes no
cloud API call of any kind.
**Recommended model:** Sonnet.
**Depends on:** 000-constitution (§18), ADR 0038, CIVO-050 (the umbrella-chart
structure this builds on).
**Lifecycle class(es) touched:** none. The `local` target sits outside the
State/Bootstrap/Persistent/Disposable model (constitution §18, §3).

## Scope

This spec defines the **`local` execution target**: running the platform's
`gitops/` content on kind, with no AWS API call anywhere in the path. It shares
the single umbrella chart every other target uses, selected by
`.Values.target`.

ADR 0038 supersedes ADR 0006 and rewrites this spec's premise. ADR 0006 was
written before `gitops/` existed and framed this work as a constraint on specs
004–013. Those specs are implemented. CIVO-050 then built the chart with one
umbrella chart and per-file `{{- if eq .Values.target "x" }}` gates rather than
the per-component `values-aws.yaml` / `values-local.yaml` layout ADR 0006
specified. So the work here is **un-gating and supplying values**, not
constraining anything.

`local` is already a valid `.Values.target`, guarded by eighteen
`{{- if ne .Values.target "local" }}` exclusions. That render is a skeleton
with no Postgres, no Gateway, no observability and no External Secrets — and it
emits an `HTTPRoute/argocd` whose `parentRefs` name a Gateway the same render
excludes. Fixing that dangling route is the first change, not the last.

Excludes: minikube (ADR 0038 alternative c); any attempt to make the local
cluster or its data survive deletion (Requirement 7 — it is deliberately
throwaway); any AWS-equivalent public edge (Requirement 8); any AWS API call at
all, including the KMS decrypt ADR 0006 allowed as an opt-in (ADR 0038); CI
integration, which is spec 024's job.

## Requirements

1. The `local` target MUST be selected by `PROVIDER=local` and MUST use the
   lifecycle commands every other target uses — `make up`, `make down`,
   `make full-up`, `make full-down`. It MUST NOT add a lifecycle command of its
   own. There MUST be no `make kind-up`, no `make minikube-up`, and no
   `make local-up`.
2. `make bootstrap-up`/`-down` and `make persistent-up`/`-down` MUST be no-ops
   for this target that report why and exit 0, since it owns no cloud resource.
   `make full-up` MUST therefore reduce to creating the cluster and installing
   Argo CD.
3. `make cluster-up` MUST create the kind cluster and `make cluster-down` MUST
   delete it. `cluster-down` MUST NOT require `CONFIRM_DESTROY`: kind deletes
   only kind clusters, and this target's data is throwaway by design.
4. Every lifecycle command that runs `kubectl` against this target MUST first
   assert that the active context's API server is on this machine, and MUST
   refuse otherwise. The cluster name comes from the environment, so without
   this a stale kubeconfig could point a local run at a real cluster. This is
   in addition to `use_isolated_kubeconfig` (ADR 0034), not instead of it.
5. The `local` target MUST render from the same umbrella chart as every other
   target, gated per file on `.Values.target`. Per-component
   `values-<target>.yaml` files MUST NOT be introduced, and Kustomize MUST NOT
   be introduced as a second overlay mechanism.
6. Karpenter, AWS Load Balancer Controller, ExternalDNS, the EBS CSI driver,
   External Secrets' `ClusterSecretStore` and every `ExternalSecret`, and the
   barman-cloud backup objects MUST NOT appear in the `local` render under any
   circumstance. They MUST be omitted by templating, never installed and then
   disabled.
7. Local Postgres data MUST be fully throwaway: no persistent-lifecycle class,
   no destroy/recreate persistence proof, no object-store backup. The cluster
   MUST use kind's default StorageClass, referenced by name and never defined
   by a template this repository owns. Reclaim semantics MUST be `Delete` — the
   deliberate inverse of spec 005's `aws`-target `Retain` requirement.
8. No cloud load balancer, DNS zone or certificate MUST be used for this
   target. Access MUST be via `kubectl port-forward` to Envoy Gateway's
   Service.
9. The chart MUST force Envoy Gateway's Service type to `ClusterIP` for this
   target, through the `EnvoyProxy` the `GatewayClass` references. Envoy
   Gateway's own default (`LoadBalancer`) MUST NOT be relied on — it hangs
   `<pending>` indefinitely on kind, which has no cloud load-balancer
   implementation, and no MetalLB or `cloud-provider-kind` substitute is used
   (ADR 0006 alternative d, carried forward by ADR 0038).
10. The `local` target's `HTTPRoute`s MUST match by **path** (`/argo`,
    `/grafana`). Every other target MUST continue matching by hostname. This is
    a permanent, accepted divergence in route-matching *kind*: a forward to
    `localhost:PORT` cannot present the Host header hostname matching needs.
    Each local route MUST carry a `URLRewrite` filter replacing the prefix with
    `/`, or the backend receives the prefix and returns 404.
11. The `local` target MUST use plain HTTP. No cert-manager issuer and no TLS
    termination at Envoy MUST be configured for it.
12. Bring-up MUST create the Kubernetes `Secret` objects the platform needs
    with generated, throwaway values, in the same untracked bootstrap class as
    the Civo CA secret. It MUST require no credential of any kind.
13. The `local` path MUST make no AWS API call. It MUST NOT read SSM Parameter
    Store, assume a role, use EKS Pod Identity or IAM Roles Anywhere, or
    decrypt a committed ciphertext through KMS. ADR 0006's opt-in KMS path is
    withdrawn (ADR 0038).
14. The root Application MUST sync from a git ref, naming the current branch or
    commit, exactly as every other target does. ADR 0006's working-directory
    sync is withdrawn (ADR 0038).
15. Observability and Postgres MUST carry an explicit laptop-scale posture for
    this target — replica counts, resource requests, retention windows — stated
    in `gitops/values.yaml` or in the bring-up script's overrides. Any
    component omitted for `local` MUST be named explicitly in this spec or in
    the values file's comments, never silently dropped.
16. Fast validation (spec 019) MUST render the chart for `target=local`, and
    the structural contract in `scripts/gitops-render-check.sh` MUST be updated
    in the same change as any render change. That contract is what makes a
    silent regression fail.
17. The `aws` golden render MUST stay byte-identical throughout. That diff is
    the regression guard for the three real targets.

## Implementation hints

- Express differences through `_helpers.tpl` functions and `gitops/values.yaml`
  first, and add a `target` branch only where the structure genuinely differs.
  `platform.storageClassName` already shows the shape: civo and hetzner name
  their provider's class, everything else falls through to the values file.
- `platform.metricsServerEnabled` needs a local arm — kind ships no
  metrics-server, so the observability stack's own must be enabled.
- `gateway.yaml` is today a single `if aws … else if civo` chain that
  duplicates the `EnvoyProxy` and `Gateway` wholesale. Adding a third copy is
  the wrong move; factor the shared parts before adding the local arm.
- `barman-plugin-application.yaml` indexes
  `.Values.postgres.backup.sidecarImages` by target name. Keeping
  `postgres.backup.enabled=false` for local avoids a nil dereference there;
  keep its `ne local` guard as well rather than relying on one of the two.
- `gitops/bootstrap/values.yaml` has drifted from `gitops/values.yaml` on
  `postgres.storageSize` (10Gi versus 20Gi). Fix that while in the area.

## Testing / acceptance criteria

- `make gitops-check` passes, with the `local` render producing the expected
  object set and the `aws` golden diff unchanged.
- `PROVIDER=local make up` succeeds on a workstation with **no AWS credentials
  in the environment**, and the root Application reaches `Synced/Healthy`. This
  is the real test of Requirement 13; a run with ambient credentials present
  proves nothing.
- `kubectl port-forward` to Envoy Gateway's Service, followed by plain-HTTP
  requests to `/argo` and `/grafana` on that port, succeeds.
- `PROVIDER=local make down` leaves no kind cluster behind, proving
  Requirement 7.
- Pointing the isolated kubeconfig at a non-local cluster and running a local
  lifecycle command fails with an explicit refusal, proving Requirement 4.
- A passing `local` run is explicitly not accepted as satisfying constitution
  §11's full lifecycle test or §12's Definition of Done for any real target.
