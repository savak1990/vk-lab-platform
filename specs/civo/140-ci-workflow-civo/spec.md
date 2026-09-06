---
id: "CIVO-140"
title: "lab.yml provider input, Civo token decrypt with masking, concurrency, cleanup-on-failure"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Workflow changes with a clear security checklist"
effort_estimate: "One session (3–4 h) plus one CI run per provider"
estimate_confidence: "medium"
depends_on: ["CIVO-045", "CIVO-015"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-140 — CI workflow for Civo

## 1. Outcome and rationale

The manual `lab` workflow can run any lifecycle target with
`provider=civo`, obtaining the Civo token by decrypting `secrets/civo-token.enc`
with the same OIDC-assumed role it already uses, never printing it, with
one run per project-provider at a time and a best-effort cleanup step on
failure.

## 2. Scope and non-goals

In scope: `.github/workflows/lab.yml` inputs, `civo` CLI install (pinned),
token step, concurrency, cleanup step, `provider` in `run-name`. Not in
scope: PR validation workflows (spec 019), Kind CI (spec 024).

## 3. Current state / evidence

- `lab.yml:11-42` inputs `project_name` (single choice), `subdomain`, `target`, `confirm_destroy`; `:85-89` OIDC role; `:91-93` `make ${{ inputs.target }}`; no `concurrency`, no `if: failure()`.
- `scripts/lib/provider.sh` `civo_token` prints `::add-mask::` under `GITHUB_ACTIONS` (CIVO-010).
- Constitution: no fork-PR trigger exists; `workflow_dispatch` only.

## 4. Design and contracts

- Inputs: `provider` choice `aws|civo` (default `aws`); `project_name` choices `vk-lab-platform|vk-civo-lab`; `subdomain` choices `lab|civo`. Validation step fails if provider and project/subdomain disagree.
- `env: PROVIDER: ${{ inputs.provider }}`; `run-name` includes provider.
- Steps: install `civo` CLI pinned with checksum (like Terragrunt); the `make` step relies on scripts calling `civo_token`; no explicit token step is needed, but a pre-step calls `civo_token >/dev/null` once so the mask registers before any output.
- `concurrency: group: lab-${{ inputs.project_name }}-${{ inputs.provider }}`, `cancel-in-progress: false`.
- Cleanup: `if: failure() && contains(fromJSON('["up","platform-up","full-up"]'), inputs.target)` → `make down` with the same env (best effort, logged).
- `test` job: `needs: lifecycle`, same provider env; `make test`.
- Secrets: none added; `permissions` unchanged.

## 5. Files/components affected

`.github/workflows/lab.yml`; docs `README.md` CI section.

## 6. Implementation steps

1. Edit workflow; `actionlint`.
2. Dispatch `status` for aws (no change in behavior) and for civo.
3. Dispatch `up` then `down` for civo; inspect logs for masked token (`***`).
4. Force a failure (bad target env) to see cleanup run.

## 7. Dependencies and blockers

045 (scripts), 015 (ADR 0028).

## 8. Acceptance criteria

- Token never visible in logs; `set -x` never enabled around it.
- Two simultaneous dispatches for the same project-provider queue.
- Cleanup step runs on failure of up-like targets.
- AWS dispatch of `status`/`up`/`down` behaves as before.

## 9. Validation

Offline: `actionlint`. Real cloud: one civo up/down via CI (~0.3 USD), aws `status`.

## 10. AWS regression protection

Default inputs reproduce today's behavior; recorded aws `status` run.

## 11. Rollout and rollback/recovery

Revert the workflow.

## 12. Risks and unresolved questions

- Masking only covers exact string matches; the token must not be transformed before masking.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
