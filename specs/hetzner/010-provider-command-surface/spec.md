---
id: "HETZ-010"
title: "PROVIDER=hetzner operator input with Hetzner project defaults, token helper, and Make dispatch"
status: "DRAFT"
priority: "P1"
milestone: "M0"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Bounded Makefile and shell changes that add a third value to an existing seam; the risk is byte-identity for the two existing providers, which the listed golden diffs catch"
effort_estimate: "One focused session (2–3 h) including the aws and civo no-op proofs"
estimate_confidence: "high"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-010 — PROVIDER=hetzner operator input and Make dispatch

## 1. Outcome and rationale

`make <target> PROVIDER=hetzner` selects the Hetzner project directories and
the Hetzner stack directories. `make <target>` with `PROVIDER` unset, `aws`,
or `civo` behaves exactly as it does today. The `hcloud_token()` helper is
the single place that decrypts the Hetzner API token. This spec lands first
and alone, as CIVO-010 did, because every later Hetzner spec uses the seam.

No Hetzner-only bootstrap target exists. The k3s bootstrap runs inside
`cluster-up` through cloud-init, and the readiness wait is part of the
`cluster-up` script (HETZ-040). The one Hetzner-only helper, `make node-ssh`,
lands in HETZ-040 and prints a message on the other providers.

## 2. Scope and non-goals

In scope: `Makefile`, `scripts/lib/provider.sh`, the `hcloud_token` and
`hcloud_cli` helpers, the secret path rule for `hcloud-token`, the
`test-kubeconfig` stub arm, the CIVO-186 `FROM`/`TO` enum, and a `make -n`
golden proof for `aws` and `civo`.
Not in scope: any Hetzner Terraform (HETZ-025/030), script branches that need
a Hetzner cluster (HETZ-040/045), CI (HETZ-140), and the generalisation
refactor (HETZ-016).

## 3. Current state / evidence

- `Makefile:9-11` exports `PROVIDER ?= aws` and fails at parse time unless `PROVIDER` is `aws` or `civo` (`filter aws civo`). The error text is asserted in CIVO-010 evidence.
- `Makefile:17-19` and `:31-33` set the civo defaults; `:128`, `:152`, `:182`, `:204` are `ifeq ($(PROVIDER),civo)` blocks for `persistent-up`, `cluster-up` (calls `civo_token`), `kubeconfig`, and the `test-kubeconfig` stub.
- `scripts/lib/provider.sh:10-27` mirrors the defaults; `:31-40` defines `civo_token()`; `:44-50` defines `civo_cli()` with a throwaway `CIVO_CONFIG` because the civo CLI writes the token to disk.
- `scripts/secret-decrypt.sh:15` and `scripts/secret-encrypt.sh:23` resolve `root-domain` and `civo-token` at the repo root instead of `secrets/<project>/`.
- `secrets/civo-token.enc` is tracked; `.gitignore` carries an explicit `!secrets/civo-token.enc` line.
- `research.md`: the Hetzner token is per project, Read or Read&Write, no scopes, no expiry, created in the Console. No API creates a project. The `hcloud` CLI is stateless when `HCLOUD_TOKEN` is set and writes no file unless `hcloud context create` runs.

## 4. Design and contracts

- `Makefile:10` guard becomes `filter aws civo hetzner`; the error text becomes "PROVIDER must be aws, civo or hetzner". Every other `ifeq ($(PROVIDER),civo)` block gains an `else ifeq ($(PROVIDER),hetzner)` arm. The aws and civo recipe text does not change by one byte.
- Defaults when `PROVIDER=hetzner`: `PROJECT_NAME ?= vk-hetzner-lab`, `SUBDOMAIN ?= hetzner`, `CLUSTER_DIR = cluster-hetzner`, `CLUSTER_NAME = $(PROJECT_NAME)`, `PERSISTENT_EXTRA_DIR = persistent-hetzner`, `BOOTSTRAP_EXCLUDE = acm`, `PERSISTENT_EXCLUDE = vpc`. `scripts/lib/provider.sh` exports the same values in a third branch. An explicit operator override always wins, as for civo.
- `hcloud_token()` in `provider.sh`: runs `scripts/secret-decrypt.sh hcloud-token`, prints `::add-mask::<value>` when `GITHUB_ACTIONS` is set, exports `HCLOUD_TOKEN`, and never echoes the token otherwise. The Terraform provider and the CLI read `HCLOUD_TOKEN`; the token never appears in tfvars, state, or arguments.
- `hcloud_cli()`: runs `hcloud "$@"` with `HCLOUD_TOKEN` exported. No config redirect is needed. Add `HCLOUD_CONFIG=/dev/null` anyway so that a stray `hcloud context` on an operator machine can never leak into a run.
- `hcloud_list_names()`: `hcloud <resource> list -o json -l project=<project>` piped through `jq -r '.[].name'`. Unlike the civo CLI, an empty result is `[]`, so no shape check is needed. HETZ-040 uses it.
- Secret path rule: `secret-decrypt.sh` and `secret-encrypt.sh` add `hcloud-token` to the repo-root list. `secrets/hcloud-token.enc` is committed KMS ciphertext under `alias/lab-secrets`; `.gitignore` gets `!secrets/hcloud-token.enc`.
- `test-kubeconfig` (`Makefile:204-207`): the hetzner arm prints "implemented in HETZ-130" and exits 1, as the civo stub does. `kubeconfig` (`:182`) prints "implemented in HETZ-040".
- CIVO-186 `make backup-promote FROM= TO=`: the enum gains `hetzner`. If CIVO-186 has not landed when this spec runs, add the line to CIVO-186 §4 instead and record that here.
- State: `PROVIDER=hetzner make state-up` creates `vk-hetzner-lab-tf-state` through the unchanged `state-up`. Nothing else in this spec touches state.
- Manual prerequisite, documented in `secrets/README.md`: create a Hetzner Cloud project named `vk-hetzner-lab` in the Console, create one Read&Write API token in that project, encrypt it with `SECRET_NAME=hcloud-token make secret-encrypt`, commit the `.enc` file. Never create the token in a project that holds anything else: every reader of the token owns the whole project (ADR 0030 amendment, HETZ-015).

