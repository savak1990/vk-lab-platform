---
id: "CIVO-070"
title: "Public TLS at Envoy with Let's Encrypt HTTP-01 and Secret persistence across down/up"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Standard cert-manager pattern; the persistence step and rate-limit handling need care but are specified"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-060", "CIVO-065", "CIVO-110"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-070 — Let's Encrypt TLS at Envoy

## 1. Outcome and rationale

`https://argo.civo.<root-domain>` and `https://grafana.civo.<root-domain>`
serve a valid Let's Encrypt certificate terminated at Envoy Gateway. The
certificate Secret survives `make down`/`make up` so repeated cycles do not
hit Let's Encrypt's duplicate-certificate limit (ADR 0011's objection).

## 2. Scope and non-goals

In scope: `ClusterIssuer`s (staging, production), `Certificate` for the
two hosts, HTTPS listener wiring, HTTP→HTTPS redirect, Secret export/import
in `argo-down`/`argo-up`. Not in scope: workload identity certs (CIVO-085),
DNS-01.

## 3. Current state / evidence

- ADR 0011 reasons: 5 duplicate certificates per week limit under CI up/down cycles; no Secret persistence bridge.
- Gateway listeners values-driven since CIVO-060; cert-manager with Gateway API solver since CIVO-065; DNS records since CIVO-110 (HTTP-01 needs the hostname to resolve to the LB).
- SSM `SecureString` pattern exists (`modules/persistent-secrets`, `argo-up.sh:41-54` reads with decryption).

## 4. Design and contracts

- `gitops/templates/platform/civo/tls/issuers.yaml`: `ClusterIssuer letsencrypt-staging` and `letsencrypt-prod`, ACME HTTP-01 solver `gatewayHTTPRoute` with `parentRefs` to `platform-gateway` (namespace `envoy`), account email from values (non-secret).
- `Certificate platform-public` in namespace `envoy`: `dnsNames: [argo.<fqdn>, grafana.<fqdn>]`, `secretName: platform-public-tls`, issuer from `.Values.tls.issuer` (staging in CI, prod on the workstation), `privateKey.rotationPolicy: Always`.
- Gateway HTTPS listener `certificateRefs: [platform-public-tls]`; HTTP listener keeps the ACME solver route and an `HTTPRoute` redirect filter for everything else.
- Persistence: `argo-down` civo branch exports `platform-public-tls` (`tls.crt`, `tls.key`) to SSM SecureString `/${project}/persistent/civo/tls/platform-public` (KMS `alias/lab-secrets`) before the cascade; `argo-up` civo branch re-creates the Secret from SSM before installing the root Application when present and not expired within 15 days. cert-manager adopts an existing Secret whose key matches and renews on schedule instead of ordering. The Secret is untracked by Argo (`argocd.argoproj.io/sync-options: Prune=false` is not needed since Argo never owns it).
- `lab-role` and the operator already have KMS and SSM permissions under `*/persistent/*`.

## 5. Files/components affected

`gitops/templates/platform/civo/tls/{issuers,certificate}.yaml`, `shared/envoy-gateway/gateway.yaml` (listener certificateRefs by values), `gitops/values.yaml`, `scripts/argo-up.sh`, `scripts/argo-down.sh`.

## 6. Implementation steps

1. Add issuers and Certificate with staging issuer; `PROVIDER=civo make up`; Certificate `Ready`; curl with `--insecure` shows staging issuer.
2. Add export/import to scripts; `make down`, `make up`; Certificate `Ready` without a new Order (check `kubectl get order` empty and cert serial unchanged).
3. Switch to prod on the workstation; browser check.
4. Record the LE rate-limit math in evidence: prod orders per week ≤ 1 under normal cycles.

## 7. Dependencies and blockers

060 (listeners), 065 (cert-manager), 110 (DNS resolves for HTTP-01).

## 8. Acceptance criteria

- `curl https://argo.civo.<root-domain>` succeeds with a trusted chain (prod) or a staging chain (CI).
- HTTP on 80 redirects to HTTPS except `/.well-known/acme-challenge/*`.
- Down/up cycle: no new ACME order; Secret restored; serial unchanged.
- SSM parameter is `SecureString`; no key material in Argo, Git, or logs.
- AWS: golden diff empty; no cert-manager or issuers on AWS.

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: two civo cycles (~0.3 USD). Staging issuer only in automated runs.

## 10. AWS regression protection

All objects under `civo/`; listener changes for aws render identical (golden).

## 11. Rollout and rollback/recovery

Revert; delete the SSM parameter to force a fresh order. Data risk: none.

## 12. Risks and unresolved questions

- HTTP-01 through Gateway API requires the ACME route to win over the redirect route; order by path precedence, verify.
- Secret re-import before cert-manager starts is fine; cert-manager reconciles on start.

## 13. Definition of done

- [ ] Evidence for staging and prod; down/up without new order
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
