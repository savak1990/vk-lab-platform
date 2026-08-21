# 011 — NLB Edge (AWS Load Balancer Controller + NLB/ACM)

**Complexity:** Medium
**Risk:** Medium — deletion-ordering between the NLB and the AWS Load Balancer Controller is a constitution-flagged risk; getting it wrong can strand an NLB/leak AWS cost during `make down`.
**Estimated cost:** ~1 day · AWS runtime cost: NLB hourly cost while `make up` is active.
**Recommended model:** Sonnet, with an Opus review pass on the deletion-ordering hooks specifically.
**Depends on:** 002-persistent-foundation (Route 53 zone, ACM cert), 010-envoy-gateway (the `Service`/`EnvoyProxy` this spec attaches AWS annotations to)
**Lifecycle class(es) touched:** Disposable (NLB, AWS Load Balancer Controller) / Persistent (referenced, not modified: the ACM cert and hosted zone from spec 002)

## Scope

Completes the public traffic path from architecture.md §8/§10–12:
`Client → Route 53 → NLB → Envoy Gateway → Kubernetes workloads`.

- AWS Load Balancer Controller (Argo-managed), watching Envoy Gateway's own
  `Service` (spec 010) directly — **no separate `Ingress` or `Gateway`
  resource at the AWS layer**. There is nothing for AWS to route by host or
  path; Envoy's `HTTPRoute`s remain the only routing definition anywhere in
  this design.
- An NLB provisioned in `target-type: ip` mode from that `Service`, with a
  TLS listener terminating using the `lab.<root-domain>`/
  `*.lab.<root-domain>` ACM certificate from spec 002. No cert-manager, no
  second certificate.
- Disposable Route 53 records inside the delegated `lab.<root-domain>`
  hosted zone (spec 002/ADR 0002) pointing hostnames such as
  `grafana.lab.<root-domain>` and `argocd.lab.<root-domain>` at the NLB —
  owned by ExternalDNS, specified separately in spec 012.

This entire spec is `aws`-target-only. The `local` target (spec 021) has no
NLB, Route 53, or ACM at all — access there is via `kubectl port-forward`
directly to Envoy Gateway's Service (spec 010 Requirements 5–6), with no
equivalent public-edge layer.

