# 012 — Public Edge (ALB + DNS/TLS)

**Complexity:** Medium
**Risk:** Medium — deletion-ordering between the ALB and the AWS Load Balancer Controller is a constitution-flagged risk; getting it wrong can strand an ALB/leak AWS cost during `make down`.
**Estimated cost:** ~1 day · AWS runtime cost: ALB hourly cost while `make up` is active.
**Recommended model:** Sonnet, with an Opus review pass on the deletion-ordering hooks specifically.
**Depends on:** 002-persistent-foundation (Route 53 zone, ACM cert), 011-envoy-gateway (something for the ALB to route to)
**Lifecycle class(es) touched:** Disposable (ALB, AWS Load Balancer Controller) / Persistent (Route 53 record lifecycle touches the persistent zone, though the record itself is disposable)

## Scope

Completes the public traffic path from architecture.md §8/§10–12: `Client → Route 53 → ALB → Envoy Gateway → Kubernetes workloads`.

- AWS Load Balancer Controller (Argo-managed), provisioning an ALB from Kubernetes-side `Ingress`/Gateway API resources.
- ALB configured for AWS-level ingress and ACM TLS termination, using the `lab.<root-domain>`/`*.lab.<root-domain>` certificate from spec 002.
- Disposable Route 53 records inside the delegated `lab.<root-domain>` hosted zone (spec 002/ADR 0002), pointing hostnames such as `grafana.lab.<root-domain>` and `argocd.lab.<root-domain>` at the ALB.

This entire spec is `aws`-target-only. The `local` target (spec 021) has no ALB, Route 53, or ACM at all — access there is via `kubectl port-forward` directly to Envoy Gateway's Service (spec 011 Requirements 5–6), with no equivalent public-edge layer.

Excludes: any Gateway API routing logic (011 already owns this — this spec's ALB should route everything to Envoy Gateway, not duplicate host/path rules); the `lab.<root-domain>` hosted zone and certificate themselves (persistent, created in spec 002 — this spec only adds disposable records inside that zone); the parent/root hosted zone and its NS delegation (external, constitution §14 — never touched by this spec).

## Requirements

1. ALB is responsible for AWS ingress and ACM TLS termination; it MUST NOT duplicate the routing logic already implemented in Envoy Gateway (constitution §8) — the ALB's job is essentially "get HTTPS traffic to the Envoy Gateway service," full stop.
2. The AWS Load Balancer Controller is a controller and MUST be Argo-managed (constitution §2); it MUST remain running until ALB-triggering Kubernetes resources have been removed and it has cleaned up the ALB — constitution §7's worked example ("ALB-triggering Kubernetes resources must be removed while AWS Load Balancer Controller is still running") is the exact ordering constraint this spec must satisfy operationally.
3. EKS MUST NOT be destroyed while ALB cleanup is still pending (constitution §7) — `make down`'s ordering (built out fully in spec 014) depends on this spec exposing a reliable signal for "ALB is gone" before the disposable Terraform stack proceeds.
4. The ACM certificate used here MUST be the persistent-lifecycle `lab.<root-domain>`/`*.lab.<root-domain>` certificate from spec 002 — do not provision a second certificate at this layer, and do not reuse the existing root-domain certificate (constitution §14).
5. End-to-end TLS between ALB and Envoy Gateway is explicitly not required initially (architecture.md §11) — terminate TLS at the ALB and use plain HTTP internally unless a later spec justifies otherwise.
6. DNS records created by this spec live inside the delegated `lab.<root-domain>` hosted zone from spec 002 and are Disposable-lifecycle — `make down` MUST remove them along with the ALB, but MUST NOT delete the `lab.<root-domain>` hosted zone or its certificate, and MUST NOT touch the parent/root hosted zone (constitution §14).
7. Record ownership MUST be explicit and MUST NOT overlap between Terraform and the Kubernetes-side controller managing these records (constitution §2, §14) — Terraform owns the zone and certificate (spec 002); whichever controller creates the ALB-pointing record (this spec) owns that record's lifecycle.

## Implementation hints

- The AWS Load Balancer Controller watches `Ingress` or Gateway API `Gateway`/`HTTPRoute` resources annotated for ALB provisioning — confirm which mode (classic Ingress vs. Gateway API-native) the controller version in use supports well, since Gateway API support has matured at different rates across controller versions.
- Route 53 record creation can be automated via `external-dns` (Argo-managed), scoped to the `lab.<root-domain>` hosted zone from spec 002, watching the same resources that trigger ALB creation — keeps the AWS-record lifecycle tied to the same Kubernetes-side resource lifecycle as the ALB itself. Scope `external-dns`'s IAM permissions to only that one hosted zone; it must have no access to the parent/root zone.
- Test the deletion-ordering constraint deliberately: delete the Ingress/Gateway resource that triggers the ALB and confirm the controller removes the ALB and its record inside `lab.<root-domain>` before considering the AWS Load Balancer Controller itself safe to remove.

## Testing / acceptance criteria

- A request to a `*.lab.<root-domain>` hostname (e.g. `grafana.lab.<root-domain>`) over HTTPS reaches Grafana/Argo CD's UI via `Route 53 → ALB → Envoy Gateway`, with TLS terminated correctly using the `lab.<root-domain>` ACM certificate.
- Deleting the Kubernetes-side resource that triggers ALB creation results in the ALB and its record inside `lab.<root-domain>` being cleaned up automatically, confirmed via the AWS console/API, before the disposable Terraform stack is destroyed.
- `make down` removes the ALB and its DNS records inside the lab zone, but the `lab.<root-domain>` hosted zone and its certificate remain — confirmed by re-querying the zone/certificate after teardown (formalized as a full acceptance scenario in spec 014).
- `make up` (after a prior `make down`) recreates a working ALB and DNS record inside the existing `lab.<root-domain>` zone, and HTTPS works again, without any Terraform plan showing drift or changes to the parent/root hosted zone.
- `make down`-style teardown does not leave an orphaned ALB or stray record in the lab zone behind — this is the specific leak the constitution's "no leaks" postcondition targets for this component.
- Fast validation (Helm/manifest rendering, k8s schema); the deletion-ordering behavior above is this spec's equivalent of a lifecycle test, since there's no persistent data here, just a controller ordering guarantee to verify.
