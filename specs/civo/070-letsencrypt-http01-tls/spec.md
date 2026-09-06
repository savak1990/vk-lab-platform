---
id: "CIVO-070"
title: "Public TLS at Envoy with Let's Encrypt HTTP-01 and Secret persistence across down/up"
status: "READY"
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
serve a valid Let's Encrypt certificate. Envoy Gateway terminates the
certificate. The certificate Secret survives `make down`/`make up`.
Because of this, repeated cycles do not hit Let's Encrypt's
duplicate-certificate limit (ADR 0011's objection).

## 2. Scope and non-goals

In scope:

- the `ClusterIssuer`s (staging, production);
- the `Certificate` for the two hosts;
- the HTTPS listener wiring;
- the HTTP→HTTPS redirect;
- the Secret export/import in `argo-down`/`argo-up`.

Not in scope: the workload identity certs (CIVO-085) and DNS-01.

## 3. Current state / evidence

- ADR 0011 gives two reasons. The limit is 5 duplicate certificates per week under CI up/down cycles. No Secret persistence bridge existed.
- The Gateway listeners are values-driven since CIVO-060. cert-manager has the Gateway API solver since CIVO-065. The DNS records exist since CIVO-110 (HTTP-01 needs the hostname to resolve to the LB).
- The SSM `SecureString` pattern exists (`modules/persistent-secrets`; `argo-up.sh:41-54` reads with decryption).

## 4. Design and contracts

- `gitops/templates/platform/civo/tls/issuers.yaml` holds `ClusterIssuer letsencrypt-staging` and `letsencrypt-prod`. Each uses the ACME HTTP-01 solver `gatewayHTTPRoute` with `parentRefs` to `platform-gateway` (namespace `envoy`). The account email comes from values (non-secret).
- `Certificate platform-public` lives in namespace `envoy`. It sets `dnsNames: [argo.<fqdn>, grafana.<fqdn>]` and `secretName: platform-public-tls`. The issuer comes from `.Values.tls.issuer` (staging in CI, prod on the workstation). It sets `privateKey: {algorithm: ECDSA, size: 256, rotationPolicy: Always}`. ECDSA is a standard Let's Encrypt key type, not a workaround. It keeps the stored manifest far below the parameter size limit and shortens the TLS handshake.
- The Gateway HTTPS listener sets `certificateRefs: [platform-public-tls]`. The HTTP listener keeps the ACME solver route. It also keeps an `HTTPRoute` redirect filter for everything else.
- Persistence: `argo-down` exports the whole Secret, not its fields. Before the cascade, the Civo branch runs `kubectl get secret platform-public-tls -n envoy -o yaml`, strips `resourceVersion`, `uid`, `creationTimestamp` and `managedFields`, and writes the result to one SSM `SecureString` parameter, `/${project}/persistent/civo/tls/platform-public`, encrypted with `alias/lab-secrets`. The parameter uses the Advanced tier (8 KB, 0.05 USD per month) so that the size never becomes a design constraint.
- Exporting the whole manifest carries the `cert-manager.io/*` annotations by construction. This matters: cert-manager reissues when the Secret's `issuer-name`, `issuer-kind` or `issuer-group` annotations do not match `issuerRef`, or when the stored key does not match the Certificate spec. The `IncorrectIssuer`, `SecretPrivateKeyMismatchesSpec` and `SecretPublicKeysDiffer` policy checks each trigger a new ACME order. Paying for a larger parameter does not prevent this; only the round-trip of the annotations does.
- `argo-up` restores the Secret before it installs the root Application. It reads the parameter and pipes the manifest into `kubectl apply -f -`. It restores only when the parameter exists and the certificate has not passed its renewal time. Argo never tracks this Secret.

- `lab-role` and the operator already have KMS and SSM permissions under `*/persistent/*`.

**Review amendments (2026-09-06, kubernetes-architect):**
- Import guard: re-import the Secret only when the certificate's renewal time (`renewBefore`, default two thirds of the 90-day duration) has not passed. A cert past its renewal time triggers an order on import; count it against the 5-per-week duplicate limit.
- Export and restore the Secret as one manifest so that the certificate, the key and the annotations always come from the same issuance. Splitting them risks a `SecretPublicKeysDiffer` reissue.
- Restore the Secret before the `Certificate` exists (cert-manager backup guidance), which the `argo-up` ordering already guarantees.
- Set `cert-manager.io/issue-temporary-certificate: "true"` on the `Certificate` so the HTTPS listener resolves during the first order (see CIVO-060 amendment).
- The redirect `HTTPRoute` must carry no path match; the ACME solver route's exact match `/.well-known/acme-challenge/<token>` then wins by Gateway API precedence.

## 5. Files/components affected

`gitops/templates/platform/civo/tls/{issuers,certificate}.yaml`; `shared/envoy-gateway/gateway.yaml` (the listener certificateRefs come from values); `gitops/values.yaml`; `scripts/argo-up.sh`; `scripts/argo-down.sh`.

## 6. Implementation steps

1. Add the issuers and the Certificate with the staging issuer. Run `PROVIDER=civo make up`. Check that the Certificate is `Ready`. Check that curl with `--insecure` shows the staging issuer.
2. Add the export/import to the scripts. Run `make down`, then `make up`. Check that the Certificate is `Ready` without a new Order. To check this, confirm that `kubectl get order` is empty and the cert serial is unchanged.
3. Switch to prod on the workstation. Check in a browser.
4. Record the LE rate-limit math in the evidence. Under normal cycles, prod orders per week are ≤ 1.

## 7. Dependencies and blockers

This spec depends on 060 (listeners), 065 (cert-manager), and 110 (DNS resolves for HTTP-01).

## 8. Acceptance criteria

- `curl https://argo.civo.<root-domain>` succeeds with a trusted chain (prod) or a staging chain (CI).
- HTTP on port 80 redirects to HTTPS, except `/.well-known/acme-challenge/*`.
- A down/up cycle creates no new ACME order (`kubectl get order -A` is empty; the `CertificateRequest` count is unchanged). The Secret is restored with its annotations. The serial is unchanged.
- The stored manifest round-trips exactly. The restored Secret carries the same `cert-manager.io/*` annotations and the same key as the export.
- The SSM parameter is `SecureString`. No key material appears in Argo, Git, or logs.
- AWS: the golden diff is empty. No cert-manager or issuers exist on AWS.

## 9. Validation

Offline: the golden diff and kubeconform. Real cloud: two civo cycles (~0.3 USD). Automated runs use the staging issuer only.

## 10. AWS regression protection

All objects are under `civo/`. The listener changes render identically for aws (golden).

## 11. Rollout and rollback/recovery

Revert the change. Delete the SSM parameter to force a fresh order. Data risk: none.

## 12. Risks and unresolved questions

- HTTP-01 through Gateway API requires the ACME route to win over the redirect route. Order the routes by path precedence. Verify this.
- A Secret re-import before cert-manager starts is fine. cert-manager reconciles on start.

## 13. Definition of done

- [ ] Evidence for staging and prod; down/up without new order
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
