---
id: "HETZ-060"
title: "Hetzner ingress: Envoy Service LoadBalancer as an hcloud LB11 with private-IP targets and Gateway listeners 80/443"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Known CCM annotations; the work is verifying LB creation, private targets and deletion against a real cluster"
effort_estimate: "One session (3–5 h)"
estimate_confidence: "medium"
depends_on: ["HETZ-045", "HETZ-050"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-060 — Hetzner ingress

## 1. Outcome and rationale

On Hetzner, the Service of Envoy Gateway becomes an hcloud load balancer
of type `lb11`. The LB listens on 80 and 443 and forwards to the three
nodes over the private network. HTTP traffic reaches the Argo CD route.
TLS arrives with HETZ-070. AWS and Civo keep their annotation blocks
byte-for-byte. Unlike Civo, the LB has no reserved address: it gets a new
public IPv4 on every `make up`, and ExternalDNS (HETZ-070) follows it.

## 2. Scope and non-goals

In scope: the hetzner annotation block in
`gitops/templates/platform/shared/envoy-gateway/gateway.yaml`, the
`envoyGateway.location` value, the LB wait in `argo-up` (HETZ-045
generalised it; this spec verifies it). Not in scope: TLS (HETZ-070), DNS
(HETZ-070), proxy protocol (HETZ-190).

## 3. Current state / evidence

- `gateway.yaml:18-99` is the aws block (NLB annotations, HTTP:443 listener, ClientTrafficPolicy). `:100-118` is the civo block with `kubernetes.civo.com/{firewall-id,ipv4-address,loadbalancer-algorithm}`. The listener and TLS parts of the civo block carry CIVO-070/075's HTTPS:443 listener.
- The hcloud CCM annotations live under `load-balancer.hetzner.cloud/` (research.md). `location` or `network-zone` is required unless the CCM env `HCLOUD_LOAD_BALANCERS_LOCATION` is set; it is immutable. `use-private-ip` needs `networking.enabled` on the CCM and nodes attached to the network; both hold after HETZ-030/045.
- Hetzner firewalls attach to servers only and filter the public interface; LB-to-node traffic over the private network needs no rule. Hetzner LBs expose only their configured services.
- k3s `servicelb` is disabled in HETZ-030, so the CCM is the only LoadBalancer controller.
- LB11: 7.49 EUR/month, own IPv4 and IPv6, up to 25 targets and 5 services.

## 4. Design and contracts

- `gateway.yaml` gains `{{- else if eq .Values.target "hetzner" }}` with an EnvoyProxy whose `envoyService.annotations` are:
  `load-balancer.hetzner.cloud/location: {{ .Values.envoyGateway.location | quote }}`,
  `load-balancer.hetzner.cloud/type: lb11`,
  `load-balancer.hetzner.cloud/name: {{ .Values.project }}-ingress`,
  `load-balancer.hetzner.cloud/use-private-ip: "true"`,
  `load-balancer.hetzner.cloud/ipv6-disabled: "true"`,
  `load-balancer.hetzner.cloud/algorithm-type: round_robin`,
  `load-balancer.hetzner.cloud/health-check-protocol: tcp`.
  The `name` annotation gives the leak sweep (HETZ-040) a stable name in addition to the label; the CCM also labels the LB with the Service UID. `ipv6-disabled` keeps ExternalDNS to one A record.
- The Gateway and listeners copy the civo block: HTTP:80 in this spec; HETZ-070 adds HTTPS:443 with `hostname: "*.{{ .Values.envoyGateway.fqdn }}"` and the `platform-public-tls` Secret. No ClientTrafficPolicy (proxy protocol off).
- Envoy deployment resources stay as civo (`replicas: 1`, 20m/64Mi requests).
- `argo-up` waits for any `status.loadBalancer.ingress[0].ip` (HETZ-045). No wait keys on a fixed address anywhere. The DNS wait compares the discovered IP.
- No firewall annotation exists and none is needed. The node firewall (HETZ-030) allows 22 and 6443 on the public interface only; NodePorts are reached over the private network. This is the reverse of Civo, where the LB firewall had to be explicit.

## 5. Files/components affected

`gitops/templates/platform/shared/envoy-gateway/gateway.yaml`,
`gitops/values.yaml` (`envoyGateway.location`), `scripts/gitops-render-check.sh`
(`EnvoyProxy`/`Gateway` required for hetzner), `tests/golden/gitops-{aws,civo}`
unchanged.

## 6. Implementation steps

1. Add the block. Run `make gitops-check`. Both golden diffs empty. Render hetzner and run `kubeconform`.
2. Run `PROVIDER=hetzner make up`. Read the IP: `kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'`.
3. `curl -sS -o /dev/null -w '%{http_code}' -H 'Host: argo.hetzner.<root-domain>' http://<ip>/` returns 200 or the Argo CD redirect.
4. `hcloud load-balancer describe <project>-ingress` shows three targets, each with `use_private_ip: true`, all healthy; the public IPv6 is absent.
5. `nmap -p 22,80,443,6443,30000-32767 <ip>` shows only 80 open (443 after HETZ-070). Scan a node's public IP: only 22 and 6443.
6. Run `argo-down`. `hcloud load-balancer list -l project=<project>` is empty before the cascade starts.

## 7. Dependencies and blockers

HETZ-045 supplies the CCM, the root install with `envoyGateway.location`,
and the LB wait. HETZ-050 supplies the render sets.

## 8. Acceptance criteria

- `status.loadBalancer.ingress[0].ip` is set within 60 s of Service creation (research.md expects about 30 s).
- HTTP on port 80 routes by Host header to Argo CD. Grafana returns 404 until HETZ-160.
- The LB targets are the three private IPs; no public NodePort is reachable.
- `argo-down` removes the LB while the CCM runs; nothing is left for the sweep.
- The AWS and Civo golden diffs are empty; `argocd app diff root` on both is empty after merge.
- Cost: one LB11 at 7.49 EUR/month, billed hourly, stops at deletion.

## 9. Validation

Offline: golden diffs, kubeconform. Real cloud: one Hetzner up/down (about
0.20 EUR including LB hours).

## 10. AWS regression protection

The aws and civo blocks are untouched; the golden diffs prove it. After
merge, `argocd app diff root` on AWS and on Civo show no change. The NLB
and Civo annotations stay unchanged.

## 11. Rollout and rollback/recovery

Revert the change. Argo reconciles. The CCM deletes the LB with the
Service. No data risk.

## 12. Risks and unresolved questions

- A new LB IP per `make up` means DNS points at a dead address between `argo-down` and the next ExternalDNS write. HETZ-070 owns the TTL and ordering; nothing here can fix it.
- If the CCM ever loses its `networking` config, `use-private-ip` targets fail health checks and the LB serves 503; the CCM install in HETZ-045 is the single place that sets it.
- The CCM writes back read-only annotations (`id`, `ipv4`); Argo must ignore them or report OutOfSync — add an `ignoreDifferences` entry for the Service annotations if the first sync shows drift.
- `type: lb11` supports 5 services; Envoy uses 2. Sufficient.
- `algorithm-type` accepts `round_robin` and `least_connections`; the CCM writes the underscore form.

## 13. Definition of done

- [ ] Evidence for hetzner, empty golden diffs for aws and civo
- [ ] Port scan and target list recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
