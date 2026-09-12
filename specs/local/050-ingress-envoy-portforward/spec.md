---
id: "LOCAL-050"
title: "Envoy as ClusterIP reached by port-forward, HTTP only, *.localhost routes"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Two shared templates gain a third branch; the sectionName change touches every target and needs the golden diff"
effort_estimate: "One session (3–4 h)"
estimate_confidence: "high"
depends_on: ["LOCAL-030"]
blocked_by: []
supersedes: ["spec 022 Req 7, Req 9, Req 10"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-050 — Envoy as `ClusterIP` reached by port-forward, HTTP only, `*.localhost` routes

## 1. Outcome and rationale

The same `Gateway` and `HTTPRoute` objects the cloud targets use route
`argo.localhost` and `grafana.localhost` to Argo CD and Grafana on the
local cluster. Envoy's Service is plain `ClusterIP`; the platform reaches
it with `kubectl port-forward`, which works identically on minikube, kind,
k3d, and Docker Desktop and needs nothing from the cluster tool. No load
balancer, no NodePort, no DNS, no TLS.

## 2. Scope and non-goals

In scope:
- `gateway.yaml` local branch: `EnvoyProxy` with
  `provider.kubernetes.envoyService.type: ClusterIP`, no annotations;
  `Gateway/envoy` with one listener `http` on port 80.
- `httproutes.yaml`: remove the LOCAL-030 temporary gate; template
  `sectionName` as `{{ include "platform.publicListener" . }}` → `https`
  on aws/civo, `http` on local; extend the grafana route gate to
  `aws|local`.
- `argo-up.sh` local readiness: after root `Healthy`, open a temporary
  port-forward to the Envoy Service (random local port), poll
  `curl --resolve argo.localhost:<port>:127.0.0.1 http://argo.localhost:<port>/healthz`
  until 200 within `ARGO_UP_WATCH_SECONDS`, close the port-forward.
- `make local-forward` (local only): foreground
  `kubectl -n envoy-gateway-system port-forward svc/<envoy> ${LOCAL_HOST_PORT:-8080}:80`
  with the two URLs printed. A convenience, not a lifecycle command.
- Render-check: `GatewayClass`, `EnvoyProxy`, `Gateway`, both `HTTPRoute`s
  required for local; `LoadBalancer`/`NodePort` Services forbidden.

Not in scope:
- TLS of any kind.
- Rate-limit/timeout policies (aws-only).
- Proxy protocol.

## 3. Current state / evidence

- `gateway.yaml:1,18,100`: two provider branches, both `LoadBalancer`;
  `:74-82` aws listener (HTTP on 443); `:149-159` civo HTTPS listener.
- `httproutes.yaml:15,41` `sectionName: https`; `:19,43` hostnames
  `argo.{{ fqdn }}` / `grafana.{{ fqdn }}`; `:25` grafana route
  `eq target "aws"`.
- LOCAL-010 passes `envoyGateway.fqdn=localhost`.
- LOCAL-020 Q3 confirms port stripping from `:authority` through a
  port-forward.
- Envoy Gateway chart `v1.2.1` (`shared/envoy-gateway/application.yaml:16-19`).
- The Envoy Service name is generated (`envoy-<gateway-ns>-<gateway>-<hash>`);
  resolve it by label
  `gateway.envoyproxy.io/owning-gateway-name=envoy` rather than by name.

## 4. Design and contracts

Gateway listener: `name: http`, `port: 80`, `protocol: HTTP`, hostname
unset (routes carry hostnames). Routes unchanged in shape; only
`sectionName` and the grafana gate change.

Port-forward helper in `scripts/lib/provider.sh`:

```
local_envoy_service() {
  kubectl -n envoy-gateway-system get svc \
    -l gateway.envoyproxy.io/owning-gateway-name=envoy \
    -o jsonpath='{.items[0].metadata.name}'
}
```

Readiness in `argo-up`: start `kubectl port-forward` in the background on
`127.0.0.1:0`-style free port (read the bound port from its stdout),
`trap` it for cleanup, curl, kill. On timeout print
`kubectl -n envoy-gateway-system get svc,pods` as the diagnostic.

## 5. Files/components affected

`gitops/templates/_helpers.tpl` (`platform.publicListener`);
`gitops/templates/platform/shared/envoy-gateway/gateway.yaml`;
`gitops/templates/platform/shared/envoy-gateway/httproutes.yaml`;
`scripts/argo-up.sh`; `scripts/lib/provider.sh`; `Makefile`
(`local-forward`); `scripts/gitops-render-check.sh`.

## 6. Implementation steps

1. Helper and `sectionName` templating; grafana gate; remove the
   temporary file gate. `make gitops-check`: AWS golden diff empty (aws
   value is still `https`); civo diff empty.
2. Gateway/EnvoyProxy local branch; render-check lists.
3. `argo-up` readiness and `make local-forward`.
4. `PROVIDER=local make up`; readiness passes; `make local-forward`; open
   `http://argo.localhost:8080` in Chrome and log in with the admin
   password from `secrets/`.

## 7. Dependencies and blockers

LOCAL-030. LOCAL-020 Q3 result.

## 8. Acceptance criteria

- Local render: `Gateway/envoy` has exactly one listener `http`/80;
  `EnvoyProxy` is `ClusterIP`; both `HTTPRoute`s present with
  `sectionName: http`.
- AWS golden diff byte-identical; civo render diff empty.
- `argo-up` exits 0 only after `/healthz` returns 200 through its own
  port-forward.
- `make local-forward` prints the two URLs and Argo CD's login page loads
  in a browser.

## 9. Validation

Offline: `make gitops-check`. Workstation: one `up` and a browser check.

## 10. AWS regression protection

Golden diff — `sectionName` templating must produce `https` for aws
byte-for-byte.

## 11. Rollout and rollback/recovery

Revert.

## 12. Risks and unresolved questions

- `kubectl port-forward` drops when the Envoy pod restarts; `make
  local-forward` is a foreground command the developer re-runs. The e2e
  suite opens its own forward per run (LOCAL-080).
- Port 8080 in use: `LOCAL_HOST_PORT` overrides.

## 13. Definition of done

- [ ] Templates, readiness, and `local-forward` landed; render-check updated
- [ ] Golden/civo diffs empty; browser login recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `DRAFT` (blocked on LOCAL-030).
- 2026-09-11 — replanned: `ClusterIP` + port-forward instead of NodePort + kind port map.
