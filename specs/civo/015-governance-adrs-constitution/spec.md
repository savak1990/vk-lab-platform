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

An accepted decision exists for every rule that the Civo target bends. The
architecture document is factually current. As a result, the implementation
specs do not silently bypass ADR 0011, 0013, 0019, 0022, 0023, constitution
§3/§8/§14/§16/§19, or invariant 4.

## 2. Scope and non-goals

The scope includes these items:

- four new ADRs;
- constitution §20;
- `architecture.md` §10a;
- the staleness fixes in `docs/architecture-review-2026-09-06.md`;
- the `CLAUDE.md` lines;
- the `README.md` Kafka line;
- `terraform/live/persistent/README.md`;
- the spec 027 status.

The scope does not include code, the CA design details (CIVO-080), or tests.

## 3. Current state / evidence

- ADR 0011 `docs/adr/0011-nlb-acm-public-edge.md` says "no cert-manager, no Let's Encrypt". It gives the LE duplicate-certificate rate limit as a reason.
- Constitution `specs/000-constitution/spec.md` §18 is the `local` carve-out. The text of §3, §16, and invariant 4 applies to AWS only.
- `docs/architecture.md` §10a describes two targets. It also describes a `values-<target>.yaml` layout that does not exist. The review document lists the other stale items.
- Spec 027 is research-only. It has four Open Questions.

## 4. Design and contracts

Each ADR has the status Proposed until the PR merges. The ADR contents are:

- **0025 Civo second execution target under a separate project.** The operator gives the `PROVIDER` input. The project is `vk-civo-lab`. The subdomain is `civo`. The stage model is identical. The state bucket is separate. The stack directories are `persistent-civo`/`cluster-civo`. The lifecycle classes apply to the Civo cluster as Disposable. The account layer is shared. This ADR supersedes the `TARGET` proposal of spec 027.
- **0026 Envoy-terminated TLS with cert-manager on Civo.** This ADR answers the reasons of ADR 0011. The platform persists the TLS Secret across down/up (SSM SecureString). CI uses LE staging. Together these two measures mitigate the rate limit. Civo has no ACM and no NLB. Invariant 10 gets a Civo variant. ADR 0011 stays unchanged for AWS.
- **0027 IAM Roles Anywhere with an offline CA.** The trust anchor comes from an external CA. M1 uses a single CA. The trust policies are CN-conditioned. A helper sidecar provides the credentials. The ADR states the blast radius explicitly: `lab-role` `kms:*` on `alias/lab-secrets` and `CIVO_TOKEN` → cluster-admin → CA key Secret → every role. The ADR lists the mitigations and the intermediate-CA follow-up (CIVO-200).
- **0028 Civo API token handling.** The token is a static key. KMS encrypts it at `secrets/civo-token.enc`. Scripts decrypt it at run time. CI masks it. To rotate the token, regenerate it, re-encrypt it, and commit the file. The invariant 4 text (AWS credentials) is not violated. The ADR acknowledges the principle. The ADR evaluates a JWT exchange and rejects it, because it still depends on a key.
- **0029 Logical dumps to S3 as the single PostgreSQL backup mechanism.** Replaces ADR 0013's EBS VolumeSnapshot recovery on both targets. Civo cannot snapshot or clone volumes, and CNPG offers no way to add a sidecar to its instance pods, so physical backups from Civo would need a permanent AWS key. A dump job from an image this repository owns uses `credential_process` on Civo and Pod Identity on AWS. States the accepted loss of point-in-time recovery and the retention window. AWS migrates in CIVO-185, not in M1.

Constitution §20 "Civo execution target" gives a variant for each of these sections:

- §3: the Civo cluster is Disposable; the Civo network/reserved IP is Persistent; Roles Anywhere is Bootstrap;
- §5: workload identity uses Roles Anywhere; the token rule applies;
- §8: LB → Envoy TLS;
- §14: the zone is `civo.<root-domain>`; there is no ACM;
- §16: Civo `tags` are best-effort;
- §17: the same command pairs apply;
- §19: the fork steps add API key encryption and the CA ceremony.

For `architecture.md`, do these three changes:

1. Add a "Current state vs target state" note at the top. The note points to `docs/aws-platform-design.md`, `docs/argocd-design.md`, and `docs/civo-high-level-design.md`.
2. Extend §10a to three targets.
3. Apply the 12 fixes from the review table.

## 5. Files/components affected

- `docs/adr/0025-…md`, `0026-…md`, `0027-…md`, `0028-…md`, `0029-…md` (new).
- `specs/000-constitution/spec.md` (add §20; do not change §18).
- `docs/architecture.md` (§10a, the §5 tree, and the Kafka/Tempo/Secrets Manager/argocd-bootstrap fixes).
- `CLAUDE.md` (the project purpose line, the VPC line in the lifecycle list, the repository layout, and the workload identity line).
- `README.md` (the implemented-stack sentence), `terraform/live/persistent/README.md`.
- `specs/027-alt-cloud-targets/spec.md` (add `**Status:** Superseded by specs/civo/`).

## 6. Implementation steps

1. Write ADRs 0025–0028 in the existing ADR format (`# ADR NNNN: Title` / Status / Context / Decision / Consequences).
2. Add constitution §20. Cross-reference each variant to its ADR.
3. Apply the review-table fixes to `architecture.md`. Keep the target-state sections. Label the deferred items.
4. Update `CLAUDE.md`, `README.md`, the persistent README, and the spec 027 status.
5. Run a link check (`grep -o '\[.*\](.*\.md)'` targets exist). Run `markdownlint` if it is available.

## 7. Dependencies and blockers

There are no dependencies or blockers. CIVO-010 and CIVO-020 can run in parallel.

## 8. Acceptance criteria

- Each ADR names the exact rule that it varies. Each ADR names the AWS rule that it leaves intact.
- Constitution §20 is a variant list, not an exemption. It states explicitly that §3, §4, §7, and §17 still apply to Civo.
- No document claims that Kafka, Tempo, Secrets Manager runtime secrets, or a Terraform Argo bootstrap are current.
- The `architecture.md` §5 tree matches the output of `ls -R gitops terraform/live`.
- Spec 027 is marked superseded, with a link.

## 9. Validation

The validation is offline only. It consists of a link check, a `git diff --stat` limited to docs, and a review by the user. It uses no cloud. The cost is 0.

## 10. AWS regression protection

This spec changes documentation only. ADR 0011/0013/0019/0022/0023 remain accepted for AWS.

## 11. Rollout and rollback/recovery

The work lands in one PR. The PR is revertible.

## 12. Risks and unresolved questions

- The user may want different ADR numbers if other ADRs land first. Renumber the ADRs before the merge.
- The constitution §20 wording on tagging parity must not over-promise Civo tag support.

## 13. Definition of done

- [ ] Four ADRs merged with Status Accepted
- [ ] Constitution §20 merged
- [ ] Review-table fixes applied
- [ ] Index row updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — plan approved by the user; no hard dependencies; promoted to READY.
