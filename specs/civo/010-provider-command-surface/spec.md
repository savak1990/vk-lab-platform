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

`make <target> PROVIDER=civo` selects the Civo project directories and the Civo stack directories.
`make <target>` with no `PROVIDER` behaves exactly as it does today.
This variable is the single operator seam that every later spec uses.
For this reason, this spec lands first and alone.

## 2. Scope and non-goals

In scope: `Makefile`, a new `scripts/lib/provider.sh`, the `civo_token`
helper, and a `make -n` golden proof.
Not in scope: any Civo Terraform, the script branches that need a Civo cluster (CIVO-040/045), and CI (CIVO-140).

## 3. Current state / evidence

- `Makefile:10` `export PROJECT_NAME ?= vk-lab-platform`; `:17` `export SUBDOMAIN ?= lab`; `:14` `REGION := eu-west-1` unexported.
- `Makefile:107` and `:125` hardcode `cd terraform/live/persistent` and `cd terraform/live/cluster`.
- `Makefile:140-143,159-162` run `aws eks update-kubeconfig`.
- No `PROVIDER`, `TARGET`, or `ENV` variable exists. `scripts/lib/region.sh:5` is the model for a small sourced lib.
- Spec 027 proposed a `TARGET` variable. This spec uses `PROVIDER` because the user decided so (HLD §6).
- `secrets/civo-token.enc` is tracked. It is KMS ciphertext at the account level and a sibling of `secrets/root-domain.enc`. `.gitignore` already admits it.

## 4. Design and contracts

- `Makefile`: `export PROVIDER ?= aws`. When `PROVIDER=civo`: `PROJECT_NAME ?= vk-civo-lab`, `SUBDOMAIN ?= civo`. Put the Make conditional before the existing `?=` lines so that explicit overrides still win. Validate `PROVIDER` ∈ {aws, civo} in a guard target. Every lifecycle target depends on that guard target.
- Stack directory variables: `CLUSTER_DIR = cluster` (aws) or `cluster-civo` (civo); `PERSISTENT_EXTRA_DIR = persistent-civo` (civo only); `BOOTSTRAP_EXCLUDE = acm` and `PERSISTENT_EXCLUDE = vpc` for civo. This spec introduces only the variables. CIVO-025/030 wire the Terraform dirs.
- `scripts/lib/provider.sh` *(new)*: exports `PROVIDER` (default aws), the same defaults for project/subdomain, and `CLUSTER_DIR`. It also defines the function `civo_token()`. The function runs `scripts/secret-decrypt.sh civo-token`. When `GITHUB_ACTIONS` is set, the function prints `::add-mask::<value>` to stdout. Then the function exports `CIVO_TOKEN`. In all other cases, the function never echoes the token.
- `scripts/secret-decrypt.sh` already resolves names outside a project folder for `root-domain`. Extend that rule to `civo-token` (repo-root `secrets/civo-token.enc`). Apply the same extension to `secret-encrypt.sh`.
- The kubeconfig targets (`eks-kubeconfig`, `test-kubeconfig`) dispatch on `PROVIDER`. The civo branch is a stub. The stub errors with "implemented in CIVO-040" until that spec lands.
- Decision links: HLD §2 (operator surface, project identity), §6 (PROVIDER as operator input).

## 5. Files/components affected

- `Makefile` (edit): variables, the guard target, `CLUSTER_DIR` use at `:125`, a persistent target wiring placeholder, and kubeconfig dispatch.
- `scripts/lib/provider.sh` (new).
- `scripts/secret-decrypt.sh`, `scripts/secret-encrypt.sh` (edit): the `civo-token` path rule.
- `secrets/README.md` (edit): document `civo-token.enc`.
- No Terraform, GitOps, or CI changes. No state impact.

## 6. Implementation steps

1. Add the `PROVIDER` block and validation to `Makefile`. Keep the `PROJECT_NAME`/`SUBDOMAIN` defaults for aws untouched.
2. Replace the literal `cluster` in `Makefile:125` with `$(CLUSTER_DIR)`. Replace the equivalent literal in `scripts/cluster-down.sh` in the same way. For aws, the variable expands to `cluster`.
3. Create `scripts/lib/provider.sh`. Source it from the `scripts/lib/region.sh` consumers only where a later spec needs it (CIVO-040). This spec only adds the file and a shellcheck run.
4. Extend the secret path rule for `civo-token`.
5. Record golden outputs for `make -n up`, `make -n down`, `make -n full-up`, and `make -n persistent-up` before and after the change. The diff must be empty for aws.
6. Add the `make -n up PROVIDER=civo` expectations to the spec evidence. The output expands to `cluster-civo` paths and shows the kubeconfig stub.

## 7. Dependencies and blockers

None. Parallel work is allowed on CIVO-015, CIVO-020, and CIVO-050 (050 only touches `gitops/`).

## 8. Acceptance criteria

- `make -n <t>` for `up`, `down`, `platform-up`, `platform-down`, `full-up`, `full-down`, `status`, `test`, `argo-up`, `argo-down`, `cluster-up`, `cluster-down`, `persistent-up`, `persistent-down` is byte-identical to the baseline when `PROVIDER` is unset or `aws`.
- `make up PROVIDER=gcp` fails fast with a clear message. Nothing else runs.
- `PROVIDER=civo make -n cluster-up` shows `terraform/live/cluster-civo`. `PROJECT_NAME` resolves to `vk-civo-lab` and `SUBDOMAIN` resolves to `civo` unless the operator overrides them.
- `PROVIDER=civo PROJECT_NAME=other make -n cluster-up` keeps `other`.
- `scripts/lib/provider.sh` passes `shellcheck`. `civo_token` prints the mask line only under `GITHUB_ACTIONS`.
- `scripts/secret-decrypt.sh civo-token` reads `secrets/civo-token.enc`. Verify this with a dry path check. Print no plaintext in the evidence.

## 9. Validation

Offline: `make -n ...` diffs (script in `scratch/` or `tests/manual/civo-010.md`), `shellcheck scripts/lib/provider.sh scripts/secret-*.sh`.
Real cloud: none required. Optional: run `aws kms decrypt` on `civo-token.enc` on a workstation to prove the path rule. Do not paste the output.
Cost: 0.

## 10. AWS regression protection

The golden `make -n` diff is the gate. This spec does not change the scripts for aws behavior.
`CLUSTER_DIR` expands to the same literal. `lab.yml` is untouched.

## 11. Rollout and rollback/recovery

One PR. A revert restores the previous Makefile. There is no state or data risk.

## 12. Risks and unresolved questions

- The Make conditional order with `?=` and environment-exported variables is a risk. Test both `PROVIDER=civo make` and `make PROVIDER=civo`.
- The `secret-decrypt.sh` name resolution rule must not break `root-domain`.

## 13. Definition of done

- [ ] Acceptance criteria met with recorded diffs
- [ ] `shellcheck` clean
- [ ] `secrets/README.md` updated
- [ ] PR merged; index row updated; status `DONE` with date

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — plan approved by the user; no hard dependencies; promoted to READY.
