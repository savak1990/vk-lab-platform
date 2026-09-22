---
id: "HETZ-060"
title: "Hetzner ingress: Envoy Service LoadBalancer as an hcloud LB11 with private-IP targets and Gateway listeners 80/443"
status: "DONE"
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
updated: "2026-09-22"
completed: "2026-09-22"
---

# HETZ-060 — Hetzner ingress

## 1. Outcome and rationale

On Hetzner, the Service of Envoy Gateway becomes an hcloud load balancer
of type `lb11`. The LB listens on 80 and 443 and forwards to the three
nodes over the private network. Port 80 redirects to 443, and HTTPS
reaches the Argo CD route. Both listeners ship here, not the HTTP one
alone - see §2. AWS and Civo keep their annotation blocks
byte-for-byte. Unlike Civo, the LB has no reserved address: it gets a new
public IPv4 on every `make up`, and ExternalDNS (HETZ-070) follows it.

## 2. Scope and non-goals

In scope: the hetzner arms of `platform.envoyServiceSpec` and
`platform.gatewayEnabled`, the `envoyGateway.location` value, the LB and
DNS waits in `argo-up`, and the load-balancer leak sweep in
`scripts/cluster-down.sh`. Not in scope: the TLS Secret round-trip and the
measured DNS timings (HETZ-070), proxy protocol (HETZ-190).

**Two scope corrections made during implementation (2026-09-22).**

*Both listeners ship here, not HTTP alone.* The phasing this spec planned
is not implementable. Every HTTPRoute that renders once the Gateway exists
names a `parentRefs.sectionName`, and two of the three name `https`:
`argocd`, `grafana` (both from `envoy-gateway/httproutes.yaml`) and
`https-redirect` (from `tls/redirect.yaml`, gated on
`selfManaged AND gatewayEnabled`, and hetzner is selfManaged). A route
whose named listener does not exist is never Accepted, its
`.status.parents` stays empty, and the root sync stalls behind its health
check - the same failure HETZ-045 §14 records costing 20 minutes. An
HTTP-only variant would need a temporary hetzner exclusion on
`redirect.yaml` and a hetzner branch in `httproutes.yaml`, both deleted
again by HETZ-070: a larger diff than shipping both listeners. The
certificate is already there - cert-manager has issued the Let's Encrypt
wildcard on this target since HETZ-045, with no Gateway to use it.

*DNS therefore starts here too.* `external-dns` renders and runs on
hetzner today with `sources: [gateway-httproute]` and `policy: sync`. It
is quiet only because no HTTPRoute exists. The moment the routes are
Accepted it writes the A and TXT records. This cannot be avoided except by
leaving the routes un-Accepted, which is the stall above. HETZ-070 is
narrowed accordingly.

## 3. Current state / evidence

- `gateway.yaml:18-99` is the aws block (NLB annotations, HTTP:443 listener, ClientTrafficPolicy). `:100-118` is the civo block with `kubernetes.civo.com/{firewall-id,ipv4-address,loadbalancer-algorithm}`. The listener and TLS parts of the civo block carry CIVO-070/075's HTTPS:443 listener.
- The hcloud CCM annotations live under `load-balancer.hetzner.cloud/` (research.md). `location` or `network-zone` is required unless the CCM env `HCLOUD_LOAD_BALANCERS_LOCATION` is set; it is immutable. `use-private-ip` needs `networking.enabled` on the CCM and nodes attached to the network; both hold after HETZ-030/045.
- Hetzner firewalls attach to servers only and filter the public interface; LB-to-node traffic over the private network needs no rule. Hetzner LBs expose only their configured services.
- k3s ships ServiceLB (klipper), which HETZ-030 disables with `--disable=servicelb`, so the hcloud CCM is the only LoadBalancer controller and creates the LB from the Service. Leaving both enabled would give the Service two controllers.
- LB11: 7.49 EUR/month, own IPv4 and IPv6, up to 25 targets and 5 services.

## 4. Design and contracts

