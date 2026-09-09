---
id: "CIVO-065"
title: "cert-manager installed behind a toggle, off on AWS"
status: "IN_PROGRESS"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One Helm Application with a well-known chart"
effort_estimate: "Half a session (2–3 h)"
estimate_confidence: "high"
depends_on: ["CIVO-050"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-09"
completed: null
---

# CIVO-065 — cert-manager install

## 1. Outcome and rationale

cert-manager runs on the Civo target with the Gateway API HTTP-01 solver
enabled. cert-manager is absent on AWS unless `certManager.enabled=true`.
Both CIVO-070 (public TLS) and CIVO-085 (workload identity certificates)
need it. For that reason, it is its own small slice.

## 2. Scope and non-goals

In scope: the Application, the CRDs, the namespace, the wave, and the
ServiceMonitor gating. Not in scope: the issuers and the certificates
(CIVO-070, CIVO-085).

## 3. Current state / evidence

No cert-manager objects exist in `gitops/` (verified negative). ADR 0011
rejects cert-manager for AWS. CIVO-015's ADR 0028 allows it on Civo.

- **Correction (2026-09-09):** `gitops/templates/platform/aws/cert-manager/application.yaml` already exists (added 2026-09-07) — an unconditional, `target=="aws"`-gated cert-manager install that exists solely to serve aws-load-balancer-controller's own webhook certificate. It is unrelated to this spec's civo/ACME use case and this spec does not touch it.

## 4. Design and contracts

- `gitops/templates/platform/shared/cert-manager/application.yaml` is gated by `{{- if .Values.certManager.enabled }}`. The chart is `cert-manager` from `https://charts.jetstack.io`. Pin the version at implementation (latest 1.x). Set `crds.enabled: true`. Set `config.gatewayAPI.enabled: true` (current docs; https://cert-manager.io/docs/configuration/acme/http01/) or the key for the pinned version. Set `ServerSideApply=true`. Wave: the first candidate was -2 (before ESO/consumers, after the Envoy chart CRDs at -1). cert-manager must be Established before the Certificates at wave 0. Place it at -3. Note that the Gateway API CRDs come from Envoy Gateway at -1. The HTTP-01 Gateway solver needs that CRD only at runtime, not at install.
- Resources: requests 50m/64Mi per component.
- `certManager.enabled` defaults to false. The civo values set it to true.

**Review amendments (2026-09-06, kubernetes-architect):**
- Add a `PreSync` hook Job on the consumers' Applications (or on the cert-manager Application's dependents) that waits for `certificates.cert-manager.io` to report `Established`, per this repository's rule that sync waves do not gate CRD readiness across Applications.

**Correction (2026-09-09):** the wave placement above is wrong — wave -3 syncs before Envoy Gateway's Application (wave -1, the CRD source), not after. The implementation uses wave 0, the minimum integer that syncs strictly after -1. This is also a forward note for CIVO-070: its Certificates must sit at a wave strictly greater than cert-manager's (0), not both at wave 0 as this section's original text assumed.

## 5. Files/components affected

The new file above; `gitops/values.yaml`; the monitors gating in CIVO-160.

## 6. Implementation steps

1. Add the Application. The golden aws diff is empty (gated off).
2. Render civo. Run `PROVIDER=civo make argo-up`. Check that `kubectl get crd certificates.cert-manager.io` shows Established. Check that the webhook is ready.
3. Confirm the Gateway API feature flag. Create a throwaway `Issuer` with a `gatewayHTTPRoute` solver that references the platform Gateway. The dry-run must be accepted.

## 7. Dependencies and blockers

The CIVO-050 layout. This spec runs in parallel with CIVO-060.

## 8. Acceptance criteria

- On civo: the cert-manager pods are Ready. The CRDs are Established. The Gateway API solver is accepted.
- On aws: this spec adds no cert-manager objects to the AWS render (the pre-existing aws-load-balancer-controller cert-manager install is untouched). The golden diff is empty.

## 9. Validation

Offline: the golden diff and kubeconform. Real cloud: civo (~cents).

## 10. AWS regression protection

The chart is gated off by default. The golden diff protects AWS.

## 11. Rollout and rollback/recovery

Revert the change. Argo prunes the objects. There is no data risk.

## 12. Risks and unresolved questions

- The flag name for Gateway API support varies by chart version. Verify it at pin time.
- **Deviation from §4 (2026-09-09):** the civo cert-manager Application is gated on `target == "civo"` alone, not on the `certManager.enabled` value flag §4 describes. That flag had no genuine second position (civo always true, aws never reads it, local never wants it) and wiring it through `gitops/bootstrap/values.yaml`/`root-application.yaml`/`argo-up.sh` plus regenerating the bootstrap golden fixture was avoidable plumbing. The dead `certManager.enabled` key was removed from `gitops/values.yaml`.
- **Deviation from §4 (2026-09-09):** resource requests use aws's proven cert-manager values (10m cpu / 32Mi memory request, 64Mi memory limit per component) instead of §4's unexamined 50m/64Mi — the identical chart at the identical pinned version already runs at the lower values on aws with no stated reason for civo to need 5x the CPU request.
- **Open question, deferred (2026-09-09):** whether a missing-Gateway-API-CRD race at cert-manager's controller boot needs a PostSync restart hook (per CLAUDE.md's documented exception for "a consumer controller that wedges permanently after a single failed attempt and needs a pod restart") was deliberately left unbuilt pending live evidence — see this spec's execution evidence for the outcome.

## 13. Definition of done

- [ ] Evidence recorded; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-09 — dependency CIVO-050 confirmed DONE; started via subagent-driven development on branch `civo-065-cert-manager`; promoted to IN_PROGRESS.
