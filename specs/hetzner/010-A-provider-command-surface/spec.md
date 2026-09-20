---
id: "HETZ-010"
title: "PROVIDER=hetzner operator input with Hetzner project defaults, token helper, and Make dispatch"
status: "IN_REVIEW"
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
updated: "2026-09-20"
completed: ""
---

# HETZ-010 — PROVIDER=hetzner operator input and Make dispatch

## 1. Outcome and rationale

`make <target> PROVIDER=hetzner` selects the Hetzner project directories and
the Hetzner stack directories. `make <target>` with `PROVIDER` unset, `aws`,
or `civo` behaves exactly as it does today. The `hcloud_token()` helper is
the single place that decrypts the Hetzner API token. This spec lands first
and alone, as CIVO-010 did, because every later Hetzner spec uses the seam.

The kubeadm bootstrap runs inside `cluster-up` through
`scripts/hetzner-bootstrap.sh` (HETZ-035); no target of its own. The one
Hetzner-only helper, `make node-ssh`, lands in HETZ-040 and prints a
message on the other providers.

## 2. Scope and non-goals

In scope: `Makefile`, `scripts/lib/provider.sh`, the `hcloud_token` and
`hcloud_cli` helpers, the `SECRET_SCOPE=global` decrypt of
`hetzner-token`, the
`test-kubeconfig` stub arm, and a `make -n`
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
- Defaults when `PROVIDER=hetzner`: `PROJECT_NAME ?= vk-hetzner-lab`, `SUBDOMAIN ?= hz`, `CLUSTER_DIR = cluster-hetzner`, `CLUSTER_NAME = $(PROJECT_NAME)`, `PERSISTENT_EXTRA_DIR = persistent-hetzner`, `BOOTSTRAP_EXCLUDE = acm`, `PERSISTENT_EXCLUDE = vpc`. `scripts/lib/provider.sh` exports the same values in a third branch. An explicit operator override always wins, as for civo.
- `hcloud_token()` in `provider.sh`: runs `SECRET_SCOPE=global scripts/secret-decrypt.sh hetzner-token`, prints `::add-mask::<value>` when `GITHUB_ACTIONS` is set, exports `HCLOUD_TOKEN`, and never echoes the token otherwise. The Terraform provider and the CLI read `HCLOUD_TOKEN`; the token never appears in tfvars, state, or arguments.
- `hcloud_cli()`: runs `hcloud "$@"` with `HCLOUD_TOKEN` exported. No config redirect is needed. Add `HCLOUD_CONFIG=/dev/null` anyway so that a stray `hcloud context` on an operator machine can never leak into a run.
- `hcloud_list_names()`: `hcloud <resource> list -o json -l project=<project>` piped through `jq -r '.[].name'`. Unlike the civo CLI, an empty result is `[]`, so no shape check is needed. HETZ-040 uses it.
- Secret path rule: none to add. `secret-decrypt.sh` and `secret-encrypt.sh` already resolve an account-global secret from the `SECRET_SCOPE=global` argument rather than from a name list, so `hetzner-token` needs no entry. `secrets/hetzner-token.enc` is committed KMS ciphertext under `alias/lab-secrets`, beside `civo-token.enc`.
- `test-kubeconfig` (`Makefile:204-207`): the hetzner arm prints "implemented in HETZ-130" and exits 1, as the civo stub does. `kubeconfig` (`:182`) prints "implemented in HETZ-040".
- State: `PROVIDER=hetzner make state-up` creates `vk-hetzner-lab-tf-state` through the unchanged `state-up`. Nothing else in this spec touches state.
- Manual prerequisite, documented in `secrets/README.md`: create a Hetzner Cloud project named `vk-hetzner-lab` in the Console, create one Read&Write API token in that project, encrypt it with `SECRET_SCOPE=global SECRET_NAME=hetzner-token make secret-encrypt`, commit the `.enc` file. Never create the token in a project that holds anything else: every reader of the token owns the whole project (ADR 0030 amendment, HETZ-015).

## 5. Files/components affected

