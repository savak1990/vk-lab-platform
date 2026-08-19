# 011 — Envoy Gateway

**Complexity:** Medium
**Risk:** Low–Medium — standard Gateway API configuration surface, no persistent data involved.
**Estimated cost:** ~1 day · AWS runtime cost: incremental compute for the Envoy Gateway pods.
**Recommended model:** Sonnet — well-documented Gateway API patterns.
**Depends on:** 004-argocd-bootstrap (Argo-managed), 006-karpenter (compute)
**Lifecycle class(es) touched:** Disposable

## Scope

Deploys Envoy Gateway as the application-layer routing tier, per architecture.md §8/§10–12:

- Envoy Gateway controller + `GatewayClass`/`Gateway`/`HTTPRoute` (Gateway API) resources, Argo-managed.
- Rate limiting, retries, timeouts, header/policy configuration for whatever routes exist so far (initially just Grafana and Argo CD's own UI, as real integration test workloads — the platform has no application workloads to route to yet, and none belong in this repo per the constitution's repo-scope rule).
- Gateway-level telemetry wired into the observability stack from spec 010.

Excludes: the AWS-side ALB and DNS/TLS termination (012 — this spec is Kubernetes-internal Gateway API routing only), any application routing (no application code in this repo).

## Requirements

1. Envoy Gateway owns Gateway API routing, rate limiting, retries, timeouts, headers/policies, and gateway telemetry (architecture.md §10) — it does not own AWS ingress or TLS termination at the AWS layer (that's ALB's job, spec 012).
2. Routing logic MUST NOT be duplicated between ALB and Envoy (constitution §8) — keep host/path routing decisions in Envoy's `HTTPRoute` resources, and let ALB do only what it must (AWS-level ingress, health checks, TLS termination).
3. Envoy Gateway is Argo-managed (constitution §2).
4. Gateway telemetry MUST feed into the observability stack from spec 010 (constitution §10's "new major components should provide metrics/logs/health info").

## Implementation hints

- Route Grafana and Argo CD's own web UI through Envoy now — this gives the Gateway API config something real to route to before the ALB (spec 012) exists, and doubles as an early integration test of the whole `client → Envoy → service` path (minus the AWS-level ALB fronting it, added next).
- `HTTPRoute` hostnames should match the delegated subdomain from spec 002/ADR 0002 — e.g. `grafana.lab.<root-domain>` and `argocd.lab.<root-domain>` — even though the ALB/DNS record making them publicly resolvable doesn't exist until spec 012; internal/port-forwarded testing can use these same hostnames via `Host` headers ahead of that.
- Keep rate-limit/retry/timeout policies conservative and documented — this is a lab, not a production system, but the policies still need to exist to exercise the feature per architecture.md's goals.
- Structure `HTTPRoute` resources per-service under `gitops/platform` or `gitops/workloads` (per the repo layout) so adding a route for a future integration test workload doesn't require touching unrelated routes.

## Testing / acceptance criteria

- `kubectl port-forward` or an internal cluster request routed through Envoy successfully reaches Grafana and Argo CD's UI according to the configured `HTTPRoute` host/path rules.
- A deliberately triggered rate-limit or timeout policy behaves as configured (e.g., a burst of requests gets throttled, a slow backend times out per the configured threshold).
- Gateway metrics appear in the Prometheus/Grafana stack from spec 010.
- Fast validation (Helm/manifest rendering, Gateway API schema validation, k8s schema); no persistence proof needed (Envoy Gateway holds no data).
