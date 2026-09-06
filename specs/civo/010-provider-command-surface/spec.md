---
id: "CIVO-010"
title: "PROVIDER operator input with Civo project defaults and Make dispatch"
status: "READY"
priority: "P1"
milestone: "M0"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Bounded Makefile and shell changes with a byte-identical AWS path; the main risk is subtle default handling, which a standard tier handles with the listed tests"
effort_estimate: "One focused session (2–4 h) including the AWS no-op proof"
estimate_confidence: "high"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-010 — PROVIDER operator input and Make dispatch

## 1. Outcome and rationale

`make <target> PROVIDER=civo` selects the Civo project and stack
directories; `make <target>` with no `PROVIDER` behaves exactly as today.
This is the single operator seam every later spec hangs off, so it lands
first and alone.

## 2. Scope and non-goals

In scope: `Makefile`, a new `scripts/lib/provider.sh`, the `civo_token`
helper, and a `make -n` golden proof. Not in scope: any Civo Terraform,
script branches that need a Civo cluster (CIVO-040/045), CI (CIVO-140).

## 3. Current state / evidence

- `Makefile:10` `export PROJECT_NAME ?= vk-lab-platform`; `:17` `export SUBDOMAIN ?= lab`; `:14` `REGION := eu-west-1` unexported.
- `Makefile:107` and `:125` hardcode `cd terraform/live/persistent` and `cd terraform/live/cluster`.
- `Makefile:140-143,159-162` run `aws eks update-kubeconfig`.
- No `PROVIDER`, `TARGET`, or `ENV` variable exists; `scripts/lib/region.sh:5` is the model for a tiny sourced lib.
- Spec 027 proposed a `TARGET` variable; this spec uses `PROVIDER` per the user's decision (HLD §6).
- `secrets/civo-token.enc` is tracked (KMS ciphertext, account-level, sibling of `secrets/root-domain.enc`); `.gitignore` already admits it.

## 4. Design and contracts

- `Makefile`: `export PROVIDER ?= aws`. When `PROVIDER=civo`: `PROJECT_NAME ?= vk-civo-lab`, `SUBDOMAIN ?= civo` (Make conditional before the existing `?=` lines so explicit overrides still win). Validate `PROVIDER` ∈ {aws, civo} in a guard target that every lifecycle target depends on.
- Stack directory variables: `CLUSTER_DIR = cluster` (aws) or `cluster-civo` (civo); `PERSISTENT_EXTRA_DIR = persistent-civo` (civo only); `BOOTSTRAP_EXCLUDE = acm` and `PERSISTENT_EXCLUDE = vpc` for civo. Only the variables are introduced here; CIVO-025/030 wire the Terraform dirs.
- `scripts/lib/provider.sh` *(new)*: exports `PROVIDER` (default aws), the same defaults for project/subdomain, `CLUSTER_DIR`, and function `civo_token()` that runs `scripts/secret-decrypt.sh civo-token`, prints `::add-mask::<value>` to stdout when `GITHUB_ACTIONS` is set, then exports `CIVO_TOKEN`. Never echoes the token otherwise.
- `scripts/secret-decrypt.sh` already resolves names outside a project folder for `root-domain`; extend that rule to `civo-token` (repo-root `secrets/civo-token.enc`). Same for `secret-encrypt.sh`.
- Kubeconfig targets (`eks-kubeconfig`, `test-kubeconfig`) dispatch on `PROVIDER`; the civo branch is a stub that errors "implemented in CIVO-040" until then.
- Decision links: HLD §2 (operator surface, project identity), §6 (PROVIDER as operator input).

## 5. Files/components affected

- `Makefile` (edit): variables, guard target, `CLUSTER_DIR` use at `:125`, persistent target wiring placeholder, kubeconfig dispatch.
- `scripts/lib/provider.sh` (new).
- `scripts/secret-decrypt.sh`, `scripts/secret-encrypt.sh` (edit): `civo-token` path rule.
- `secrets/README.md` (edit): document `civo-token.enc`.
- No Terraform, GitOps, or CI changes. No state impact.

## 6. Implementation steps

1. Add `PROVIDER` block and validation to `Makefile`; keep `PROJECT_NAME`/`SUBDOMAIN` defaults for aws untouched.
2. Replace the literal `cluster` in `Makefile:125` and `scripts/cluster-down.sh`'s equivalent with `$(CLUSTER_DIR)`; for aws it expands to `cluster`.
3. Create `scripts/lib/provider.sh`; source it from `scripts/lib/region.sh` consumers only where needed later (CIVO-040). This spec only adds the file and a shellcheck run.
4. Extend the secret path rule for `civo-token`.
5. Record golden outputs: `make -n up`, `make -n down`, `make -n full-up`, `make -n persistent-up` before and after; diff must be empty for aws.
6. Add `make -n up PROVIDER=civo` expectations to the spec evidence (expands to `cluster-civo` paths; kubeconfig stub).

## 7. Dependencies and blockers

None. Parallel work allowed: CIVO-015, CIVO-020, CIVO-050 (050 only touches `gitops/`).

## 8. Acceptance criteria

- `make -n <t>` for `up`, `down`, `platform-up`, `platform-down`, `full-up`, `full-down`, `status`, `test`, `argo-up`, `argo-down`, `cluster-up`, `cluster-down`, `persistent-up`, `persistent-down` is byte-identical to baseline when `PROVIDER` is unset or `aws`.
- `make up PROVIDER=gcp` fails fast with a clear message; nothing else runs.
- `PROVIDER=civo make -n cluster-up` shows `terraform/live/cluster-civo`; `PROJECT_NAME` resolves to `vk-civo-lab` and `SUBDOMAIN` to `civo` unless overridden.
- `PROVIDER=civo PROJECT_NAME=other make -n cluster-up` keeps `other`.
- `scripts/lib/provider.sh` passes `shellcheck`; `civo_token` prints the mask line only under `GITHUB_ACTIONS`.
- `scripts/secret-decrypt.sh civo-token` reads `secrets/civo-token.enc` (verified with a dry path check; no plaintext printed in evidence).

## 9. Validation

Offline: `make -n ...` diffs (script in `scratch/` or `tests/manual/civo-010.md`), `shellcheck scripts/lib/provider.sh scripts/secret-*.sh`.
Real cloud: none required. Optional: `aws kms decrypt` of `civo-token.enc` on a workstation to prove the path rule; do not paste output.
Cost: 0.

## 10. AWS regression protection

The golden `make -n` diff is the gate. Scripts are not changed for aws
behavior; `CLUSTER_DIR` expands to the same literal. `lab.yml` is untouched.

## 11. Rollout and rollback/recovery

Single PR; revert restores the previous Makefile. No state or data risk.

## 12. Risks and unresolved questions

- Make conditional ordering with `?=` and environment-exported variables; test both `PROVIDER=civo make` and `make PROVIDER=civo`.
- `secret-decrypt.sh` name resolution rule must not break `root-domain`.

## 13. Definition of done

- [ ] Acceptance criteria met with recorded diffs
- [ ] `shellcheck` clean
- [ ] `secrets/README.md` updated
- [ ] PR merged; index row updated; status `DONE` with date

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — plan approved by the user; no hard dependencies; promoted to READY.
