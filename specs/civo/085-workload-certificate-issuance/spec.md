---
id: "CIVO-085"
title: "Workload certificate issuance: CA issuer Secret at argo-up, per-consumer Certificates, RBAC, rotation"
status: "READY"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Authorization of who may obtain which identity is the core security property; mistakes grant AWS roles to arbitrary pods"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-045", "CIVO-050", "CIVO-065", "CIVO-080"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-085 — Workload certificate issuance

## 1. Outcome and rationale

Each Roles Anywhere consumer (ESO, ExternalDNS) receives a short-lived
certificate with a fixed CN from a cert-manager CA issuer whose key is the
project CA decrypted at `argo-up`. Only Argo-owned `Certificate` objects
can request those CNs; no pod can mint its own identity.

## 2. Scope and non-goals

In scope: the CA Secret ceremony in `argo-up`, `ClusterIssuer`,
`Certificate` objects, RBAC, rotation settings, negative tests. Not in
scope: the sidecar (CIVO-090), roles (CIVO-082), approver policy (CIVO-200).

## 3. Current state / evidence

- cert-manager installed on civo (CIVO-065). CA issuer type consumes a Secret with `tls.crt`/`tls.key` in the cert-manager namespace.
- `argo-up.sh` early-exit at `:151-158`; the CA Secret must be ensured before that check so re-runs repair it.
- Roles Anywhere requires end-entity `digitalSignature`, `CA:false`, X.509v3, SHA-256.

## 4. Design and contracts

- `argo-up` civo branch, before the fast path: `ensure_ca_secret()` decrypts `civo-ca-key` in memory and creates/updates Secret `civo-workload-ca` in namespace `cert-manager` (type `kubernetes.io/tls`, `tls.crt` from the committed PEM, `tls.key` from the decrypted value) using `kubectl create secret tls --dry-run=client -o yaml | kubectl apply -f -` through a pipe; never a temp file. Idempotent; label `app.kubernetes.io/managed-by: argo-up`.
- `gitops/templates/platform/civo/identity/issuer.yaml`: `ClusterIssuer civo-workload-ca` with `ca.secretName: civo-workload-ca`.
- `Certificate` per consumer in the consumer's namespace: `eso` in `external-secrets`, `external-dns` in `kube-system`: `commonName: <project>-civo-<consumer>`, `subject.organizations: [<project>]`, `usages: [digital signature]`, `isCA: false`, `duration: 24h`, `renewBefore: 8h`, `privateKey: {algorithm: ECDSA, size: 256, rotationPolicy: Always}`, `secretName: <consumer>-ra-cert`.
- RBAC: no human or workload ServiceAccount receives `create`/`update` on `certificates.cert-manager.io` or `certificaterequests`; the Argo controller is the only writer. Document that a namespace admin could still create a Certificate with a spoofed CN: mitigated in CIVO-200 with approver-policy; in M1 the cluster has no namespace admins other than the operator.
- Secret protection: consumer Secrets readable only by the consumer's ServiceAccount via the pod mount; no `get secrets` RoleBindings added.
- Mount pattern (used by CIVO-090): volume mount of the whole Secret, not `subPath`, so renewals propagate.

## 5. Files/components affected

`scripts/argo-up.sh`, `gitops/templates/platform/civo/identity/{issuer,certificates}.yaml`, `gitops/values.yaml` (consumer list).

## 6. Implementation steps

1. Add `ensure_ca_secret`; run `argo-up` twice; Secret present and unchanged.
2. Add issuer and Certificates; `kubectl get certificate -A` Ready; inspect a cert: CN, usages, `CA:false`, issuer CN.
3. Rotation: `cmctl renew` or wait; Secret updates; note the timestamp for CIVO-090's reload test.
4. Negative: apply a `Certificate` with CN `<project>-civo-eso` from a non-Argo identity with only default RBAC → forbidden; create one via Argo with a wrong issuer → issued by a different CA → Roles Anywhere denies (tested in CIVO-090).

## 7. Dependencies and blockers

045 (argo-up civo branch), 050 (`civo/` tree), 065 (cert-manager), 080 (files).

## 8. Acceptance criteria

- CA Secret exists only on civo; created before the root Application; never in Git or Argo.
- Two Certificates Ready with exact CN/usages; renewal observed.
- RBAC audit: `kubectl auth can-i create certificates.cert-manager.io --as=system:serviceaccount:default:default` = no.
- AWS unaffected (golden diff empty; no cert-manager on AWS).

## 9. Validation

Offline: golden diff, kubeconform. Real cloud: civo (~cents). No AWS.

## 10. AWS regression protection

All objects under `civo/`; script branch only for civo.

## 11. Rollout and rollback/recovery

Delete the CA Secret and Certificates; consumers lose AWS access (fail closed). Compromise response: disable trust anchor (CIVO-080 runbook), rotate CA.

## 12. Risks and unresolved questions

- cert-manager may refuse a CA cert without `keyCertSign`: covered by CIVO-080.
- Secret creation via pipe on macOS bash 3.2: verify.

## 13. Definition of done

- [ ] Evidence incl. RBAC check and rotation; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