- `Makefile` (edit): guard, defaults, the hetzner arm in four `ifeq` blocks.
- `scripts/lib/provider.sh` (edit): third branch, `hcloud_token`, `hcloud_cli`, `hcloud_list_names`.
- `scripts/secret-decrypt.sh`, `scripts/secret-encrypt.sh`: no edit — `SECRET_SCOPE=global` already covers `hetzner-token`.
- `secrets/README.md` (edit): `hetzner-token.enc`, the project and token prerequisite.
- `.gitignore`: no edit — `!secrets/*.enc` already tracks it.
- `secrets/hetzner-token.enc` (already committed, ciphertext).
- No Terraform, GitOps, or CI changes.

## 6. Implementation steps

1. Capture golden `make -n` output for the 16 lifecycle targets with `PROVIDER` unset, `PROVIDER=aws`, and `PROVIDER=civo`.
2. Edit the guard and the defaults. Add the hetzner arms.
3. Extend `provider.sh`. Run `shellcheck`.
4. Diff the goldens. All three must be empty.
5. Record `PROVIDER=hetzner make -n cluster-up`, `persistent-up`, `kubeconfig`, `test-kubeconfig` in §14.

## 7. Dependencies and blockers

None. HETZ-015 and HETZ-020 run in parallel. HETZ-016 starts after this spec is on `main`.

## 8. Acceptance criteria

- `make -n <t>` for all 16 lifecycle targets is byte-identical to the baseline for `PROVIDER` unset, `aws`, and `civo`.
- `make up PROVIDER=gcp` fails at parse time with the new message. Nothing else runs.
- `PROVIDER=hetzner make -n cluster-up` shows `terraform/live/cluster-hetzner`. `PROJECT_NAME` resolves to `vk-hetzner-lab`, `SUBDOMAIN` to `hz`, `CLUSTER_NAME` to `vk-hetzner-lab`. `PROVIDER=hetzner PROJECT_NAME=other make -n cluster-up` keeps `other`. Both `PROVIDER=hetzner make` and `make PROVIDER=hetzner` forms agree.
- `shellcheck scripts/lib/provider.sh scripts/secret-*.sh` is clean. `hcloud_token` prints the mask line only under `GITHUB_ACTIONS`.
- `SECRET_SCOPE=global scripts/secret-decrypt.sh hetzner-token >/dev/null` exits 0 on a workstation with KMS access. Never capture or display its stdout.
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

- [x] Acceptance criteria met with recorded diffs
- [ ] `shellcheck` clean — not run: not installed on the workstation and never run for the aws or civo arms; `bash -n` is clean (see §14)
- [x] `secrets/README.md` updated with the manual project and token step
- [ ] Change on `main`; index row updated; status `DONE` with date

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-20 — review fix: §6's "extend the secret path rule" step is
  deleted and the rest renumbered; §4 and §5 already state that
  `SECRET_SCOPE=global` covers `hetzner-token` with no path-rule or
  `.gitignore` edit.
- 2026-09-20 — the committed ciphertext is `secrets/hetzner-token.enc`, account-global like `civo-token.enc`, read with `SECRET_SCOPE=global`; no path-rule or `.gitignore` edit is needed. The helper name `hcloud_token()` and the env var `HCLOUD_TOKEN` are unchanged.
- 2026-09-20 — no unmet dependencies (depends_on empty); promoted to IN_PROGRESS.
  Decision: `SUBDOMAIN` defaults to `hz` (zone `hz.<root-domain>`), not
  `hetzner`; every spec in this package that named the zone is updated in
  the same change. Decision: a pull request is the default delivery for
  every spec from now on (`specs/civo/README.md` step 6 updated).
