---
id: "LOCAL-022"
status: "IN_PROGRESS"
updated: "2026-09-22"
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
   MUST use kind's default StorageClass, referenced by name (`standard`) and
   never defined by a template this repository owns. `platform.storageClassName`
   MUST carry a `local` arm rather than falling through to
   `.Values.storage.className`: that fall-through is `else`, not `eq "aws"`, so
   without an arm the target silently inherits the AWS-only class and every
   claim stays Pending. Reclaim semantics MUST be `Delete` — the
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
10. The `local` target's `HTTPRoute`s MUST match by **path** (`/` for Argo CD,
    `/grafana`) and MUST omit `hostnames` entirely. Every other target MUST
    continue matching by hostname. This is a permanent, accepted divergence in
    route-matching *kind*: a forward to `localhost:PORT` cannot present the
    Host header hostname matching needs.

    A `URLRewrite` filter stripping the prefix MUST NOT be used. Instead, a
    component that can serve itself from a subpath gets its own prefix and
    receives it unrewritten. A component that cannot MUST take the root prefix
    rather than be forced under one.

    **Grafana, as implemented.** `grafana.ini`'s `server.root_url` and
    `server.serve_from_sub_path`, set in the chart's values rather than through
    the equivalent `GF_SERVER_ROOT_URL` environment variable, because every
    other Grafana setting is already expressed there. `root_url` MUST name the
    same prefix the route matches, and the port the bring-up banner tells the
    operator to forward — the two are one setting split across two files, and
    the render check pins both ends so they cannot drift apart.

    `serve_from_sub_path` moves **every** path, not only the UI. Grafana's
    `ServiceMonitor` path and its readiness probe MUST be moved under the
    prefix with it. Left alone, both receive a 301 to an absolute URL naming
    the operator's forwarded port: Prometheus reports the Grafana target
    `down`, and the probe passes on the redirect without ever reaching the
    health endpoint, which makes it vacuous rather than merely misrouted.
    Both were observed on a live kind cluster.

    **Argo CD takes the root prefix.** `server.rootpath` moves its API and its
    redirects, but the UI keeps `<base href="/">`, so every relative asset
    resolves to the root and returns 404; `server.basehref` does not change
    that tag either. Both were measured on a live cluster against chart
    10.4.0 before this requirement was settled. Since there is exactly one
    gateway on this target and no hostname matching, giving Argo CD `/` costs
    nothing: Gateway API matches a longer prefix first, so every other
    component still reaches its own.

    (Amended 2026-09-21. As first written this requirement mandated the
    `URLRewrite` filter; the first amendment replaced it with `rootpath`,
    which the live test then disproved. Amended again 2026-09-22: the path
    list said `/argocd` while the paragraph below it, added by the same
    amendment, gives Argo CD the root — and the acceptance criterion said
    `/argo`. Three spellings, one implementation. The list now matches it.)
11. The `local` target MUST use plain HTTP. No cert-manager issuer and no TLS
    termination at Envoy MUST be configured for it.
12. Bring-up MUST create the Kubernetes `Secret` objects the platform needs
    with generated, throwaway values, in the same untracked bootstrap class as
    the Civo CA secret. It MUST require no credential of any kind.
13. The `local` path MUST make no AWS API call. It MUST NOT read SSM Parameter
    Store, assume a role, use EKS Pod Identity or IAM Roles Anywhere, or
    decrypt a committed ciphertext through KMS. ADR 0006's opt-in KMS path is
    withdrawn (ADR 0038).
14. The root Application MUST reconcile `gitops/` edits from the working tree,
    with no commit and no push, via `argocd app sync root --local gitops`
    (ADR 0038 as amended). Its `syncPolicy.automated` MUST be omitted for this
    target only — Argo refuses a local sync while automated sync is enabled —
    and bring-up MUST perform the sync itself, since nothing else will. A
    previous failed sync leaves an operation `Running` and the next sync is
    rejected outright, so bring-up MUST clear a stale operation first.
