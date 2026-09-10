---
id: "CIVO-205"
title: "lab-role and civo in-cluster RBAC least-privilege review"
status: "DRAFT"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "IAM permission boundaries define blast radius; narrowing them wrong is a security regression, not just a style issue"
effort_estimate: "Unestimated (design not yet resolved)"
estimate_confidence: "low"
depends_on: ["CIVO-082", "CIVO-085", "CIVO-200"]
blocked_by: []
supersedes: []
created: "2026-09-09"
updated: "2026-09-10"
completed: null
---

# CIVO-205 — lab-role and civo in-cluster RBAC least-privilege review

## 1. Outcome and rationale

`lab-role` (`terraform/modules/lab-role/main.tf`) is the single AWS
automation identity, assumed via GitHub OIDC, that runs Terraform for both
providers. CIVO-082 adds Civo/Roles-Anywhere-management statements to this
same role (`rolesanywhere:Create*` etc. on the account's Roles Anywhere
ARNs, `iam:PassRole` scoped to `role/*-ra-*`, SSM paths under
`*/persistent-civo/*`, `*/cluster-civo/*`, `*/bootstrap/rolesanywhere/*`)
rather than creating a dedicated Civo operator role — a deliberate M1
choice (recorded in this session's conversation, 2026-09-09) made because
Civo's own compute is provisioned entirely outside AWS IAM (via
`CIVO_TOKEN`, ADR 0030), so the actual AWS-side surface Civo needs is
already narrow, and a second OIDC-trust-bound role would add real
complexity (which role does `lab.yml` assume, for what) for an
uncertain blast-radius benefit.

This spec is the deferred follow-up: revisit that call once the accreted
statement set is real, not hypothetical (post CIVO-082, and ideally post
CIVO-200, since CIVO-200 changes `x509Issuer/CN` trust-policy conditions
and may itself add or remove statements). Decide, with the actual final
policy document in front of it, whether `lab-role` remains one role or
splits — and if it splits, along what boundary (provider? blast-radius
tier, mirroring ADR 0022's precedent for `eks-access-identity`?).

A second, distinct surface was folded in from CIVO-085's final review
(2026-09-10): the External Secrets Operator's own `ClusterRole`
(Kubernetes RBAC, not AWS IAM — a separate axis from `lab-role`'s AWS
permissions) grants cluster-wide `get`/`list`/`watch`/`create`/`update`/
`delete`/`patch` on Secrets in every namespace, not just the ones ESO
actually manages. This means the ESO controller can read
`cert-manager/civo-workload-ca` — the Roles Anywhere CA's private key,
introduced by CIVO-085 — directly, and mint a certificate for any CN,
bypassing the per-consumer CN scoping CIVO-082/085 otherwise establish.
CIVO-200's Certificate-approval policy does not close this path (it
gates who may get a `Certificate` approved, not who may read the Secret
holding the CA key). This is now documented as a known, accepted M1 risk
in `specs/civo/085-workload-certificate-issuance/spec.md` §4 and
`docs/adr/0029-rolesanywhere-offline-ca.md`; this spec is where the
actual fix — scoping ESO's RBAC — should land.

## 2. Scope and non-goals

In scope: reviewing the accreted `lab-role` policy document for
over-broad statements (Civo-related and, opportunistically, any AWS-side
statements found stale during the review); a decision, with rationale,
on whether to split the role; if splitting, the Terraform/OIDC-trust/
`lab.yml` changes that follow. Also in scope: scoping External Secrets
Operator's `ClusterRole` (via its Helm chart's `scopedNamespace`/
`scopedRBAC` support) so it can no longer read Secrets outside the
namespaces it actually manages, closing the CA-key-read path described
in §1.