- 2026-09-20 — implemented and validated. Execution evidence (commands run,
  no secrets):
  - Byte-identity gate: `make -n` for the 16 lifecycle targets captured
    before the first code edit in five forms (`PROVIDER` unset, `PROVIDER=aws`
    env, `make PROVIDER=aws`, `PROVIDER=civo` env, `make PROVIDER=civo`; 80
    files, no absolute path in any) and `diff -r`'d after the Makefile
    change and again after the `provider.sh` change — empty both times.
  - `make -n up PROVIDER=gcp` → `Makefile:11: *** PROVIDER must be aws,
    civo or hetzner, got 'gcp'.  Stop.` (exit 2), nothing else runs.
  - `make -n cluster-up PROVIDER=hetzner` → `./scripts/require-persistent.sh`
    then `bash -c '...; hcloud_token; cd terraform/live/cluster-hetzner &&
    terragrunt run --all --non-interactive -- apply -auto-approve'`;
    identical in the `PROVIDER=hetzner make` form. `make -n persistent-up`
    → `./scripts/persistent-up-hetzner.sh` (HETZ-025 creates it; until then
    the target fails loudly with "No such file", nothing applied).
  - `make -pn` resolution with `PROVIDER=hetzner`: `PROJECT_NAME
    vk-hetzner-lab`, `SUBDOMAIN hz`, `CLUSTER_DIR cluster-hetzner`,
    `PERSISTENT_EXTRA_DIR persistent-hetzner`, `BOOTSTRAP_EXCLUDE acm`,
    `PERSISTENT_EXCLUDE vpc`. `PROJECT_NAME=other` wins in all four
    {env, command line} × {PROVIDER, PROJECT_NAME} combinations.
  - `provider.sh` sourced with `PROVIDER=hetzner` exports
    `vk-hetzner-lab|hz|cluster-hetzner|vk-hetzner-lab|persistent-hetzner|acm|vpc|persistent`
    (the last is `BACKUP_SSM_LAYER`); civo and aws exports unchanged.
  - Offline probe with a fake `aws` (base64 round-trip) and a fake `hcloud`
    on PATH: `hcloud_token` exports `HCLOUD_TOKEN` and prints
    `::add-mask::` only with `GITHUB_ACTIONS` set; `hcloud_cli` runs with
    `HCLOUD_CONFIG=/dev/null` and passes the exit status through (3 → 3);
    `hcloud_list_names server` sends `-o json -l project=vk-hetzner-lab`,
    prints nothing for `[]` and for `null`, and prints both names for a
    two-item list; extra terms append as
    `project=other,role=control-plane,managed_by=terraform`.
  - `make kubeconfig PROVIDER=hetzner` → `configure_kubeconfig:
    PROVIDER=hetzner is implemented in HETZ-035`, exit 1 (make exit 2);
    `make test-kubeconfig PROVIDER=hetzner` → `... implemented in
    HETZ-130`, exit 1. A fake `kubectl` on PATH was never reached.
  - `bash -n scripts/lib/provider.sh` clean. `make secrets-check`,
    `make specs-check`, `make gitops-check` pass.
  - Real cloud (`AWS_PROFILE=viacheslav-dev`, cost 0): `SECRET_SCOPE=global
    scripts/secret-decrypt.sh hetzner-token >/dev/null` exit 0 (stdout
    never captured); `hcloud_token; hcloud_cli server list` → empty table,
    exit 0; `hcloud_list_names server` → empty, exit 0; `~/.config/hcloud`
    absent before and after.
  - Deviations from §4: the `kubeconfig` stub names HETZ-035, which owns
    `configure_kubeconfig` (HETZ-035 §2), not HETZ-040. The README uses
    `make secret-encrypt NAME=hetzner-token VALUE=<token> SCOPE=global`
    because the Make target overrides `SECRET_NAME`/`SECRET_SCOPE` from
    `NAME=`/`SCOPE=`. `BACKUP_SSM_LAYER=persistent` is exported for hetzner
    (§4 omits it; hetzner keeps the AWS `persistent/backups` unit, whose
    `ssm_layer` is `persistent`). `hcloud_list_names <resource> [k=v ...]`
    always prefixes `project=$PROJECT_NAME`; HETZ-040 adopts this helper
    instead of its draft `hcloud_list`, and `HCLOUD_CONFIG=/dev/null`
    supersedes HETZ-040's `mktemp` wording. `kubeconfig`/`test-kubeconfig`
    are not `ifeq` blocks in the Makefile; the stubs live in `provider.sh`.
    `.gitignore`, `secret-*.sh`: no edit, as §5 already states.
- 2026-09-20 — pull request opened; IN_REVIEW.
