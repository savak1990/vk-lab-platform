---
id: "CIVO-060"
title: "Civo ingress: Envoy Service LoadBalancer with Civo annotations and Gateway listeners 80/443"
status: "DONE"
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
updated: "2026-09-09"
completed: "2026-09-09"
---

# CIVO-060 — Civo ingress

## 1. Outcome and rationale

On Civo, the Service of Envoy Gateway becomes a Civo load balancer on the
reserved IP. The load balancer listens on 80 and 443. It uses the firewall
from CIVO-030. HTTP traffic reaches the Argo CD and Grafana routes. The
traffic is plain HTTP until CIVO-070. AWS keeps its NLB configuration
byte-for-byte.

## 2. Scope and non-goals

In scope:

- The EnvoyProxy, Gateway, and ClientTrafficPolicy objects become values-driven.
- The civo values.
- A readiness gate for the load balancer in `argo-up`.

Not in scope:

- TLS (CIVO-070).
- DNS (CIVO-110).
- Proxy protocol (CIVO-190).

## 3. Current state / evidence

- `gitops/templates/platform/aws/envoy-gateway/gateway.yaml:2-44` contains the EnvoyProxy with six `service.beta.kubernetes.io/aws-load-balancer-*` annotations. Lines `:61-80` contain the Gateway with a single HTTP:443 listener. Lines `:84-97` contain the ClientTrafficPolicy for proxy protocol.
- The Civo annotations are `kubernetes.civo.com/firewall-id`, `kubernetes.civo.com/ipv4-address` (reserved IP), `loadbalancer-algorithm`, and `protocol` (research.md).
- `scripts/argo-up.sh:86-140` contains the DNS wait. The DNS wait reads the Service in namespace `envoy`.

## 4. Design and contracts

- Move `gateway.yaml` to `shared/envoy-gateway/gateway.yaml`. The template renders `annotations: {{ toYaml .Values.envoyGateway.service.annotations }}`. The template renders the listeners from `.Values.envoyGateway.listeners`. The aws default is one HTTP:443 listener. The civo listeners are HTTP:80 and HTTPS:443 with `tls.mode: Terminate` and `certificateRefs` to a Secret name from values. CIVO-070 adds the HTTPS:443 listener. The template renders the ClientTrafficPolicy only when `.Values.envoyGateway.proxyProtocol` is true. The value is true for aws and false for civo.
- The civo values are `envoyGateway.service.annotations: {kubernetes.civo.com/firewall-id: <from argo-up>, kubernetes.civo.com/ipv4-address: <reserved IP>, kubernetes.civo.com/loadbalancer-algorithm: round_robin}` and `envoyGateway.tls.mode: envoy`.
- On civo, `argo-up` waits after the root sync until the Service has an ingress IP equal to the reserved IP. The timeout is 300 s. Then `argo-up` runs the DNS wait. The DNS records exist only after CIVO-110. Until then, `argo-up` skips the DNS wait on civo and writes a log line.
- The golden AWS render must stay an empty diff.

**Review amendments (2026-09-06, kubernetes-architect):**
- Set `hostname` on the HTTPS listener (for example `*.civo.<root-domain>` from values) so SNI matching is explicit; Envoy Gateway's cert-manager task shows this pattern.
- AWS annotations stay a literal block guarded by target inside the shared file (see CIVO-050 amendment); Civo annotations come from values.
- Until the first certificate exists, the HTTPS listener reports `ResolvedRefs=False` while HTTP:80 still programs. Add an Argo health override for `Gateway` that treats a missing certificate Secret as Progressing, or set `cert-manager.io/issue-temporary-certificate: "true"` on the `Certificate` (CIVO-070), so `argo-up` does not time out on first bring-up.

## 5. Files/components affected

- `gitops/templates/platform/shared/envoy-gateway/gateway.yaml` (moved + templated).
- `gitops/values.yaml`.
- `scripts/argo-up.sh` (LB wait).
- `tests/golden/gitops-aws` stays unchanged.

## 6. Implementation steps

1. Template the three objects. Run `make gitops-check`. The aws diff must be empty.
2. Add the civo values. Render the templates. Run `kubeconform`.
3. Run `PROVIDER=civo make up`. Run `curl -H 'Host: argo.civo.<root-domain>' http://<reserved-ip>/`. The command must return the redirect page or the login page of Argo CD.
4. Run a port scan. Only ports 80/443 must be open on the reserved IP.
5. Run `argo-down`. The Civo LB must be deleted before the cascade. The output of `civo loadbalancer ls` must be empty.

## 7. Dependencies and blockers

