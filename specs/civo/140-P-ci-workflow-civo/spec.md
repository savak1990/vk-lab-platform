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
updated: "2026-09-18"
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

- Inputs: `provider` is a choice of `aws|civo` (default `aws`). `project_name`
  and `subdomain` are free-form strings whose blank default means "this
  provider's own default" — see deviation D1.
- Set `env: PROVIDER: ${{ inputs.provider }}`. The `run-name` includes the provider.
- Steps: install the `civo` CLI pinned with a checksum (like Terragrunt). The `make` step relies on scripts that call `civo_token`. No explicit token step is needed. A pre-step calls `civo_token >/dev/null` once, so the mask registers before any output.
- Set `concurrency: group: lab-${{ inputs.project_name }}-${{ inputs.provider }}` and `cancel-in-progress: false`.
- Cleanup: a step with `if: failure() && contains(fromJSON('["up","platform-up","full-up"]'), inputs.target)` runs `make down`. After `full-down` (success or failure) the same job deletes the project's TLS parameter, `aws ssm delete-parameter --name /${PROJECT_NAME}/persistent/civo/tls/platform-public`, ignoring `ParameterNotFound`: it survives teardown by design (ADR 0028) and a staging certificate is worthless to keep. This prevents the fail-closed CNPG rule from CIVO-045/120 from leaving a billing cluster behind. If that step fails too, fall back to `make cluster-down` alone. Log the result.
- The `test` job has `needs: lifecycle` and the same provider env. It calls `civo_token` again first, because `::add-mask::` is per job. Then it runs `make test`.
- Emit the mask to the step's stdout directly. Never emit it inside a `$(...)` capture.
- Secrets: none added. `permissions` is unchanged.
- **Public TLS issuer (from CIVO-070):** a civo `up`-like step sets
  `TLS_ISSUER` from the `production_tls` input — see deviation D3. When that
  input is unticked the step sets `TLS_ISSUER=letsencrypt-staging`. CI uses a fresh project per run, so the
  SSM-persisted certificate Secret never carries over and each run places a
  new ACME order for the same names. Let's Encrypt production allows 5
  duplicate certificates per name set per week and 50 per registered domain
  per week; that quota is shared with the personal lab, so a few retried
  pipelines would lock the real `argo.civo.<root-domain>` out of renewals
  for a week. Staging has ~30x the limits and exercises the same code path;
  tests must not require a browser-trusted chain (`curl -k`). The variable
  must be on the `make` step's environment: `argo-up.sh` relays it into the
  root Application only on a cold install, not on the idempotent fast path.
  The `test` job on civo sets `E2E_INSECURE_TLS=1` for the same reason: the
  suite's `--insecure-skip-tls-verify` flag (`tests/e2e/framework/config.go`)
  is the only way a Go client accepts the staging root. AWS runs and a
  prod-issuer civo run leave it unset so a certificate regression still fails.

## 4a. Deviations from §4, decided during implementation

- **D1 — `project_name` and `subdomain` are free-form, not `choice` pairs.**
  The spec predates main's move to a free-form `project_name` on `lab.yml`, and
  the outcome requires custom-named throwaway projects on both providers. A
  blank input is *omitted* from `$GITHUB_ENV` rather than exported empty,
  because an environment variable set to `""` still counts as defined for
  make's `?=` (measured: `origin` returns `environment`), which would defeat
  `Makefile:17-23`. The Makefile therefore stays the single source of the
  per-provider defaults.
- **D2 — the §4 "validation step fails if provider and project disagree" is
  narrowed.** With free-form names there is no closed set to compare against.
  The resolve step rejects only the realistic footgun: naming one provider's
  default project while running the other. Subdomain uniqueness is left to
  `scripts/require-unique-subdomain.sh`, which already decides it from live
  Route 53 state before any apply and is more accurate than a workflow rule.
- **D3 — `production_tls` replaces the unconditional staging rule.** §4 set
  `TLS_ISSUER=letsencrypt-staging` for every civo CI run. That would write a
  staging certificate into `vk-civo-lab`'s SSM-persisted Secret and degrade the
  personal lab. A boolean input, default on, keeps the default lab on
  production and lets a throwaway project opt into staging. The `test` job
  derives `E2E_INSECURE_TLS` from the same input.
- **D4 — the cleanup-on-failure step is not in this pass; the TLS-parameter
  delete that §4 bundled with it is.** Only the `if: failure()` bring-up
  recovery is deferred, to keep the diff reviewable. The other half of that
  bullet is independent of it and is implemented: `civo_export_tls_secret`
  writes `/<project>/persistent/civo/tls/platform-public` as an Advanced-tier
  SecureString on every `argo-down`, and CIVO-185's leak check confirmed it
  survives `full-down` by design, so a throwaway project would leave a billed
  parameter behind.
