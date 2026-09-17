---
id: "HETZ-190"
title: "Proxy protocol on the hcloud load balancer and client IP at Envoy"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "One annotation and one Envoy policy toggle, both already values-driven on Civo"
effort_estimate: "Two hours"
estimate_confidence: "high"
depends_on: ["HETZ-060", "CIVO-190"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-190 — Proxy protocol and client IP

## 1. Outcome and rationale

Envoy on Hetzner sees the real client address. With `use-private-ip`
(HETZ-060) every connection reaches the nodes from the load balancer's
private address, so without proxy protocol the client IP is lost before
Envoy. The hcloud LB supports PROXY protocol v2 per service, and Envoy
already has the `ClientTrafficPolicy` from CIVO-190. Off in M1, as on Civo.

## 2. Scope and non-goals

In scope: the `uses-proxyprotocol` annotation, the Envoy policy toggle for
`target: hetzner`, and the verification. Not in scope: rate limiting by
client IP, access logs, or the LB's own `hostname` mode.

## 3. Current state / evidence

- CIVO-190 makes the Civo annotation and the `ClientTrafficPolicy` values-driven (`envoyGateway.proxyProtocol`), and handles Civo's hostname-only status when enabled.
- The hcloud CCM annotation `load-balancer.hetzner.cloud/uses-proxyprotocol: "true"` enables PROXY v2 on every service of the LB (`research.md`). The Service status keeps `.ip`, so the Civo hostname trap does not occur.
- HETZ-060 sets `use-private-ip: "true"`, so the LB connects from `10.0.0.0/16`.

## 4. Design and contracts

- `gateway.yaml` hetzner block adds `load-balancer.hetzner.cloud/uses-proxyprotocol: {{ .Values.envoyGateway.proxyProtocol | quote }}`.
- `ClientTrafficPolicy` `enableProxyProtocol` renders on hetzner exactly as on civo, from the same value.
- Both sides must flip together: the LB sending PROXY headers to an Envoy that does not expect them breaks every request, and the reverse makes Envoy wait for a header that never comes. One value controls both.
- `argo-up` needs no change: the LB IP stays in `.status.loadBalancer.ingress[0].ip`.

## 5. Files/components affected

- `gitops/templates/platform/shared/envoy-gateway/gateway.yaml` (hetzner annotation line).
- `gitops/values.yaml` (`envoyGateway.proxyProtocol: false` default for hetzner).

## 6. Implementation steps

1. Add the annotation line; render three targets; aws and civo unchanged.
2. On a running Hetzner cluster set the value to `true` through `argo-up`; confirm the LB service shows `proxyprotocol: true` in `hcloud load-balancer describe`.
3. `curl -H "Host: <fqdn>" https://<fqdn>/` from a known address; check Envoy's access log (or a debug HTTPRoute echoing `X-Forwarded-For`) shows that address.
4. Set the value back to `false`; confirm requests still succeed.

## 7. Dependencies and blockers

HETZ-060 for the LB; CIVO-190 for the values plumbing.

## 8. Acceptance criteria

- With `proxyProtocol: true`: the echo shows the client address; HTTPS and the HTTP redirect both work; HETZ-130 tests pass.
- With `false`: unchanged behaviour.
- Toggling causes at most one LB service update (the CCM applies it in place); measure the interruption.

## 9. Validation

Offline: three-target render. Real cloud: one toggle on a running lab.

## 10. AWS regression protection

AWS uses its own NLB proxy-protocol path; the hetzner line is inside the
hetzner branch. Golden renders for aws and civo unchanged.

## 11. Rollout and rollback/recovery

One value; rollback is `false`.

## 12. Risks and unresolved questions

- The CCM applies the annotation to all services of the LB, including the plain HTTP:80 listener used for the redirect; Envoy's policy covers both listeners, so this is consistent, but verify the redirect.
- Health checks from the LB do not carry PROXY headers; Envoy's health endpoint must tolerate that or the check must target a TCP port.

## 13. Definition of done

- [ ] Acceptance criteria met and recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