- `platform.envoyServiceSpec` gains an `{{- else if eq .Values.target "hetzner" -}}` arm, which `gateway.yaml` renders into the EnvoyProxy's `envoyService.annotations`:
  `load-balancer.hetzner.cloud/location: {{ .Values.envoyGateway.location | quote }}`,
  `load-balancer.hetzner.cloud/type: lb11`,
  `load-balancer.hetzner.cloud/name: {{ .Values.project }}-ingress`,
  `load-balancer.hetzner.cloud/use-private-ip: "true"`,
  `load-balancer.hetzner.cloud/ipv6-disabled: "true"`,
  `load-balancer.hetzner.cloud/algorithm-type: round_robin`.
  `health-check-protocol` is dropped from the list above: `tcp` is the CCM default and states nothing. The `name` annotation is not an addition to the label - it is the **only** thing the leak sweep can match on, because the CCM applies no labels at all (see §5 and HETZ-040 §14). `ipv6-disabled` keeps ExternalDNS to one A record.
- The Gateway and listeners do not copy the civo block - hetzner **shares** it. `platform.envoyListeners`' civo arm becomes `has .Values.target (list "civo" "hetzner")`, giving HTTP:80 and HTTPS:443 with `certificateRefs: [platform-public-tls]`. One consequence is deliberate: the shared arm carries no `hostname: "*.{{ .Values.envoyGateway.fqdn }}"`, which HETZ-070 §4 had promised. The certificate is a wildcard and each HTTPRoute carries its own hostnames, so the listener needs no host constraint; a per-target arm to add one would be duplication, not precision. No ClientTrafficPolicy (proxy protocol off).
- Envoy deployment resources stay as civo (`replicas: 1`, 20m/64Mi requests).
- `argo-up` waits for any `status.loadBalancer.ingress[0].ip`. **This spec builds that wait; HETZ-045 did not.** §7's claim that it did is wrong - HETZ-045 §14 records both waits as deliberately deferred, and its two hetzner dispatch arms were `echo`-only placeholders naming this spec. The only wait that existed keyed on `[ "$svc_ip" = "$RESERVED_IP" ]`, which hetzner never sets and which would abort the script under `set -u`. The fix is to generalise `civo_wait_for_lb_ip`/`civo_wait_for_dns` into `wait_for_lb_ip`/`wait_for_dns`, matching the reserved IP only when one is set. Hetzner's DNS budget is 300 s against Civo's 60 s, because its address is new on every `make up`.
- No firewall annotation exists and none is needed. The node firewall (HETZ-030) allows 22 and 6443 on the public interface only; NodePorts are reached over the private network. This is the reverse of Civo, where the LB firewall had to be explicit.

## 5. Files/components affected

`gitops/templates/_helpers.tpl` (`gatewayEnabled`, the hetzner
`envoyServiceSpec` arm, the widened `envoyListeners` guard),
`gitops/templates/platform/shared/envoy-gateway/gateway.yaml`,
`gitops/values.yaml` and `gitops/bootstrap/values.yaml`
(`envoyGateway.location`), `gitops/bootstrap/templates/root-application.yaml`,
`scripts/argo-up.sh`, `scripts/gitops-render-check.sh`,
`scripts/cluster-down.sh`, `.github/workflows/lifecycle-test.yml`.

`tests/golden/` holds `gitops-aws` only - there is no civo golden, so
"the civo golden diff is empty" in §8 and §9 was a claim about a file
that does not exist. Civo, hetzner and local are checked structurally, by
object set. Since this change edits two helpers Civo consumes, the Civo
proof is a manual before/after `helm template` diff instead.

## 6. Implementation steps

