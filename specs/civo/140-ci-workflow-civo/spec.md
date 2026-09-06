---
id: "CIVO-140"
title: "lab.yml provider input, Civo token decrypt with masking, concurrency, cleanup-on-failure"
status: "READY"
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

The manual `lab` workflow can run any lifecycle target with `provider=civo`.
The workflow obtains the Civo token by decrypting `secrets/civo-token.enc`
with the same OIDC-assumed role it already uses. The workflow never prints
the token. Only one run per project-provider executes at a time. A
best-effort cleanup step runs on failure.

## 2. Scope and non-goals

In scope:

- `.github/workflows/lab.yml` inputs.
- The `civo` CLI install (pinned).
- The token step.
- Concurrency.
- The cleanup step.
- `provider` in `run-name`.

Not in scope: PR validation workflows (spec 019), Kind CI (spec 024).

## 3. Current state / evidence

- `lab.yml:11-42` defines the inputs `project_name` (single choice), `subdomain`, `target`, `confirm_destroy`. `:85-89` assumes the OIDC role. `:91-93` runs `make ${{ inputs.target }}`. The workflow has no `concurrency` and no `if: failure()`.
- `scripts/lib/provider.sh` `civo_token` prints `::add-mask::` under `GITHUB_ACTIONS` (CIVO-010).
- Constitution: no fork-PR trigger exists. The workflow uses `workflow_dispatch` only.

## 4. Design and contracts

- Inputs: `provider` is a choice of `aws|civo` (default `aws`). `project_name` is a choice of `vk-lab-platform|vk-civo-lab`. `subdomain` is a choice of `lab|civo`. A validation step fails if the provider and the project/subdomain disagree.
- Set `env: PROVIDER: ${{ inputs.provider }}`. The `run-name` includes the provider.
- Steps: install the `civo` CLI pinned with a checksum (like Terragrunt). The `make` step relies on scripts that call `civo_token`. No explicit token step is needed. A pre-step calls `civo_token >/dev/null` once, so the mask registers before any output.
- Set `concurrency: group: lab-${{ inputs.project_name }}-${{ inputs.provider }}` and `cancel-in-progress: false`.
- Cleanup: a step with `if: failure() && contains(fromJSON('["up","platform-up","full-up"]'), inputs.target)` runs `make down` with `CI_TEARDOWN_ALLOW_DATA_LOSS=1`. This prevents the fail-closed CNPG rule from CIVO-045/120 from leaving a billing cluster behind. If that step fails too, fall back to `make cluster-down` alone. Log the result.
- The `test` job has `needs: lifecycle` and the same provider env. It calls `civo_token` again first, because `::add-mask::` is per job. Then it runs `make test`.
- Emit the mask to the step's stdout directly. Never emit it inside a `$(...)` capture.
- Secrets: none added. `permissions` is unchanged.

## 5. Files/components affected

`.github/workflows/lab.yml`; docs `README.md` CI section.

## 6. Implementation steps

1. Edit the workflow. Run `actionlint`.
2. Dispatch `status` for aws (no change in behavior). Dispatch `status` for civo.
3. Dispatch `up`, then `down`, for civo. Inspect the logs for the masked token (`***`).
4. Force a failure (bad target env). Check that the cleanup step runs.

## 7. Dependencies and blockers

045 (scripts), 015 (ADR 0028).

## 8. Acceptance criteria

- The token is never visible in the logs. `set -x` is never enabled around it.
- Two simultaneous dispatches for the same project-provider queue.
- The cleanup step runs on failure of up-like targets.
- An AWS dispatch of `status`/`up`/`down` behaves as before.

## 9. Validation

Offline: `actionlint`. Real cloud: one civo up/down through CI (~0.3 USD), one aws `status`.

## 10. AWS regression protection

The default inputs reproduce today's behavior. Record one aws `status` run.

## 11. Rollout and rollback/recovery

Revert the workflow.

## 12. Risks and unresolved questions

- Masking covers only exact string matches. The token must not be transformed before masking.

## 13. Definition of done

- [ ] Evidence; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
