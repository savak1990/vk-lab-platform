---
id: "CIVO-200"
title: "Identity hardening: per-cluster intermediate CA and Certificate approval policy"
status: "DRAFT"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Changes the trust chain and adds an admission-time authorization boundary"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["CIVO-085"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-200 — Identity hardening

## 1. Outcome and rationale

The root CA key never enters the cluster: `argo-up` issues a short-lived
intermediate per cluster and the trust anchor stays the root. A
cert-manager approval policy restricts which namespaces may request which
CNs. Together they bound the blast radius of a `CIVO_TOKEN` compromise
(ADR 0027) in time and in scope.

## 2. Scope and non-goals

In scope: intermediate issuance in `argo-up` (using the decrypted root key
in memory, 30-day validity, `pathlen:0`), `--intermediates` chain for the
helper, approver-policy install and `CertificateRequestPolicy` objects,
CRL note. Not in scope: HSM, OCSP.

## 3. Current state / evidence

CIVO-085 places the root key in a Secret; Roles Anywhere validates chains
to the anchor and accepts intermediates via the helper's `--intermediates`.

## 4. Design and contracts

- `argo-up`: generate intermediate key in-cluster? No: generate the pair in memory on the operator/CI side, sign with the root, create the Secret with intermediate key+cert; root key is discarded from memory after signing.
- Helper sidecar args add `--intermediates /ra/ca.crt` (cert-manager writes `ca.crt` for CA issuers).
- approver-policy: `CertificateRequestPolicy` allowing CN `<project>-civo-eso` only from namespace `external-secrets`, etc.; default deny.
- Rotation: intermediate renewed on every `argo-up` if under 7 days left; runbook.

## 5. Files/components affected

`scripts/argo-up.sh`, `gitops/templates/platform/civo/identity/*`, `gitops/templates/shared/cert-manager/approver-policy.yaml`, helper template.

## 6. Implementation steps

1. Intermediate issuance and chain; positive/negative tests from CIVO-090 rerun.
2. approver-policy; negative: Certificate with a foreign CN in the wrong namespace is denied.

## 7. Dependencies and blockers

085.

## 8. Acceptance criteria

- Root key absent from the cluster (`kubectl get secret` shows only the intermediate).
- Roles Anywhere accepts the chain; denies a cert signed by an expired intermediate.
- Policy denies out-of-namespace CNs.

## 9. Validation

Real cloud, cents.

## 10. AWS regression protection

Civo-only.

## 11. Rollout and rollback/recovery

Revert to the single-CA issuer.

## 12. Risks and unresolved questions

- approver-policy version compatibility with the pinned cert-manager.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