Excludes: any Gateway API or `Ingress` routing logic at the AWS layer (there
is none — see above; all routing stays inside spec 010's `HTTPRoute`s);
the `lab.<root-domain>` hosted zone and certificate themselves (persistent,
created in spec 002 — this spec only references them); the parent/root
hosted zone and its NS delegation (external, constitution §14 — never
touched by this spec); DNS record lifecycle for application hostnames
(ExternalDNS, spec 012); cert-manager or any non-ACM certificate mechanism
(rejected — see ADR 0011).

## Requirements

1. The NLB is responsible for AWS ingress and ACM TLS termination; it MUST NOT perform any host/path routing (constitution §8) — plaintext forwarding to Envoy Gateway's `Service` is its entire job.
2. The AWS Load Balancer Controller is a controller and MUST be Argo-managed (constitution §2); it MUST remain running until NLB-triggering Kubernetes resources have been removed and it has cleaned up the NLB — constitution §7's worked example ("NLB-triggering Kubernetes resources must be removed while AWS Load Balancer Controller is still running") is the exact ordering constraint this spec must satisfy operationally.
3. EKS MUST NOT be destroyed while NLB cleanup is still pending (constitution §7) — `make down`'s ordering (built out fully in spec 014) depends on this spec exposing a reliable signal for "NLB is gone" before the disposable Terraform stack proceeds.
4. The ACM certificate used here MUST be the persistent-lifecycle `lab.<root-domain>`/`*.lab.<root-domain>` certificate from spec 002 — do not provision a second certificate at this layer, do not introduce cert-manager, and do not reuse the existing root-domain certificate (constitution §14). See ADR 0011 for why NLB+ACM was chosen over NLB+cert-manager.
5. NLB target-type mode MUST be `ip` — the AWS Load Balancer Controller registers Envoy Gateway pod IPs directly, not node IPs, and this is the reason AWS Load Balancer Controller is required at all rather than the legacy in-tree/cloud-controller-manager NLB path (which only supports instance-mode targets and is deprecated).
6. The NLB exposes port 443 only. There is no port 80 listener and no HTTP→HTTPS redirect at the AWS layer — an ALB's free redirect does not carry over to an NLB TLS listener, and adding one would mean either a second listener/target-group Envoy must also handle, or an L7 component this design deliberately doesn't have at the AWS edge. `http://` requests to a `*.lab.<root-domain>` hostname simply fail to connect; this is accepted, stated behavior for a lab, not an oversight.
7. Proxy Protocol v2 MUST be enabled on the NLB target group (`service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: "*"` or equivalent) and Envoy Gateway's `EnvoyProxy` resource (spec 010 Requirement 8) MUST be configured to trust and parse it. An NLB TLS listener terminates the connection, so without Proxy Protocol v2 every request appears to originate from the NLB itself — this would silently defeat spec 010's per-client rate-limiting requirement, not just lose logging fidelity. Verify NLB health checks still pass against Envoy's listener with Proxy Protocol v2 enabled; mismatched health-check expectations are the known failure mode.
8. The ACM certificate ARN MUST reach the Argo-managed `EnvoyProxy` annotation (`service.beta.kubernetes.io/aws-load-balancer-ssl-cert`) without being hardcoded as an account-specific literal in committed YAML (constitution §19). Wire it the same way ADR 0010 wired the Postgres EBS volume handle: a Terraform output from spec 002 → an `argocd-bootstrap` Helm parameter → `gitops/values.yaml` → templated into the `aws`-target `EnvoyProxy` values. There is no ACM auto-discovery mechanism for NLB (unlike ALB's host-based SAN matching), so this explicit wiring path is required, not optional.
9. AWS Load Balancer Controller gets its own EKS Pod Identity association (new `terraform/modules/aws-lb-controller-pod-identity`, following the `terraform/modules/karpenter-pod-identity`/`terraform/modules/ebs-csi-pod-identity` precedent) — not IRSA, per the constitution's "prefer EKS Pod Identity or an equivalent" (§5) and ADR 0001's "prefer Pod Identity going forward" decision.
10. This spec does not create or manage any Route 53 record itself — it only makes the NLB exist for ExternalDNS (spec 012) to point records at. Record ownership is entirely spec 012's concern.

## Implementation hints

- Envoy Gateway's `EnvoyProxy` resource (spec 010) is where every annotation in Requirements 5–8 above actually lands — `EnvoyProxy.spec.provider.kubernetes.envoyService.annotations`, layered in via `values-aws.yaml`. This spec supplies the values; spec 010 supplies the resource shape.
- Test the deletion-ordering constraint deliberately: delete/modify the `EnvoyProxy`/`Service` resource that triggers NLB creation and confirm the AWS Load Balancer Controller removes the NLB before considering the controller itself safe to remove.
- Since there is no Ingress/Gateway resource for AWS Load Balancer Controller to watch, verify which controller version/configuration mode is needed to provision an NLB purely from `Service` annotations (`service.beta.kubernetes.io/aws-load-balancer-type: external` + `aws-load-balancer-nlb-target-type: ip`) — this is the controller's "Service" mode, distinct from its Ingress and Gateway API modes, neither of which this spec uses.

## Testing / acceptance criteria

- A request to a `*.lab.<root-domain>` hostname (e.g. `grafana.lab.<root-domain>`) over HTTPS reaches Grafana/Argo CD's UI via `Route 53 → NLB → Envoy Gateway`, with TLS terminated correctly using the `lab.<root-domain>` ACM certificate, and the correct client IP visible to Envoy (Proxy Protocol v2 verification).
- A request to the same hostname over plain HTTP (port 80) fails to connect — confirming Requirement 6's stated behavior, not a bug.
- Deleting the Kubernetes-side `Service`/`EnvoyProxy` resource that triggers NLB creation results in the NLB being cleaned up automatically, confirmed via the AWS console/API, before the disposable Terraform stack is destroyed.
- `make down` removes the NLB, but the `lab.<root-domain>` hosted zone and its certificate remain — confirmed by re-querying the zone/certificate after teardown (formalized as a full acceptance scenario in spec 014).
- `make up` (after a prior `make down`) recreates a working NLB, and HTTPS works again, without any Terraform plan showing drift or changes to the parent/root hosted zone.
- `make down`-style teardown does not leave an orphaned NLB behind — this is the specific leak the constitution's "no leaks" postcondition targets for this component.
- Fast validation (Helm/manifest rendering, k8s schema); the deletion-ordering behavior above is this spec's equivalent of a lifecycle test, since there's no persistent data here, just a controller ordering guarantee to verify.