CIVO-045 supplies the civo argo path. CIVO-025/030 supply the reserved IP and the firewall via SSM.

## 8. Acceptance criteria

- The Service field `status.loadBalancer.ingress[0].ip` equals the reserved IP.
- HTTP on port 80 routes by Host header to the Argo CD and Grafana backends. The Grafana route applies only if observability is present. Otherwise, a 404 from Envoy is acceptable. Record that result.
- `argo-down` removes the LB. The reserved IP remains in the account.
- The AWS golden diff is empty. The AWS Argo `app diff` is empty.

## 9. Validation

Offline: run the golden diff and kubeconform. Real cloud: run civo up/down (~0.2 USD incl. LB minutes).

## 10. AWS regression protection

- Run the golden render diff.
- After merge, run `argocd app diff root` on AWS. The output must be empty.
- The NLB annotations stay unchanged.

## 11. Rollout and rollback/recovery

Revert the change. Argo reconciles the resources. There is no data risk.

## 12. Risks and unresolved questions

- The annotation key for the reserved IP differs across documents (`kubernetes.civo.com/ipv4-address` vs `civo.com/reserved-ip`). The CCM README is authoritative. Confirm the key in the spike.
- **Resolved (2026-09-09):** `kubernetes.civo.com/ipv4-address` is correct - confirmed against the live CCM source (`civo/civo-cloud-controller-manager`, `loadbalancer.go`), not just documentation. `civo.com/reserved-ip` does not appear anywhere in that repo.
- **Deviations from §3/§4 (2026-09-09):** the `kubernetes.civo.com/protocol` annotation from §3's list was deliberately dropped - CCM's HTTP default is correct here, nothing needs overriding. Civo gets an HTTP:80-only listener; no HTTPS:443/TLS listener exists yet (§4's mention of one is corrected below). `scripts/gitops-render-check.sh`'s structural check, not named in §5, needed a per-target split - `EnvoyProxy`/`Gateway`/`GatewayClass` were forbidden for both `civo` and `local`; now required for `civo`, still forbidden for `local`.
- **Plan defect, not implementation defect (2026-09-09):** the implementation plan's own text said Gateway listeners would be values-driven so a later spec's HTTPS listener would be a values change. What was actually built is a literal per-target template block (§2's TLS-out-of-scope boundary and §1's "plain HTTP until CIVO-070" both argue for exactly this, and the plan's own contradiction was resolved that way). CIVO-070 will need to add the HTTPS:443 listener itself as a template change - corrected in `specs/civo/070-letsencrypt-http01-tls/spec.md` §3/§5.
- **New observation (2026-09-09):** a live bring-up reached `root` `Synced/Healthy` on civo for the first time - the `Gateway`'s ArgoCD health check (`Accepted`/`Programmed`, already present in `gitops/argocd/values.yaml` before this spec) is the first real health signal anywhere in civo's root tree. `scripts/argo-up.sh` still keeps the shortened 300s `WATCH_SECONDS` default from CIVO-045 deliberately, since one successful run doesn't prove it holds every time - see the tracking note added to `specs/civo/120-cnpg-on-civo-persistence/spec.md` §12.

## 13. Definition of done

- [x] Evidence for both providers
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-09 — implemented via subagent-driven development on branch `civo-060-envoy-lb`; advisor-reviewed plan, per-task reviews, final whole-branch review (one fix round, all findings addressed) all clean. Merged to `main` (`e2a3d2c`), no PR.
- 2026-09-09 — offline evidence: `make gitops-check` clean (AWS golden diff empty, civo/local structural check correct) at every task and after merge. `bash -n`/shellcheck clean on `scripts/argo-up.sh`.
- 2026-09-09 — live evidence (civo, ~region LON1): fresh bring-up via `PROVIDER=civo make argo-up` against merged `main` reached `root` `Synced/Healthy` (first time ever on civo). `civo_wait_for_lb_ip()` (this spec's readiness gate) confirmed the Envoy Service's LB got the reserved IP. `curl -H 'Host: argo.<fqdn>' http://<reserved-ip>/` returned HTTP 200 (ArgoCD login page). Port check: only 80 open on the reserved IP; 443 and other common ports closed/filtered, matching the HTTP-only scope. `PROVIDER=civo make argo-down` deleted the Envoy-managed LB Service and confirmed it gone before the cascade; `civo loadbalancer ls` empty afterward. Full teardown (`cluster-down`, `persistent-down`, `bootstrap-down`) afterward left zero Civo resources and no state bucket - verified via `civo kubernetes/network/volume/firewall/ip/loadbalancer ls` and `aws s3 ls`, matching the pre-run baseline exactly. Status: `DONE`.
