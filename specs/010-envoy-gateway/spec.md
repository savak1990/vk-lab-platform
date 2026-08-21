# 010 — Envoy Gateway

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
- Gateway-level telemetry wired into the observability stack from spec 009.

Excludes: the AWS-side NLB and TLS termination (011 — this spec is Kubernetes-internal Gateway API routing only; the `aws`-target annotation values that turn this spec's `EnvoyProxy`-generated `Service` into an NLB with an ACM TLS listener — target-type, ACM ARN, proxy protocol — are owned by spec 011, not this spec, even though they land on an object this spec defines the shape of), any application routing (no application code in this repo).

Requirements 5 and 6 below apply to the `local` target (spec 021) and are genuine divergences in kind from the `aws`-target hostname-routing/`LoadBalancer`-Service assumptions elsewhere in this spec, not values-only tuning.

## Requirements

1. Envoy Gateway owns Gateway API routing, rate limiting, retries, timeouts, headers/policies, and gateway telemetry (architecture.md §10) — it does not own AWS ingress or TLS termination at the AWS layer (that's the NLB's job, spec 011). This requirement describes the `aws` target; spec 011 (NLB/TLS) does not apply to `local` at all.
2. Routing logic MUST NOT be duplicated between the NLB and Envoy (constitution §8) — keep all host/path routing decisions in Envoy's `HTTPRoute` resources; the NLB performs no host/path routing at all, only AWS-level ingress, health checks, and TLS termination. `aws` target only — `local` has no NLB.
3. Envoy Gateway is Argo-managed (constitution §2). Applies to both targets.
4. Gateway telemetry MUST feed into the observability stack from spec 009 (constitution §10's "new major components should provide metrics/logs/health info"). Applies to both targets.
5. For the `local` target, `values-local.yaml` MUST force Envoy Gateway's Service type to `ClusterIP` (via `EnvoyProxy`/`GatewayClass` parameters) — the upstream default (`LoadBalancer`) hangs `<pending>` indefinitely on kind/minikube (spec 021 Requirement 8).
6. For the `local` target, `HTTPRoute`s MUST match by path (`/api`, `/grafana`, `/argocd`) rather than by hostname, since `kubectl port-forward` to `localhost` cannot present a matching Host header. The `aws` target MUST keep matching by hostname (the hostname-based implementation hint below is `aws`-only). This is a permanent, accepted divergence in route-matching kind (spec 021 Requirement 9), not a values-only difference.
7. The `Gateway` listener MUST be `protocol: HTTP` with no `tls` block, on both targets — TLS terminates at the NLB (spec 011) on `aws`, and `local` never had TLS. Envoy Gateway never holds a certificate.
8. The `aws`-target `EnvoyProxy` resource (`gitops/platform/aws/`-layered values) is where spec 011 injects its NLB-specific `Service` annotations (`aws-load-balancer-type`, `aws-load-balancer-nlb-target-type`, `aws-load-balancer-ssl-cert`, `aws-load-balancer-ssl-ports`, `aws-load-balancer-proxy-protocol`) via `EnvoyProxy.spec.provider.kubernetes.envoyService.annotations`. This spec owns the `EnvoyProxy` resource's existence and shape (including Requirement 7's HTTP-only listener); spec 011 owns only the `aws`-target annotation *values* inside it, supplied through `values-aws.yaml` — the same generated object, explicit split of who owns which field on it.

## Implementation hints

- Route Grafana and Argo CD's own web UI through Envoy now — this gives the Gateway API config something real to route to before the NLB (spec 011) exists, and doubles as an early integration test of the whole `client → Envoy → service` path (minus the AWS-level NLB fronting it, added next).
- `HTTPRoute` hostnames should match the delegated subdomain from spec 002/ADR 0002 — e.g. `grafana.lab.<root-domain>` and `argocd.lab.<root-domain>` — even though the NLB/DNS record making them publicly resolvable doesn't exist until spec 011/012; internal/port-forwarded testing can use these same hostnames via `Host` headers ahead of that.
- Keep rate-limit/retry/timeout policies conservative and documented — this is a lab, not a production system, but the policies still need to exist to exercise the feature per architecture.md's goals.
- Structure `HTTPRoute` resources per-service under `gitops/platform` or `gitops/workloads` (per the repo layout) so adding a route for a future integration test workload doesn't require touching unrelated routes.

## Testing / acceptance criteria

- `kubectl port-forward` or an internal cluster request routed through Envoy successfully reaches Grafana and Argo CD's UI according to the configured `HTTPRoute` host/path rules.
- A deliberately triggered rate-limit or timeout policy behaves as configured (e.g., a burst of requests gets throttled, a slow backend times out per the configured threshold).
- Gateway metrics appear in the Prometheus/Grafana stack from spec 009.
- Fast validation (Helm/manifest rendering, Gateway API schema validation, k8s schema); no persistence proof needed (Envoy Gateway holds no data).
