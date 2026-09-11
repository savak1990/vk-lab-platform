# ADR 0025: Retry failed Argo syncs rather than gate every cross-Application dependency

## Status

Accepted

## Context

A single `make up` on 2026-09-06 produced a cluster that needed three manual
interventions before it worked, and left a fourth failure undetected for another
twenty minutes. All four are the same failure:

> A resource owned by the `root` Application depends on something a *sibling*
> Application provides. `root`'s sync reaches that resource first. The whole sync
> operation fails atomically. Nothing ever retries it.

| # | `root` resource | Depends on | Symptom |
|---|---|---|---|
| 1 | `envoy-gateway-webhook-probe` Job (wave -2) | `aws-load-balancer-controller`'s webhook serving cert | probe exhausted its 150s budget ~90s before the cert became valid |
| 2 | `GatewayClass`, `Gateway`, `EnvoyProxy`, `ClientTrafficPolicy` (wave 0) | Gateway API CRDs from the `envoy-gateway` chart | `no matches for kind "GatewayClass" ... ensure CRDs are installed first` |
| 3 | the NLB `Service` envoy-gateway's controller creates | the same LBC webhook cert | `x509: certificate signed by unknown authority`; the controller logged `failed to create new infra` and never retried |
| 4 | 5 `ServiceMonitor`/`PodMonitor`, 2 dashboard ConfigMaps, `PrometheusRule`, `RoleBinding` (wave 2) | `kube-prometheus-stack`'s CRDs and its `observability` namespace | `no matches for kind "ServiceMonitor"`, `namespaces "observability" not found` |

Instances 2 and 4 are exactly what `CLAUDE.md`'s Argo CD conventions section already
warned about: sync waves order when `root` *creates* each child Application object,
not when that child's controller becomes ready. The prescribed remedy there was a
`PreSync` hook waiting on the concrete dependency. Instance 1 *is* that remedy,
built for instance 3 — and it is the thing that broke first.

Four facts from the incident decide the design.

**A failed automated sync is terminal.** `root`'s `syncPolicy` declared
`automated: {prune, selfHeal}` and no `retry`. `selfHeal` re-syncs drift; it does
not re-attempt a sync operation that *failed* on the same revision. `root` sat
`OutOfSync` with `operationState.phase=Failed` for over six minutes with
`reconciledAt` still advancing, and would have stayed there until a new commit
landed. Every manual intervention in the incident was a human supplying the retry
Argo was not configured to perform.

**A gate cannot make a distributed convergence deterministic.** The probe *passed*,
in three seconds, and instance 3 still hit the same x509 error minutes later.

**The dependency kinds differ.** Instances 2, 3 and 4 span CRDs, a webhook cert and
a namespace. A gate per dependency is one new bespoke component per failure — each
of which can itself time out, as instance 1 did.

**`no matches for kind` outlives the missing CRD.** The `ServiceMonitor` CRD was
created at 17:08:21; retried syncs still failed with `no matches for kind` until
17:09:50. Argo maintains its own cluster API-discovery cache, refreshed on a watch
resync (~10 min by default in gitops-engine, and not exposed as a flag on
`argocd-application-controller` v3.5.1). Any retry budget must outlast that
refresh, not merely the CRD's creation. Argo's default backoff (5s, factor 2) burns
five attempts in about 2.5 minutes and is therefore useless here.

`SkipDryRunOnMissingResource=true` is not a partial remedy. All four resources in
instance 2 already carried it. It skips the server dry-run; the real apply still
fails.

## Decision

**`syncPolicy.retry` on the `root` Application is the primary mechanism for
cross-Application ordering failures.** Readiness gates are the exception, used only
where retry provably cannot help.

1. `root` declares an explicit retry budget sized against Argo's API-discovery
   cache refresh, not against CRD creation:

   ```yaml
   retry:
     limit: 10
     backoff: { duration: 15s, factor: 2, maxDuration: 2m }
   ```

   Worst case ≈ 15.75 min of backoff plus per-attempt sync time. `argo-up.sh`'s
   watch ceiling rises from 1800s to 2700s to contain it.

2. Retry is declared on `root` only. All four raced resources are `root`'s own; the
   child Applications install self-contained upstream charts. Adding retry to all
   thirteen would be noise, not defence.

