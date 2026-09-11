---
id: "CIVO-070"
title: "Public TLS at Envoy with Let's Encrypt HTTP-01 and Secret persistence across down/up"
status: "DONE"
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
updated: "2026-09-11"
completed: "2026-09-11"
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
- **Correction (2026-09-09, from CIVO-060):** CIVO-060 shipped Civo with an HTTP:80-only Gateway listener; no HTTPS:443 listener exists yet, and the civo branch of `shared/envoy-gateway/gateway.yaml` is a literal template block, not values-driven. This spec must add the HTTPS:443 listener itself (a template change) alongside its `certificateRefs`, not just set a value on an existing listener. cert-manager has the Gateway API solver since CIVO-065. The DNS records exist since CIVO-110 (HTTP-01 needs the hostname to resolve to the LB).
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

`gitops/templates/platform/civo/tls/{issuers,certificate}.yaml`; `shared/envoy-gateway/gateway.yaml` (adds the HTTPS:443 listener - see correction above); `gitops/values.yaml`; `scripts/argo-up.sh`; `scripts/argo-down.sh`.

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

- [x] Evidence for staging and prod; down/up without new order
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-11 — implemented via subagent-driven-development (plan
  `docs/superpowers/plans/2026-09-10-civo-070-letsencrypt-tls.md`) and
  verified on `vk-civo-lab`. Closed as DONE.
  - Objects: `civo/tls/{issuers,certificate,redirect}.yaml`; HTTPS:443
    listener in the civo branch of `shared/envoy-gateway/gateway.yaml`;
    Secret export in `argo-down` and import in `argo-up`
    (`scripts/lib/provider.sh`), SSM `SecureString`, Advanced tier,
    `alias/lab-secrets`. `tls.issuer`/`tls.acmeEmail` relayed through the
    bootstrap chart.
  - Blocker found first, not in this spec's scope: a cold civo `full-up`
    deadlocked at root wave 0. gitops-engine never re-applies a `SyncFailed`
    task while the operation is `Running`, and wave 0 could not settle
    because `ClusterSecretStore`/`ExternalSecret` waited for ESO's pod, which
    waits for the wave-1 identity Certificate. Fixed by wave ordering
    (ESO consumers 2, aws Cluster 3, this Certificate 3); ADR 0025 amended.
  - Ruling: app `HTTPRoute`s bind to the `https` listener (`sectionName`);
    without it their hostname match beat the redirect on port 80.
  - Ruling: the import guard reads the leaf's expiry from `tls.crt`;
    cert-manager keeps `notAfter`/`renewalTime` on the Certificate, not the
    Secret.
  - Staging evidence: `Certificate platform-public` `Ready`; issuer
    `(STAGING) Artificial Amaranth YE1`; `Order` `valid`; DNS resolved to
    the Gateway address; `http://` → `301` to `https://`.
  - Down/up evidence: `argo-down` exported the Secret; `argo-up` logged
    `restored platform-public-tls Secret from SSM`; the served serial was
    unchanged (`2CFB2E35…A62E`); `kubectl get order -A` empty; all
    `cert-manager.io/*` annotations round-tripped. Rate-limit math: one
    order per issuance, none per cycle; ≤ 1 prod order per week under
    normal use, renewal at day 60.
  - Prod evidence: default issuer `letsencrypt-prod`; issuer `CN=YE1`,
    serial `0652E7BE…59C4`, `notAfter 2026-12-10T05:07:15Z`; `curl` without
    `-k` returns 200 (`ssl_verify=0`); one prod `Order`; the login API
    returns 401 for a wrong password. Browser login deferred by the user:
    the civo admin hash had been generated with a random password
    (commit 6021b98) and was replaced (commit 5b4e367); the SSM parameter
    updates on the next `persistent-up`.
  - Note: `argo-up`'s fast path skips the `root-application` Helm upgrade on
    a healthy cluster, so `TLS_ISSUER` overrides apply on a cold `argo-up`
    only. Recorded in CIVO-140 §4.
  - Follow-up: CIVO-075 (wildcard through DNS-01) created READY.
  - Cluster torn down afterwards (`full-down`), no leaks.
  - Post-closure fix (same day): the first prod `make down` failed in
    `argo-down` — the exported manifest was 15354 chars, over the Advanced
    tier's 8192, because the earlier client-side `kubectl apply` import had
    stamped a `last-applied-configuration` annotation holding a full copy
    of the Secret. Export now strips that annotation, import uses
    server-side apply, and a failed export is a warning (one extra order)
    rather than an aborted teardown. Stored size with a two-certificate
    prod chain: 7390 chars, ~10% headroom — CIVO-075 must re-check this
    with the wildcard chain.