1. Add the block. Run `make gitops-check`. Both golden diffs empty. Render hetzner and run `kubeconform`.
2. Run `PROVIDER=hetzner make up`. Read the IP: `kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'`.
3. `curl -sS -o /dev/null -w '%{http_code}' -H 'Host: argo.hz.<root-domain>' http://<ip>/` returns 200 or the Argo CD redirect.
4. `hcloud load-balancer describe <project>-ingress` shows three targets, each with `use_private_ip: true`, all healthy. The LB still **has** an IPv6 - `ipv6-disabled` only suppresses it in the Service ingress status (`research.md:262`), so the check is that `.status.loadBalancer.ingress[0]` carries `.ip` alone.
5. `nmap -p 22,80,443,6443,30000-32767 <ip>` shows only 80 open (443 after HETZ-070). Scan a node's public IP: only 22 and 6443.
6. Run `argo-down`. The label selector in the original step is a no-op - the CCM sets no `project` label, so it returns empty whether or not an LB leaked. Match the name instead: `hcloud load-balancer list -o json | jq -r '(. // [])[].name' | grep "^<project>-"` is empty before the cascade starts.

## 7. Dependencies and blockers

HETZ-045 supplies the CCM and the root install. It supplies **neither**
`envoyGateway.location` nor the LB wait, though this section originally
claimed both; see §4. HETZ-050 supplies the render sets.

## 8. Acceptance criteria

- `status.loadBalancer.ingress[0].ip` is set within 60 s of Service creation (research.md expects about 30 s).
- HTTP on port 80 returns **301** to https - the redirect HTTPRoute renders on this target. HTTPS on 443 routes by Host header to Argo CD.
- The LB targets are the three private IPs; no public NodePort is reachable.
- `argo-down` removes the LB while the CCM runs; nothing is left for the sweep.
- The AWS golden diff is empty but for the one new, empty root parameter; the Civo render is identical once comments are stripped (see §5). `argocd app diff root` on both is empty after merge.
- Cost: one lb11 at USD 10.27 gross per month (net 8.49, VAT 21 percent), billed hourly, stopping at deletion. `research.md`'s 7.49 came from a press release and is stale; this is what `GET /v1/pricing` returns.

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
- The CCM writes back read-only annotations (`id`, `ipv4`), but Argo has nothing to diff against: Argo applies the `EnvoyProxy` CR, and the Envoy Gateway controller derives the Service from it, so the Service is never in Argo's desired state. `argo-down.sh:238-239` states this for the same object on aws. Neither aws nor civo carries an `ignoreDifferences` for it, and civo's CCM writes back the same class of annotation. Watch the Service on the first sync; the open question is whether Envoy Gateway's own reconciler fights the CCM, which no manifest change can answer.
- On the first sync the Gateway is wave 0 and `Certificate platform-public` is wave 2, so `cert-manager.io/issue-temporary-certificate: "true"` does not cover the window before the Certificate object exists: the https listener reports `ResolvedRefs` false until the Secret appears, and self-heals when it does. The http listener is unaffected. Civo runs the identical wave layout and CIVO-070 recorded it converging. Root may look briefly Degraded inside a 2700 s watch budget.
- An `argo-down` that aborts early leaves a load balancer that no automated check reports, because `make` stops the chain and `cluster-down`'s sweep never runs. The sweep added here covers the other case - teardown finished, load balancer lingered. Recorded in HETZ-047 §14.
- `type: lb11` supports 5 services; Envoy uses 2. Sufficient.
- `algorithm-type` accepts `round_robin` and `least_connections`; the CCM writes the underscore form.

## 13. Definition of done

- [ ] Evidence for hetzner, empty golden diffs for aws and civo
- [ ] Port scan and target list recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-20 — k3s (HETZ-017): the reason the hcloud CCM is the only
  LoadBalancer controller changes from "the bootstrap ships none" to "the
  bundled one is disabled by flag". The LB design is unaffected.

