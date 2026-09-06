---
id: "CIVO-190"
title: "Proxy protocol on the Civo LB for client IP preservation"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "One annotation and one policy toggle with a known side effect"
effort_estimate: "Half a session (1–2 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-060"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-190 — Proxy protocol and client IP

## 1. Outcome and rationale

Envoy sees the real client IP on Civo. This enables per-client rate limits
and accurate access logs. This matches the AWS setup, where the NLB sends
proxy protocol.

## 2. Scope and non-goals

In scope:

- `kubernetes.civo.com/loadbalancer-enable-proxy-protocol: send-proxy-v2`.
- `ClientTrafficPolicy enableProxyProtocol: true` on civo.
- ExternalDNS handling of a hostname-only status.

Not in scope: WAF.

## 3. Current state / evidence

CCM README: with proxy protocol, the Service status carries only a hostname
(`<id>.lb.civo.com`). ExternalDNS then creates a CNAME rather than an A
record. Let's Encrypt HTTP-01 still works through the hostname.

## 4. Design and contracts

The value `envoyGateway.proxyProtocol: true` on civo adds the annotation
and renders the ClientTrafficPolicy. ExternalDNS handles CNAME targets by
default. Verify that the reserved-IP annotation still applies.

## 5. Files/components affected

`gitops/values.yaml`, `shared/envoy-gateway/gateway.yaml` (already conditional).

## 6. Implementation steps

1. Flip the value. Sync. Check that the Envoy access log `x-forwarded-for`/downstream address equals the client IP.
2. Check that the DNS record type and the TLS issuance are still fine.

## 7. Dependencies and blockers

060.

## 8. Acceptance criteria

- The client IP is visible in the Envoy logs. DNS resolves. TLS renews.

## 9. Validation

Real cloud, cents.

## 10. AWS regression protection

AWS already uses proxy protocol. The values are unchanged.

## 11. Rollout and rollback/recovery

Flip the value back.

## 12. Risks and unresolved questions

- The interaction between the hostname-only status and the reserved IP.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
