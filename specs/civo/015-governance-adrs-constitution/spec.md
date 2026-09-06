---
id: "CIVO-015"
title: "Governance: ADRs 0025–0028, constitution §20, architecture §10a, documentation fixes"
status: "READY"
priority: "P0"
milestone: "M0"
type: "documentation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Cross-document consistency with accepted ADRs and security trade-offs (identity blast radius, token handling) needs careful reasoning"
effort_estimate: "One session (3–5 h) of writing and cross-checking"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-015 — Governance and documentation base

## 1. Outcome and rationale

Accepted decisions exist for every rule the Civo target bends, and the
architecture document is factually current, so implementation specs do not
silently bypass ADR 0011, 0013, 0019, 0022, 0023, constitution §3/§8/§14/§16/§19, or invariant 4.

## 2. Scope and non-goals

In scope: four new ADRs, constitution §20, `architecture.md` §10a plus the
staleness fixes in `docs/architecture-review-2026-09-06.md`, `CLAUDE.md`
lines, `README.md` Kafka line, `terraform/live/persistent/README.md`, spec
027 status. Not in scope: code, the CA design details (CIVO-080), tests.

## 3. Current state / evidence

- ADR 0011 `docs/adr/0011-nlb-acm-public-edge.md`: "no cert-manager, no Let's Encrypt", with the LE duplicate-certificate rate limit as a reason.
- Constitution `specs/000-constitution/spec.md` §18 is the `local` carve-out; §3, §16, invariant 4 are AWS-scoped by text.
- `docs/architecture.md` §10a describes two targets and a `values-<target>.yaml` layout that does not exist; other stale items listed in the review document.
- Spec 027 is research-only with four Open Questions.

## 4. Design and contracts

ADR contents (Status: Proposed until merged):

- **0025 Civo second execution target under a separate project.** `PROVIDER` operator input; project `vk-civo-lab`, subdomain `civo`; identical stage model; separate state bucket; `persistent-civo`/`cluster-civo` stack dirs; lifecycle classes apply to the Civo cluster as Disposable; account layer shared. Supersedes spec 027's `TARGET` proposal.
- **0026 Envoy-terminated TLS with cert-manager on Civo.** Answers ADR 0011's reasons: rate limit mitigated by persisting the TLS Secret across down/up (SSM SecureString) and LE staging in CI; no ACM/NLB on Civo; invariant 10 gets a Civo variant. ADR 0011 unchanged for AWS.
- **0027 IAM Roles Anywhere with an offline CA.** Trust anchor from external CA; single CA in M1; CN-conditioned trust policies; helper sidecar; explicit blast radius: `lab-role` `kms:*` on `alias/lab-secrets` and `CIVO_TOKEN` → cluster-admin → CA key Secret → every role; mitigations and the intermediate-CA follow-up (CIVO-200).
- **0028 Civo API token handling.** Static key, KMS-encrypted at `secrets/civo-token.enc`, decrypted at run time, masked in CI, rotation by regenerate + re-encrypt + commit; invariant 4 text (AWS credentials) not violated, principle acknowledged; JWT exchange evaluated and rejected as still key-dependent.

Constitution §20 "Civo execution target": per-section variants for §3
(Civo cluster is Disposable; Civo network/reserved IP Persistent; Roles
Anywhere Bootstrap), §5 (workload identity via Roles Anywhere; token rule),
§8 (LB → Envoy TLS), §14 (zone `civo.<root-domain>`, no ACM), §16 (Civo
`tags` best-effort), §17 (same command pairs), §19 (fork steps add API key
encryption and CA ceremony).

`architecture.md`: add a "Current state vs target state" note at the top
pointing to `docs/aws-platform-design.md`, `docs/argocd-design.md`,
`docs/civo-high-level-design.md`; extend §10a to three targets; apply the
12 fixes from the review table.

## 5. Files/components affected

- `docs/adr/0025-…md`, `0026-…md`, `0027-…md`, `0028-…md` (new).
- `specs/000-constitution/spec.md` (§20 added; §18 untouched).
- `docs/architecture.md` (§10a, §5 tree, Kafka/Tempo/Secrets Manager/argocd-bootstrap fixes).
- `CLAUDE.md` (project purpose line, lifecycle list VPC line, repository layout, workload identity line).
- `README.md` (implemented-stack sentence), `terraform/live/persistent/README.md`.
- `specs/027-alt-cloud-targets/spec.md` (add `**Status:** Superseded by specs/civo/`).

## 6. Implementation steps

1. Write ADRs 0025–0028 using the existing ADR format (`# ADR NNNN: Title` / Status / Context / Decision / Consequences).
2. Add constitution §20; cross-reference each variant to the ADR.
3. Apply the review-table fixes to `architecture.md`; keep target-state sections, label deferred items.
4. Update `CLAUDE.md`, `README.md`, persistent README, spec 027 status.
5. Run a link check (`grep -o '\[.*\](.*\.md)'` targets exist) and `markdownlint` if available.

## 7. Dependencies and blockers

None. Parallel: CIVO-010, CIVO-020.

## 8. Acceptance criteria

- Each ADR names the exact rule it varies and the AWS rule it leaves intact.
- Constitution §20 is a variant list, not an exemption; §3, §4, §7, §17 explicitly still apply to Civo.
- No document claims Kafka, Tempo, Secrets Manager runtime secrets, or a Terraform Argo bootstrap as current.
- `architecture.md` §5 tree matches `ls -R gitops terraform/live`.
- Spec 027 marked superseded with a link.

## 9. Validation

Offline only: link check, `git diff --stat` limited to docs, review by the
user. No cloud. Cost 0.

## 10. AWS regression protection

Documentation only; ADR 0011/0013/0019/0022/0023 remain accepted for AWS.

## 11. Rollout and rollback/recovery

One PR; revertible.

## 12. Risks and unresolved questions

- The user may want a different ADR numbering if other ADRs land first; renumber before merge.
- Constitution §20 wording on tagging parity must not over-promise Civo tag support.

## 13. Definition of done

- [ ] Four ADRs merged with Status Accepted
- [ ] Constitution §20 merged
- [ ] Review-table fixes applied
- [ ] Index row updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — plan approved by the user; no hard dependencies; promoted to READY.