Not in scope: workload-facing IAM roles (`${project}-ra-*`, already
narrowly scoped per-consumer by CIVO-082's own design) — those are not
what "less privileged" refers to here. Also not in scope: the
Certificate-approval policy itself (CIVO-200) — this spec assumes
CIVO-200 exists and explicitly does not rely on it to close the ESO
finding above.

## 3. Current state / evidence

Not yet gathered for the `lab-role` half — this spec is a DRAFT
placeholder capturing the decision to defer, not a resolved design. An
implementer should re-read the actual `lab-role` policy document as it
stands after CIVO-082 (and CIVO-200, if done) land, not this spec's own
description of it, since both will have changed it further by the time
this is picked up.

For the ESO half, live evidence already exists (2026-09-10, against the
`vk-civo-lab` Civo cluster, torn down after CIVO-085's testing but
recreatable): `kubectl auth can-i get secrets -n cert-manager
--as=system:serviceaccount:external-secrets:external-secrets` → `yes`.
`external-secrets-controller`'s `ClusterRole` is the upstream chart's
own default (installed via
`gitops/templates/platform/shared/external-secrets/application.yaml`,
unrelated to and predating CIVO-085) — this is not a CIVO-085-introduced
regression, just a pre-existing over-broad grant that CIVO-085's CA
Secret made newly consequential.

## 4. Design and contracts

Unresolved for `lab-role`. Candidate directions to evaluate, not a
decision:

- Leave as one role (status quo) if the accreted Civo statements remain
  genuinely narrow relative to the AWS-side statements already present.
- Split by provider (`lab-role` for AWS-only statements, a new
  `civo-lab-role` for Civo-related statements), accepting the added
  OIDC-trust/`lab.yml` complexity this session's conversation flagged as
  the cost of splitting.
- Split by blast-radius tier instead of provider (e.g., isolate
  `kms:*`-shaped statements from narrowly-scoped ones), if that boundary
  turns out to matter more than the provider boundary.

For the ESO `ClusterRole`, the direction is more settled (this is a
narrowing, not an open design question): apply the chart's
`scopedNamespace`/`scopedRBAC` values so ESO's Role/RoleBinding are
namespace-scoped instead of cluster-scoped, covering only the
namespaces it must actually read from (at minimum `external-secrets`
itself and wherever `SecretStore`-backed Secrets are consumed) — and
explicitly NOT `cert-manager`. Verify AWS is unaffected (ESO is a
`platform/shared/` component, used by both targets) before landing this,
per §10.

## 5. Files/components affected

`terraform/modules/lab-role/main.tf`; possibly `terraform/live/account/lab-role`,
`.github/workflows/lab.yml`, `terraform/modules/github-oidc-trust` if a
split is chosen. Also
`gitops/templates/platform/shared/external-secrets/application.yaml`
(the `scopedNamespace`/`scopedRBAC` Helm values).

## 6. Implementation steps

Unresolved for `lab-role` — depends on the direction chosen in §4. For
ESO: add the scoping values to the chart's Helm values, verify the
AWS-target golden diff renders identically or with an intentional,
documented change, verify live (`kubectl auth can-i get secrets -n
cert-manager --as=system:serviceaccount:external-secrets:external-secrets`
→ `no`), verify ESO's actual `SecretStore` functionality still works on
both targets after the scoping change.

## 7. Dependencies and blockers

CIVO-082 (the `lab-role` statements to review must exist first). CIVO-085
(the ESO/CA-Secret finding this spec now also covers). CIVO-200 (changes
the trust-policy CN condition and may itself touch `lab-role`) — soft
dependency for the `lab-role` half, review after both land rather than
after CIVO-082 alone, so the review isn't immediately stale. The ESO
scoping half has no dependency on CIVO-200 and could be picked up
independently/earlier if desired.

## 8. Acceptance criteria

For `lab-role`: unresolved — depends on the direction chosen in §4. For
ESO: `kubectl auth can-i get secrets -n cert-manager
--as=system:serviceaccount:external-secrets:external-secrets` returns
`no`; ESO's existing `SecretStore`-backed functionality (Postgres/Grafana
password sync from AWS Secrets Manager) still works on both AWS and
Civo after the change; the AWS-target golden diff shows only the
intended scoping change, nothing else.

## 9. Validation

Unresolved.

## 10. AWS regression protection

Any split must leave the AWS-only workflow's `lab-role` assumption and
permissions unchanged in behavior — a regression here would affect every
AWS operation, not just Civo's.

## 11. Rollout and rollback/recovery

Unresolved — depends on the direction chosen in §4.

## 12. Risks and unresolved questions

- Whether narrowing scope is worth the operational complexity of a second
  automation identity is itself the open question this spec exists to
  answer — see §1.
- ESO's `scopedNamespace`/`scopedRBAC` config may require the
  `SecretStore`/`ClusterSecretStore` objects it serves to also be
  reachable within the scoped namespace set — verify this doesn't break
  the AWS-target usage (Postgres/Grafana password sync) before landing.

## 13. Definition of done

- [ ] Design resolved (§4); reviewed; evidence recorded; index updated;
  status `DONE` — covering both the `lab-role` review and the ESO
  `ClusterRole` scoping.

## 14. Execution evidence and status history

- 2026-09-09 — created as DRAFT, capturing a deferred decision from the
  CIVO-080 planning conversation: keep `lab-role` as the single operator
  identity for now (CIVO-082 adds statements to it), but track a
  follow-up review of whether that should change once the real statement
  set exists.
- 2026-09-10 — folded in a second finding from CIVO-085's final
  whole-branch review, at the user's explicit request: ESO's
  pre-existing, cluster-wide-Secret-read `ClusterRole` can read the
  Roles Anywhere CA private key directly (`cert-manager/civo-workload-ca`),
  bypassing per-consumer CN scoping. Verified live
  (`kubectl auth can-i get secrets -n cert-manager
  --as=system:serviceaccount:external-secrets:external-secrets` → `yes`)
  against `vk-civo-lab`. Documented as a known, accepted M1 risk in
  `specs/civo/085-workload-certificate-issuance/spec.md` §4 and
  `docs/adr/0029-rolesanywhere-offline-ca.md`; this spec now also owns
  the actual fix (ESO RBAC scoping), still DRAFT pending user review.
