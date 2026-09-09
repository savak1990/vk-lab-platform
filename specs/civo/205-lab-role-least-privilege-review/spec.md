---
id: "CIVO-205"
title: "lab-role least-privilege review for civo-related statements"
status: "DRAFT"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "IAM permission boundaries define blast radius; narrowing them wrong is a security regression, not just a style issue"
effort_estimate: "Unestimated (design not yet resolved)"
estimate_confidence: "low"
depends_on: ["CIVO-082", "CIVO-200"]
blocked_by: []
supersedes: []
created: "2026-09-09"
updated: "2026-09-09"
completed: null
---

# CIVO-205 — lab-role least-privilege review

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

## 2. Scope and non-goals

In scope: reviewing the accreted `lab-role` policy document for
over-broad statements (Civo-related and, opportunistically, any AWS-side
statements found stale during the review); a decision, with rationale,
on whether to split the role; if splitting, the Terraform/OIDC-trust/
`lab.yml` changes that follow.

Not in scope: workload-facing IAM roles (`${project}-ra-*`, already
narrowly scoped per-consumer by CIVO-082's own design) — those are not
what "less privileged" refers to here.

## 3. Current state / evidence

Not yet gathered — this spec is a DRAFT placeholder capturing the
decision to defer, not a resolved design. An implementer should re-read
the actual `lab-role` policy document as it stands after CIVO-082 (and
CIVO-200, if done) land, not this spec's own description of it, since
both will have changed it further by the time this is picked up.

## 4. Design and contracts

Unresolved. Candidate directions to evaluate, not a decision:

- Leave as one role (status quo) if the accreted Civo statements remain
  genuinely narrow relative to the AWS-side statements already present.
- Split by provider (`lab-role` for AWS-only statements, a new
  `civo-lab-role` for Civo-related statements), accepting the added
  OIDC-trust/`lab.yml` complexity this session's conversation flagged as
  the cost of splitting.
- Split by blast-radius tier instead of provider (e.g., isolate
  `kms:*`-shaped statements from narrowly-scoped ones), if that boundary
  turns out to matter more than the provider boundary.

## 5. Files/components affected

`terraform/modules/lab-role/main.tf`; possibly `terraform/live/account/lab-role`,
`.github/workflows/lab.yml`, `terraform/modules/github-oidc-trust` if a
split is chosen.

## 6. Implementation steps

Unresolved — depends on the direction chosen in §4.

## 7. Dependencies and blockers

CIVO-082 (the statements to review must exist first). CIVO-200 (changes
the trust-policy CN condition and may itself touch `lab-role`) — soft
dependency, review after both land rather than after CIVO-082 alone, so
the review isn't immediately stale.

## 8. Acceptance criteria

Unresolved — depends on the direction chosen in §4.

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

## 13. Definition of done

- [ ] Design resolved (§4); reviewed; evidence recorded; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-09 — created as DRAFT, capturing a deferred decision from the
  CIVO-080 planning conversation: keep `lab-role` as the single operator
  identity for now (CIVO-082 adds statements to it), but track a
  follow-up review of whether that should change once the real statement
  set exists.