## 5. Files/components affected

- `Makefile` (edit): guard, defaults, the hetzner arm in four `ifeq` blocks.
- `scripts/lib/provider.sh` (edit): third branch, `hcloud_token`, `hcloud_cli`, `hcloud_list_names`.
- `scripts/secret-decrypt.sh`, `scripts/secret-encrypt.sh` (edit): the `hcloud-token` path rule.
- `secrets/README.md` (edit): `hcloud-token.enc`, the project and token prerequisite.
- `.gitignore` (edit): `!secrets/hcloud-token.enc`.
- `secrets/hcloud-token.enc` (new, ciphertext).
- CIVO-186 enum, one line, when present.
- No Terraform, GitOps, or CI changes.

## 6. Implementation steps

1. Capture golden `make -n` output for the 16 lifecycle targets with `PROVIDER` unset, `PROVIDER=aws`, and `PROVIDER=civo`.
2. Edit the guard and the defaults. Add the hetzner arms.
3. Extend `provider.sh`. Run `shellcheck`.
4. Extend the secret path rule. Encrypt and commit the token.
5. Diff the goldens. All three must be empty.
6. Record `PROVIDER=hetzner make -n cluster-up`, `persistent-up`, `kubeconfig`, `test-kubeconfig` in §14.

## 7. Dependencies and blockers

None. HETZ-015 and HETZ-020 run in parallel. HETZ-016 starts after this spec is on `main`.

## 8. Acceptance criteria

- `make -n <t>` for all 16 lifecycle targets is byte-identical to the baseline for `PROVIDER` unset, `aws`, and `civo`.
- `make up PROVIDER=gcp` fails at parse time with the new message. Nothing else runs.
- `PROVIDER=hetzner make -n cluster-up` shows `terraform/live/cluster-hetzner`. `PROJECT_NAME` resolves to `vk-hetzner-lab`, `SUBDOMAIN` to `hetzner`, `CLUSTER_NAME` to `vk-hetzner-lab`. `PROVIDER=hetzner PROJECT_NAME=other make -n cluster-up` keeps `other`. Both `PROVIDER=hetzner make` and `make PROVIDER=hetzner` forms agree.
- `shellcheck scripts/lib/provider.sh scripts/secret-*.sh` is clean. `hcloud_token` prints the mask line only under `GITHUB_ACTIONS`.
- `scripts/secret-decrypt.sh hcloud-token >/dev/null` exits 0 on a workstation with KMS access. Never capture or display its stdout.
- `hcloud_cli server list` with `HCLOUD_TOKEN` set writes nothing under `~/.config/hcloud/`.

## 9. Validation

Offline: the golden diffs, `shellcheck`, `bash -n`. Real cloud: one `hcloud_cli server list` against the new project (empty list). Cost: 0.

## 10. AWS regression protection

The three golden `make -n` diffs (unset, `aws`, `civo`) are the gate. This spec adds arms and never edits an existing recipe line. `lab.yml` and `lifecycle-test.yml` are untouched. For civo, additionally run `PROVIDER=civo make -n up` before and after and diff.

## 11. Rollout and rollback/recovery

One PR together with `specs/hetzner/`. A revert restores the previous Makefile and scripts. No state or data risk. The committed ciphertext is inert without the KMS key.

## 12. Risks and unresolved questions

- The Make `?=` and `ifeq` ordering with three values. Test all four combinations of {command line, environment} × {default, override}, as CIVO-010 did.
- The account may reject a second project or a token creation until identity verification completes (`research.md`, new-account friction). This is outside the repository.
- `HCLOUD_CONFIG=/dev/null` must not break `hcloud` on a version that requires a readable file. Verify with the pinned CLI version from HETZ-140.

## 13. Definition of done

- [ ] Acceptance criteria met with recorded diffs
- [ ] `shellcheck` clean
- [ ] `secrets/README.md` updated with the manual project and token step
- [ ] Change on `main`; index row updated; status `DONE` with date

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