3. **The webhook probe is retained, for instance 3 alone.** Retry re-runs a failed
   *sync*; it cannot restore a consumer controller that wedged after one failed
   attempt and requires a pod restart. That is the only class a gate still earns.
   Its in-pod budget rises from 150s to 480s, past the ~5.5 min the LBC took to
   generate its cert, and its `hook-delete-policy` becomes
   `BeforeHookCreation,HookSucceeded` — a *failed* Job persists, Job specs are
   immutable, and without this a retried sync recreates it into `AlreadyExists`,
   making retry spin without ever re-running the probe.

   *Amended 2026-09-06: `HookSucceeded` is dropped; `BeforeHookCreation` alone
   satisfies the `AlreadyExists` reasoning above and is Argo's default.
   `HookSucceeded` deletes the hook when the sync completes rather than when the
   hook does, so a teardown deleting the Application mid-sync races that cleanup.
   A hook left holding `argocd.argoproj.io/hook-finalizer` is unreapable and pins
   the sync operation open, which blocks every deletion finalizer including the
   root Application's — see ADR 0012 for the teardown precondition this created.*

4. **`argo-up.sh` fails fast on an exhausted retry budget.** It previously polled
   only `sync.status`/`health.status` and would have burned its full watch on a
   dead sync. It now also reads `operationState.phase`; a `Failed`/`Error` phase
   whose `startedAt` differs from the one captured before this run means the budget
   is spent, and the script exits with Argo's own message. Phase stays `Running`
   for the duration of the retry sequence, so this cannot fire early.

5. **A Lua health check for `gateway.networking.k8s.io/Gateway`.** Argo CD 3.5.1
   ships no health check for Gateway API — every such resource in `root`'s tree
   reports no health at all, so a Gateway with `Programmed: False` and no load
   balancer behind it still rolled up as Healthy. Delivered through a values file
   for Argo CD's own release rather than `--set`, since the key carries a
   multi-line Lua body.

6. **A wave must never contain a resource whose health depends on a later wave.**
   *Amended 2026-09-11, from a Civo cold-bootstrap deadlock.* Retry only fires when
   the whole operation terminates, and gitops-engine never re-applies a task that
   already holds a `SyncFailed` result while the operation is still `Running`: the
   result is persisted in `status.operationState.syncResult` and merely re-printed on
   every resume, so it survives controller restarts. A wave therefore has to settle
   — every resource in it Healthy, Failed or without a health check — before a
   raced failure in that wave can ever be retried.

   On Civo, `ClusterSecretStore`/`ExternalSecret` sat in wave 0 while the Roles
   Anywhere `Certificate` that lets ESO's pod start sat in wave 1 (ADR 0029). Argo
   ships built-in health checks for both ESO kinds, so wave 0 could never settle,
   the `GatewayClass`/`Gateway`/`EnvoyProxy` failures from instance 2 above were
   never retried, and `root` stayed `Running` indefinitely — 40 minutes, restart-
   immune. On AWS the same race self-heals in ~11 minutes only because ESO uses
   Pod Identity and wave 0 settles.

   Waves are the same for a component on both targets. `ClusterSecretStore` and
   `ExternalSecret` move to wave 2, strictly after the identity Certificates;
   `Cluster/lab-postgres` moves to wave 3 so ESO's pinned password Secret still
   exists before CNPG bootstraps (CNPG otherwise generates its own); the public
   TLS `Certificate` (CIVO-070, switched to DNS-01 by CIVO-075) lands at wave 2 —
   DNS-01 only needs the wave-0 Gateway and the wave-1 identity Certificates, not
   the application HTTPRoutes HTTP-01 used to depend on. `argo-up.sh`'s watch
   ceiling is 2700s on both targets.

## Consequences

A cross-Application race now costs minutes of retry instead of a broken cluster and
manual repair. `make argo-up` takes longer in the bad case; that is the mechanism
working, not a regression.

The `CLAUDE.md` Argo CD conventions section is amended: sync-level retry is the
default remedy for a cross-Application CRD, namespace or Secret dependency, and a
hook is reserved for a consumer controller that wedges permanently.

Retry only ever re-attempts the same revision. If a budget still exhausts on a cold
cluster, `root` ends `Failed` and stays there until a new commit lands. Decision 4
makes that loud rather than silent, and `operationState.retryCount` after a cold
cycle is the evidence that says whether the budget holds — a count near the limit
means it is marginal and must rise.

This is also the first ADR covering the webhook probe at all. It landed as a commit
titled `small fix` with no body, followed by four fix-forward commits, in a
repository where every other mechanism traces to a decision record. It is now
documented and scoped.

Nothing here changes AWS resources, cost, or lifecycle classes. The acceptance test
is a cold `make argo-down && make argo-up` reaching `Synced/Healthy` with no manual
intervention — manifest rendering and linting prove nothing about a race.