15. Observability and Postgres MUST carry an explicit laptop-scale posture for
    this target — replica counts, resource requests, retention windows — stated
    in `gitops/values.yaml` or in the bring-up script's overrides. Any
    component omitted for `local` MUST be named explicitly in this spec or in
    the values file's comments, never silently dropped.

    **Postgres, as implemented.** One instance, `250m` CPU and `256Mi` memory
    requested and no limits — the same numbers every other target uses, which
    are already laptop-scale. Only the volume differs: `argo-up` defaults
    `POSTGRES_STORAGE_SIZE` to `5Gi` here against `20Gi` elsewhere, because
    kind's provisioner carves it out of the workstation's own disk. No values
    key expresses the instance count or the requests, and none is added: a key
    whose value never differs is configuration for nothing.

    `enablePDB: false` MUST reach this target. CloudNativePG creates a
    PodDisruptionBudget even for a single instance, and that budget blocks a
    node from ever draining.

    **Observability, as implemented.** Retention windows and volume sizes live
    in `gitops/values.yaml` under `observability.profile`, which has a
    `default` arm and a `local` arm selected by target. `local` holds **6h**
    of Prometheus series on a **1Gi** claim and **6h** of Loki logs on another
    **1Gi** claim — 2Gi in total. The cluster is deleted whole at the end of a
    session, so a longer window costs disk and buys nothing.

    Prometheus's `retentionSize` MUST stay below its claim, so the head block
    and the write-ahead log still fit. It is also the bound that actually
    holds: `standard` is backed by `rancher.io/local-path`, which hands out a
    directory on the node and enforces no size at all, so the claim is nominal
    and the retention settings are not.

    Loki's `reject_old_samples_max_age` MUST NOT follow `retention_period`
    down. It bounds how stale an *arriving* line may be, not how long a stored
    one is kept; at 6h a suspended workstation or a pod whose logs backfill
    after a restart would have real logs rejected.

    **Resource requests are deliberately not target-varied.** They were
    measured on live clusters, and the comments recording those measurements
    say so. A request set below real usage hides the footprint from the
    scheduler and buys eviction, not headroom. Any change here MUST come from
    a measurement on kind, not from halving a cloud number.

    **Omitted for `local`, named here as this requirement demands:**
    Alertmanager (`alertmanager.enabled: false` — nothing pages anyone from a
    laptop; the `PrometheusRule` still evaluates and a firing alert still
    shows in Prometheus's own UI); the Grafana `ExternalSecret` and the
    `ClusterSecretStore` behind it (Requirement 12 creates the credential
    instead); `grafana-traffic-policy`, the Envoy rate limit and retry budget
    for the Grafana route (rate-limiting a single operator against their own
    workstation buys nothing). Tempo and the OpenTelemetry Collector are absent
    on every target, not only this one.

    The `observability` `RoleBinding` for the E2E suite was omitted here until
    2026-09-22, when the suite gained a kind environment. It now renders on
    every target, and this target alone adds one in `envoy`: it is the only one
    that reaches the gateway through a port-forward, and `pods/portforward` is
    granted per namespace.
16. Fast validation (spec 019) MUST render the chart for `target=local`, and
    the structural contract in `scripts/gitops-render-check.sh` MUST be updated
    in the same change as any render change. That contract is what makes a
    silent regression fail.
17. The `aws` golden render MUST stay byte-identical throughout. That diff is
    the regression guard for the three real targets.

    One narrow exception, added rather than taken silently: a **comment inside
    a rendered manifest** that a change makes factually false MUST be removed,
    even though that moves the baseline. Such a diff MUST be comment-line
    deletions only, and the commit that makes it MUST say so. No object, field
    or value may move under this exception. (Added 2026-09-22, when un-gating
    the Grafana route falsified a comment reading "Stays gated".)

## Implementation hints

- Express differences through `_helpers.tpl` functions and `gitops/values.yaml`
  first, and add a `target` branch only where the structure genuinely differs.
  `platform.storageClassName` already shows the shape: civo and hetzner name
  their provider's class, everything else falls through to the values file.
- kind's default StorageClass is `standard`, backed by
  `rancher.io/local-path`, with `reclaimPolicy: Delete` and
  `volumeBindingMode: WaitForFirstConsumer` already — measured on kind 0.33.0,
  node image v1.37.0. Requirement 7 needs no reclaim-policy override, only the
  name.
- ~~`platform.metricsServerEnabled` needs a local arm.~~ It does not: the
  helper's fall-through reads `observability.metricsServer.enabled`, which is
  already `true`, and `platform.kubeletInsecureTls` falls through to `true` as
  well, which is what kind's self-signed kubelet certificates need. Verified by
  render before any arm was written. Unlike `platform.storageClassName`, whose
  identical-looking fall-through was wrong, this one reaches the right value.
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
- Editing a file under `gitops/` and re-running `PROVIDER=local make argo-up`
  reconciles that change into the cluster **without a commit or a push**,
  proving Requirement 14. Re-running on an already-healthy cluster must not
  take the idempotency fast path: that re-sync is the loop.
- `kubectl port-forward` to Envoy Gateway's Service, followed by plain-HTTP
  requests to `/` (Argo CD) and `/grafana` on that port, succeeds — and
  Grafana's own assets load, not only its root document.
- `PROVIDER=local make down` leaves no kind cluster behind, proving
  Requirement 7.
- Pointing the isolated kubeconfig at a non-local cluster and running a local
  lifecycle command fails with an explicit refusal, proving Requirement 4.
- A passing `local` run is explicitly not accepted as satisfying constitution
  §11's full lifecycle test or §12's Definition of Done for any real target.
