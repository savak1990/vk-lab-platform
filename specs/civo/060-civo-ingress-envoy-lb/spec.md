---
id: "CIVO-060"
title: "Civo ingress: Envoy Service LoadBalancer with Civo annotations and Gateway listeners 80/443"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Known annotations and Gateway API objects; verification against a real LB is the main work"
effort_estimate: "One session (3–5 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-045"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-060 — Civo ingress

## 1. Outcome and rationale

On Civo, Envoy Gateway's Service becomes a Civo load balancer on the
reserved IP, listening on 80 and 443, with the firewall from CIVO-030;
HTTP reaches Argo CD and Grafana routes (plain HTTP until CIVO-070). AWS
keeps its NLB configuration byte-for-byte.

## 2. Scope and non-goals

In scope: EnvoyProxy, Gateway, ClientTrafficPolicy made values-driven;
civo values; LB readiness gate in `argo-up`. Not in scope: TLS (CIVO-070),
DNS (CIVO-110), proxy protocol (CIVO-190).

## 3. Current state / evidence

- `gitops/templates/platform/aws/envoy-gateway/gateway.yaml:2-44` EnvoyProxy with six `service.beta.kubernetes.io/aws-load-balancer-*` annotations, `:61-80` Gateway single listener HTTP:443, `:84-97` ClientTrafficPolicy proxy protocol.
- Civo annotations: `kubernetes.civo.com/firewall-id`, `kubernetes.civo.com/ipv4-address` (reserved IP), `loadbalancer-algorithm`, `protocol` (research.md).
- `scripts/argo-up.sh:86-140` DNS wait reads the Service in namespace `envoy`.

## 4. Design and contracts

- Move `gateway.yaml` to `shared/envoy-gateway/gateway.yaml` with: `annotations: {{ toYaml .Values.envoyGateway.service.annotations }}`; listeners rendered from `.Values.envoyGateway.listeners` (aws default: one HTTP:443; civo: HTTP:80 and HTTPS:443 with `tls.mode: Terminate` and `certificateRefs` to a Secret name from values, added in CIVO-070); ClientTrafficPolicy rendered only when `.Values.envoyGateway.proxyProtocol` is true (aws true, civo false).
- Civo values: `envoyGateway.service.annotations: {kubernetes.civo.com/firewall-id: <from argo-up>, kubernetes.civo.com/ipv4-address: <reserved IP>, kubernetes.civo.com/loadbalancer-algorithm: round_robin}`; `envoyGateway.tls.mode: envoy`.
- `argo-up` civo: after root sync, wait until the Service has an ingress IP equal to the reserved IP (timeout 300 s), then run the DNS wait (records exist only after CIVO-110; until then the wait is skipped on civo with a log line).
- Golden AWS render must stay empty-diff.

## 5. Files/components affected

`gitops/templates/platform/shared/envoy-gateway/gateway.yaml` (moved + templated), `gitops/values.yaml`, `scripts/argo-up.sh` (LB wait), `tests/golden/gitops-aws` unchanged.

## 6. Implementation steps

1. Template the three objects; run `make gitops-check` (aws empty diff).
2. Add civo values; render and `kubeconform`.
3. `PROVIDER=civo make up`; `curl -H 'Host: argo.civo.<root-domain>' http://<reserved-ip>/` returns Argo CD's redirect/login page.
4. Port scan: only 80/443 open on the reserved IP.
5. `argo-down`: Civo LB deleted before the cascade; `civo loadbalancer ls` empty.

## 7. Dependencies and blockers

CIVO-045 for the civo argo path; reserved IP and firewall from CIVO-025/030 via SSM.

## 8. Acceptance criteria

- Service `status.loadBalancer.ingress[0].ip` equals the reserved IP.
- HTTP on 80 routes by Host header to Argo CD and Grafana backends (Grafana only if observability is present; otherwise 404 from Envoy is acceptable and recorded).
- LB removed on `argo-down`; reserved IP remains in the account.
- AWS golden diff empty; AWS Argo `app diff` empty.

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: civo up/down (~0.2 USD incl. LB minutes).

## 10. AWS regression protection

Golden render diff; post-merge `argocd app diff root` on AWS empty; NLB annotations unchanged.

## 11. Rollout and rollback/recovery

Revert; Argo reconciles. No data risk.

## 12. Risks and unresolved questions

- Reserved IP annotation key differs across docs (`kubernetes.civo.com/ipv4-address` vs `civo.com/reserved-ip`); CCM README is authoritative; confirm in spike.

## 13. Definition of done

- [ ] Evidence for both providers
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
