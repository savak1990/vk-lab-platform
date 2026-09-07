---
id: "CIVO-200"
title: "Identity hardening: per-cluster intermediate CA and Certificate approval policy"
status: "READY"
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

The root CA key never enters the cluster. `argo-up` issues a short-lived
intermediate per cluster (`pathlen:0`, allowed by the root's `pathlen:1`
from CIVO-080). The trust anchor stays the root. A cert-manager approval
policy restricts which namespaces may request which CNs. Together, they
bound the blast radius of a `CIVO_TOKEN` compromise (ADR 0029) in time and
in scope.

## 2. Scope and non-goals

In scope:

- Intermediate issuance in `argo-up` (using the decrypted root key in memory, 30-day validity, `pathlen:0`).
- The `--intermediates` chain for the helper.
- The approver-policy install and `CertificateRequestPolicy` objects.
- A CRL note.

Not in scope: HSM, OCSP.

## 3. Current state / evidence

CIVO-085 places the root key in a Secret. Roles Anywhere validates chains
to the anchor. It accepts intermediates through the helper's
`--intermediates`.

## 4. Design and contracts

- `argo-up` does not generate the intermediate key in-cluster. It generates the pair in memory on the operator/CI side. It signs the pair with the root. It creates the Secret with the intermediate key and cert. It discards the root key from memory after signing.
- The helper sidecar args add `--intermediates /ra/ca.crt`. cert-manager writes `ca.crt` for CA issuers.
- CIVO-082's trust-policy condition `x509Issuer/CN` must change from the root CN to the intermediate CN (`<project>-civo-workload-ica`). This is a Terraform variable. Apply it before the switch.
- approver-policy: a `CertificateRequestPolicy` allows the CN `<project>-civo-eso` only from the namespace `external-secrets`, with similar rules for the other consumers. The default is deny.
- Rotation: `argo-up` renews the intermediate on every run if under 7 days are left. Write a runbook.

## 5. Files/components affected

`scripts/argo-up.sh`, `gitops/templates/platform/civo/identity/*`, `gitops/templates/shared/cert-manager/approver-policy.yaml`, the helper template.

## 6. Implementation steps

1. Implement the intermediate issuance and the chain. Rerun the positive and negative tests from CIVO-090.
2. Install approver-policy. Run a negative test: a Certificate with a foreign CN in the wrong namespace is denied.

## 7. Dependencies and blockers

085.

## 8. Acceptance criteria

- The root key is absent from the cluster (`kubectl get secret` shows only the intermediate).
- Roles Anywhere accepts the chain. It denies a cert signed by an expired intermediate.
- The policy denies out-of-namespace CNs.

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
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
