---
id: "CIVO-065"
title: "cert-manager installed behind a toggle, off on AWS"
status: "DRAFT"
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
updated: "2026-09-06"
completed: null
---

# CIVO-065 — cert-manager install

## 1. Outcome and rationale

cert-manager runs on the Civo target (Gateway API HTTP-01 solver enabled)
and is absent on AWS unless `certManager.enabled=true`. Both CIVO-070
(public TLS) and CIVO-085 (workload identity certificates) need it, so it
is its own small slice.

## 2. Scope and non-goals

In scope: the Application, CRDs, namespace, wave, ServiceMonitor gating.
Not in scope: issuers and certificates (CIVO-070, CIVO-085).

## 3. Current state / evidence

No cert-manager objects exist in `gitops/` (verified negative). ADR 0011
rejects cert-manager for AWS; CIVO-015's ADR 0026 allows it on Civo.

## 4. Design and contracts

- `gitops/templates/platform/shared/cert-manager/application.yaml` gated by `{{- if .Values.certManager.enabled }}`; chart `cert-manager` from `https://charts.jetstack.io`, version pinned at implementation (latest 1.x); `crds.enabled: true`; `config.enableGatewayAPI: true` (or the flag name for the pinned version); `ServerSideApply=true`; wave -2 (before ESO/consumers, after Envoy chart CRDs at -1? — cert-manager must be Established before Certificates at wave 0; place at -3 and note that Gateway API CRDs come from Envoy Gateway at -1, so the HTTP-01 Gateway solver only needs the CRD at runtime, not at install).
- Resources: requests 50m/64Mi per component.
- `certManager.enabled` default false; civo values true.

## 5. Files/components affected

New file above; `gitops/values.yaml`; monitors gating in CIVO-160.

## 6. Implementation steps

1. Add Application; golden aws diff empty (gated off).
2. Render civo; `PROVIDER=civo make argo-up`; `kubectl get crd certificates.cert-manager.io` Established; webhook ready.
3. Confirm the Gateway API feature flag by creating a throwaway `Issuer` with a `gatewayHTTPRoute` solver referencing the platform Gateway (dry-run accepted).

## 7. Dependencies and blockers

CIVO-050 layout. Parallel with CIVO-060.

## 8. Acceptance criteria

- On civo: cert-manager pods Ready; CRDs Established; Gateway API solver accepted.
- On aws: no cert-manager objects; golden diff empty.

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: civo (~cents).

## 10. AWS regression protection

Gated off by default; golden diff.

## 11. Rollout and rollback/recovery

Revert; Argo prunes. No data risk.

## 12. Risks and unresolved questions

- Flag name for Gateway API support varies by chart version; verify at pin time.

## 13. Definition of done

- [ ] Evidence recorded; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