- 2026-09-22 — implemented and closed. Offline evidence: `make gitops-check`
  green, with the aws golden baseline changed by exactly two lines (the new,
  empty `envoyGateway.location` root parameter, inert on that target); the
  civo, hetzner and local object sets pass; the hetzner render is 41 of 41
  valid under `kubeconform -strict`; `make scripts-check` green, including
  `argo-up-dispatch-test.sh` reporting four dispatch blocks that each name
  every provider. The hetzner render gains exactly seven objects:
  `GatewayClass`, `EnvoyProxy`, `Gateway`, the `argocd`, `grafana` and
  `https-redirect` HTTPRoutes, and the Grafana `BackendTrafficPolicy`.

  The Civo regression proof is the manual diff §5 describes, because no civo
  golden exists. Its only entry is the comment above the https listener, whose
  wording changed when the arm stopped being Civo's alone; the parsed object
  is identical. `helm template` for aws is unchanged.

  Four claims in earlier sections were wrong and are corrected in place rather
  than left to mislead: §2/§7 on what HETZ-045 supplied, §4 on the load
  balancer wait, §5/§8/§9 on a civo golden diff that does not exist, and §6
  step 4 on the IPv6. §6 step 6's label selector was a no-op for the same
  reason the leak sweep was blind, and is replaced by a name match.

  Outstanding: every acceptance criterion that needs a cluster. The live cycle
  is deliberately not folded into this entry, because it is also the evidence
  HETZ-047, HETZ-085 and HETZ-115 are waiting on.

- 2026-09-22 — live cycle on three `cx33` in `fsn1`, `TARGET_REVISION=hetz-060-ingress`.
  Every acceptance criterion that needs a cluster is now met.

  | Criterion | Measured |
  |---|---|
  | address within 60 s | **17 s** (Service 13:59:14Z, address 13:59:31Z) |
  | port 80 | **301** to `https://argo.hz.<root>/` |
  | port 443 | **200** at Argo CD; Grafana 302 to its own login |
  | targets on private IPs | three, all `use_private_ip=true` |
  | no public NodePort | `curl <node-public-ip>:30261` → refused |
  | type and location | `lb11` in `fsn1`, from the `REGION` input |
  | `argo-down` removes it | gone **1 s** after the Service |
  | sweep after teardown | eight categories clean |

  Both listeners programmed on the first sync, `Accepted` and `ResolvedRefs`
  true, and all three HTTPRoutes attached with no stall. The §12 risk about
  the https listener having no Secret did not fire, but not because it was
  wrong: `argo-up` restored `platform-public-tls` from SSM before the root
  install, so the Secret already existed. The risk stands for a project with
  no stored certificate.

  Two of the three load balancer targets report `unhealthy`, and that is
  correct rather than a fault. The Service is `externalTrafficPolicy: Local`
  and Envoy runs one replica, so only the node hosting it answers the health
  check. All three are registered on their private addresses, which is what
  §8 asks. The trade-off is worth stating: losing that node drops ingress
  until Kubernetes reschedules, the same exposure Civo carries.

  Confirmed live, as §6 step 4 was corrected to predict: the load balancer
  does have an IPv6 (`2a01:4f8:c01e:399f::1`). `ipv6-disabled` suppresses it
  in the Service status only.

  Whole-cycle timings, for whoever sizes budgets: `bootstrap-up` 5m06s,
  `persistent-up` 3m10s, `cluster-up` 4m10s, `argo-up` 16m31s; teardown
  `argo-down` 7m31s, `cluster-down` 1m16s, `persistent-down` 0m31s,
  `bootstrap-down` 2m09s, total 11m27s. Roughly 10 minutes of `argo-up` and
  6 minutes of `argo-down` were avoidable and are explained in HETZ-070 §14
  and HETZ-047 §14; a clean cycle is about 19 minutes up and 5 down.

  One defect this PR introduced and fixed in the same cycle: external-dns
  published two A values per name, the public address and the load balancer's
  private `10.0.1.1`, so about half of all DNS answers were unroutable.
  `disable-private-ingress` was missing from the annotation arm although
  `research.md:46` lists it. Proven on the same cluster: the Gateway dropped
  to one address 42 s after the sync, external-dns rewrote the records 33 s
  later, and both names then resolved to the public address alone. `argo-up`'s
  DNS wait had passed anyway, because it reads one answer and round-robin
  handed it the public one - luck, not correctness, and the reason to fix the
  record rather than the wait.

  Two unrelated notes from the same run, neither owned here. `make full-down`
  halts at `cluster-down`'s leak exit; this cycle ran the phases separately
  on purpose, so the 11m27s total is the real figure rather than a truncated
  one. And `argo-down`'s load balancer message says "NLB", which is AWS
  wording on this target - cosmetic, recorded in HETZ-047.