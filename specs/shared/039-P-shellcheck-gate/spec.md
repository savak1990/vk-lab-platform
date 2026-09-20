---
id: "SHARED-039"
title: "shellcheck and bash -n join fast validation, so the ten scripts that already claim shellcheck compliance are actually checked"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "A lint gate plus a first fix-or-suppress pass; every finding is mechanical once shellcheck runs, no design decision is open"
effort_estimate: "Half a session (2-3 h) plus the first fix pass"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
---

# SHARED-039 — shellcheck and `bash -n` in fast validation

## 1. Outcome and rationale

Every script under `scripts/` and `tests/scripts/` is parsed with `bash -n`
and linted with `shellcheck` on every pull request, in the same
`validate-repo` job that already runs `make gitops-check`, `make
specs-check`, and `make secrets-check` with no AWS credentials.

**Priority 3, optional.** Nothing here is broken today - the scripts run.
This closes a gap between what ten scripts already claim
(`# shellcheck source=…`/`shell=bash` directives) and what CI actually
verifies (nothing).

## 2. The problem

Ten scripts carry a `# shellcheck source=…` or `# shellcheck shell=bash`
directive, written for a linter nothing runs:
`scripts/verify-no-leaks.sh` (lines 27, 29), `scripts/persistent-down.sh`
(line 24), `scripts/bootstrap-up.sh` (line 10), `scripts/status.sh` (line
8), `scripts/require-persistent.sh` (line 6), `scripts/force-clean-ci.sh`
(lines 33, 35, 37), `scripts/persistent-up-civo.sh` (line 9),
`scripts/ca-init.sh` (line 8), `scripts/cluster-down.sh` (line 23), and
`scripts/lib/provider.sh` (line 1, `shell=bash`).

`.github/workflows/lifecycle-test.yml`'s `validate-repo` job runs `make
gitops-check`, `make specs-check`, and `make secrets-check` - no `shellcheck`
anywhere in `.github/`, and no `shellcheck` target in the `Makefile`. The only
occurrence of the word "shellcheck" in the whole CI-relevant tree is a prose
comment, at `.github/workflows/lifecycle-test.yml` line 610, explaining why a
format string is written the way it is - not an invocation.

The macOS-bash-3.2 idioms these scripts depend on are guarded by comments
only, not by any check: `scripts/lib/provider.sh` uses `${kcfg[@]:+"${kcfg[@]}"}`
at lines 121, 122, 123, 127, 129, 143, 144, 151, and 156, specifically because
stock `/bin/bash` on macOS predates `declare -A` and `mapfile`. Nothing
verifies a future edit does not reintroduce one of those.

No `.shellcheckrc` exists in the repository root, so any local `shellcheck`
run today falls back to whatever default dialect the invoker's shell
happens to imply.

## 3. Scope and non-goals

In scope:

- A `make scripts-check` target.
- Wiring it into `.github/workflows/lifecycle-test.yml`'s `validate-repo`
  job.
- A `.shellcheckrc`.
- Fixing or suppressing (with a one-line, per-line reason) whatever the
  first real run finds.
- A header comment on `scripts/specs-check.sh` explaining its missing
  `set -e`.

Non-goals:

- `shfmt` or any other formatter.
- Rewriting any script beyond what a shellcheck/`bash -n` finding actually
  names.

## 4. Requirements

1. `make scripts-check` MUST run `bash -n` against every file matching
   `scripts/**/*.sh` and `tests/scripts/*.sh`, failing on the first syntax
   error.
2. It MUST then run `shellcheck -x -S warning` against the same file set.
3. It MUST then run every `tests/scripts/*-test.sh` (this absorbs
   SHARED-037's `wait-until-test.sh` and any test already in the tree, such
   as `secret-scope-test.sh`, into one target).
4. `.github/workflows/lifecycle-test.yml`'s `validate-repo` job MUST run
   `make scripts-check`, with `shellcheck` installed at a pinned version -
   either added to `.github/actions/setup-lab-tools` or installed via `apt`
   with the version recorded in the workflow - so the CI version is fixed
   and known, not "whatever ubuntu-latest ships this week."
5. Every finding from the first real `shellcheck -x -S warning` run MUST be
   resolved: fixed, or suppressed with `# shellcheck disable=SCxxxx` on the
   line it applies to, each carrying a one-line reason in plain prose (the
   existing `cluster-down.sh:105` `# shellcheck disable=SC2086` is the
   pattern already in the tree, and its own reason comment MUST be checked
   for completeness while this spec is implemented).
6. A `.shellcheckrc` MUST exist at the repository root, setting `shell=bash`
   and `external-sources=true` (`external-sources` matters because most
   scripts `source` a sibling under `scripts/lib/`, and without it
   shellcheck cannot resolve those and repeats "not following" warnings for
   every one).
7. `scripts/specs-check.sh` MUST get a header comment stating why it runs
   with `set -uo pipefail` rather than `set -euo pipefail` like every other
   script - it accumulates failures across the whole `specs/` tree rather
   than aborting on the first one, so `set -e` would defeat its own purpose.

## 5. Implementation hints

- Run `shellcheck` once, uncommitted, before deciding how to wire it into
  `make`, to see the real finding count and shape - the fix-or-suppress pass
  is sized against what actually comes back, not a guess.
- `${kcfg[@]:+"${kcfg[@]}"}` and similar guards are exactly the kind of thing
  `shellcheck -S warning` should leave alone once it understands the bash-3.2
  constraint; if it flags them anyway, a repo-wide suppression comment
  explaining the constraint (once, near the first occurrence, referenced from
  the rest) is preferable to nine near-identical inline suppressions.
- `setup-lab-tools`'s `scope: test` input already exists for jobs that skip
  the heavier terraform/terragrunt/helm install (see its own header comment);
  `validate-repo` already uses a similarly light install path, so adding
  `shellcheck` there costs little.

## 6. Testing / acceptance criteria

1. `make scripts-check` exits 0 on the current tree once the first fix pass
   lands.
2. Reintroducing a known syntax error (a deliberately unmatched `fi`) in a
   scratch copy makes `make scripts-check` fail at the `bash -n` stage before
   `shellcheck` runs.
3. `validate-repo` in `.github/workflows/lifecycle-test.yml` shows
   `scripts-check` in its step list, with the installed `shellcheck` version
   recorded in the run log.
4. `.shellcheckrc` is present and `shellcheck` picks it up with no `-x`
   warning about following an unresolvable source once `external-sources`
   is set.
5. AWS and Civo `make -n` output identical before and after.

## 7. Status history

- 2026-09-20 — created as READY from the 2026-09-20 shell-layer review.