- **D8 — that delete is gated on `production_tls`, not unconditional.** §4
  reasoned from "CI uses a fresh project per run", which no longer holds now
  that `lab.yml` can drive the personal lab. Deleting the parameter for
  `vk-civo-lab` would throw away a valid production certificate and force a
  fresh ACME order on the next bring-up — the exact cost the export exists to
  avoid. Only a staging certificate is deleted; a production one is kept.
- **D5 — `dig` and `htpasswd` are installed, which §5 did not name.** Found
  during implementation: `scripts/generate-secrets.sh` calls `htpasswd` with no
  fallback whenever a project has no committed `argocd-admin-password.bcrypt`,
  and `scripts/argo-up.sh`'s DNS wait returns non-zero without `dig`. `full-up`
  was therefore broken for every project name except the two committed ones, on
  **both** providers — not a Civo-only gap.
- **D6 — `TARGET_REVISION` follows `github.ref_name`, which §2 did not scope.**
  `scripts/argo-up.sh` defaults it to the literal `main`, so a branch dispatch
  ran Terraform from the branch but reconciled `gitops/` from `main`. Included
  because it makes branch dispatch meaningful, which the operator asked for.
- **D7 — the mask step runs after `configure-aws-credentials`, and its stdout
  is not redirected.** The token is KMS ciphertext in the repository, so
  decrypting it needs the assumed role. §4 asks for `civo_token >/dev/null`,
  which contradicts §4's own next line: `civo_token` writes nothing but the
  `::add-mask::` directive, so redirecting stdout would discard the mask and
  leave the token unmasked. The step runs it unredirected; GitHub consumes the
  directive and prints nothing.

## 5. Files/components affected

`.github/workflows/lab.yml`; `.github/workflows/lifecycle-test.yml` (one stale
comment); `README.md` CI section; `docs/civo-high-level-design.md` §4.2 (the
CA's per-project lifetime, per D5's neighbouring finding).

## 6. Implementation steps

1. Edit the workflow. Run `actionlint`.
2. Dispatch `status` for aws (no change in behavior). Dispatch `status` for civo.
3. Dispatch `up`, then `down`, for civo. Inspect the logs for the masked token (`***`).
4. Force a failure (bad target env). Check that the cleanup step runs.

## 7. Dependencies and blockers

045 (scripts), 015 (ADR 0030).

## 8. Acceptance criteria

- The token is never visible in the logs. `set -x` is never enabled around it.
- Two simultaneous dispatches for the same project-provider queue.
- The cleanup step runs on failure of up-like targets.
- An AWS dispatch of `status`/`up`/`down` behaves as before.
- A civo `full-up` run shows `Certificate platform-public` `Ready` with `issuerRef.name: letsencrypt-staging`; no production order appears in the run.

## 9. Validation

Offline: `actionlint`, `yamllint -c .yamllint.yml`. Real cloud: one civo
up/down through CI (~0.3 USD), one aws `status`.

One runtime check has no offline equivalent: confirm on the first civo
bring-up's log that `TLS_ISSUER` resolved to `letsencrypt-prod`. The
`inputs.<name>` expression for a `type: boolean` input is boolean-typed, but the
legacy `github.event.inputs.<name>` path is string-typed, where `'false'` is
truthy — and a `status` dispatch never evaluates `TLS_ISSUER`. Read it off a
real bring-up before trusting an unticked (staging) run.

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
- 2026-09-18 — implemented on branch `civo-140-ci-provider`. Deviations D1–D7
  recorded in §4a. Offline validation: `actionlint` clean on all three
  workflows; `yamllint -c .yamllint.yml` clean. The blank-input contract was
  measured rather than assumed — `PROVIDER=civo` with `PROJECT_NAME` unset
  resolves to `vk-civo-lab`/`civo`/`cluster-civo`, and with `PROJECT_NAME`
  exported empty it resolves to an empty project name, which is why the resolve
  step omits blanks.
- 2026-09-18 — smoke dispatches from the branch, both green.
  - aws `status` (run 35336573884): resolve step set `PROVIDER=aws` and left
    `PROJECT_NAME` out of the environment, so the Makefile default applied;
    `TARGET_REVISION=civo-140-ci-provider` confirms the branch reaches Argo's
    root Application, and `TLS_ISSUER=letsencrypt-prod` confirms the ticked
    default.
  - civo `status` with `production_tls` unticked (run 35340501502): every step
    green, `TLS_ISSUER=letsencrypt-staging`. The input is genuinely
    boolean-typed in both directions, which the §9 runtime check asked for.
  - Token masking verified by hashing, never by printing: the decrypted token
    is 50 characters, and no 20-plus-character run anywhere in that run's log
    hashes to it. The mask step itself emits no visible output, as expected -
    GitHub consumes the directive.
  - One bug found and fixed by the first civo dispatch (run 35337042103):
    `sha256sum -c` matches the filename recorded in the checksum line, so
    downloading the archive under a different name made the check fail open
    rather than verify. The step body now runs verbatim against both releases.
- Live lifecycle evidence pending.
