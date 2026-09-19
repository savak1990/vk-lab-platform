---
id: "SHARED-042"
title: "Fold the state-bucket script pairs into one script per direction, parametrized by layer, and fix the one untrapped temp file"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "Two scripts each collapse into one with a layer argument; the differences between each pair are already enumerated below and are small"
effort_estimate: "Half a session (2-3 h)"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
---

# SHARED-042 — Fold the state-bucket script pairs and fix the small leaks

## 1. Outcome and rationale

One `state-up.sh` and one `state-down.sh`, each taking a layer argument
(`project` or `account`), replace today's four scripts:
`scripts/state-up.sh`/`scripts/account-state-up.sh` and
`scripts/state-down.sh`/`scripts/account-state-down.sh`. Each pair is the
same script twice, differing only in which bucket name it computes and
which Terraform unit directory it targets.

**Priority 3, optional.** All four scripts work correctly today. This
removes a maintenance trap - a fix applied to one half of a pair (as very
nearly happened, since the two `-up` scripts already differ slightly in
which checks precede the two-phase bootstrap) silently not reaching the
other - and fixes the one temp file in this area that has no `trap`.

## 2. The problem

`scripts/state-up.sh` and `scripts/account-state-up.sh` are the same
two-phase local-backend bootstrap, written twice:

- Both clear a stale cache/state with `rm -rf .terragrunt-cache
  terraform.tfstate terraform.tfstate.backup` at three points each:
  `state-up.sh` lines 21, 61, 93; `account-state-up.sh` lines 26, 38, 67.
- Both back up `terragrunt.hcl` to `terragrunt.hcl.orig` and set a
  restoring `trap` before appending a temporary local-backend block:
  `state-up.sh` lines 63-82 (`cp` at 63, `trap` at 67); `account-state-up.sh`
  lines 40-56 (`cp` at 40, `trap` at 41).
- Both run the same `terragrunt init`/`apply`/`migrate-state`/`plan`
  sequence: `state-up.sh` lines 84-96; `account-state-up.sh` lines 58-70.
- `state-up.sh` probes AWS credentials explicitly (lines 34-37) and
  distinguishes a missing-bucket 404 from an unreadable-bucket error (lines
  39-51) before choosing the two-phase path; `account-state-up.sh` has
  neither check (line 29's `head-bucket` call is a plain `if`, with no
  credential probe and no 404-vs-other distinction) - an inconsistency
  folding the pair together removes rather than preserves.

`scripts/state-down.sh` and `scripts/account-state-down.sh` are the same
resource-count-then-permanently-delete script, written twice:

- Both loop prefixes, count resources, and refuse if any prefix is
  non-empty: `state-down.sh` lines 30-50; `account-state-down.sh` lines
  30-45 (a single `account/` prefix, since that bucket has no sibling
  prefixes to check).
- Both then delete every object version and delete marker in batches of
  1000, then delete the bucket itself: `state-down.sh` lines 52-73;
  `account-state-down.sh` lines 47-67.

`scripts/status.sh` passes `"$(mktemp)"` inline at line 69 as an argument to
`argo_state`, with no `trap` covering that specific temp file - every other
temp file in this area (including `status.sh`'s own `TMP_DIR` at line 24-25)
is trapped; this one is not.

## 3. Scope and non-goals

In scope:

- Folding `state-up.sh`/`account-state-up.sh` into one script.
- Folding `state-down.sh`/`account-state-down.sh` into one script.
- The `Makefile` targets `state-up`, `account-state-up`, `state-down`,
  `account-state-down` calling the folded scripts with the right layer
  argument.
- `status.sh`'s untrapped temp file at line 69.

Non-goals:

- Changing any bucket name, key prefix, or Terraform backend configuration.
- Changing the credential/404 checks `state-up.sh` has and
  `account-state-up.sh` lacks, beyond bringing both under the one check the
  folded script now always runs (see Requirement 3).

## 4. Requirements

1. One `scripts/state-up.sh`, parametrized by a `project`/`account` layer
   argument, MUST replace the current `scripts/state-up.sh` and
   `scripts/account-state-up.sh`. The layer argument selects: the bucket
   name (`${PROJECT_NAME}-tf-state` vs. `${GITHUB_REPO_OWNER}-account-state`),
   the Terraform unit directory (`terraform/live/state` vs.
   `terraform/live/account-state`), and the messages/labels that currently
   differ between the two ("State layer bootstrapped" vs. "Account state
   layer bootstrapped").
2. One `scripts/state-down.sh`, parametrized the same way, MUST replace the
   current `scripts/state-down.sh` and `scripts/account-state-down.sh`. The
   layer argument selects the bucket name and which prefixes get checked
   before the permanent delete (`bootstrap persistent persistent-civo
   cluster cluster-civo` for `project`, just `account` for `account`).
3. The folded `state-up.sh` MUST run the AWS-credential probe and the
   404-vs-other-error distinction (today only in the project-layer script)
   for both layers - this is a behavior change, and MUST be called out as
   one in the commit/PR description, not silently introduced.
4. The `Makefile` targets `state-up`, `account-state-up`, `state-down`,
   `account-state-down` MUST call the folded script with the right layer
   argument, and MUST keep their current names - this is an internal
   refactor of what each target runs, not a renaming of the targets
   themselves.
5. `status.sh`'s temp file at line 69 MUST get a `trap`, or MUST be replaced
   by a variable created earlier under the existing `TMP_DIR` trap at lines
   24-25.
6. `make -n` output for `state-up`, `state-down`, and `status` MUST be
   identical before and after - those targets keep calling the same script
   path. For `account-state-up` and `account-state-down`, `make -n` output
   MUST change in exactly one way: the script path each recipe calls (now
   `state-up.sh account`/`state-down.sh account` instead of a dedicated
   `account-state-up.sh`/`account-state-down.sh`) - nothing else in either
   recipe line MUST differ.

## 5. Implementation hints

- The two `-up` scripts and the two `-down` scripts each differ in exactly
  three things: the bucket-name expression, the unit directory, and a couple
  of message strings - a single `case "$layer" in project|account)` block at
  the top of each folded script, setting `BUCKET`/`UNIT_DIR`/`LABEL`
  variables, covers the whole difference; everything below that block is
  already identical between the two originals.
- `account-state-down.sh` has no sibling prefixes to loop (only `account/`
  exists in that bucket) - the folded `state-down.sh` can pass a
  layer-specific prefix list (one entry for `account`, five for `project`)
  rather than special-casing the loop itself.
- Fix `status.sh`'s temp file first, in isolation, since it has no bearing
  on the fold and is otherwise easy to forget once the two bigger scripts
  are underway.

## 6. Testing / acceptance criteria

1. `make -n state-up state-down status` output identical before and after,
   for both AWS and Civo. `make -n account-state-up account-state-down`
   output differs only in the script path each recipe calls, as
   Requirement 6 specifies.
2. One real `state-up`/`state-down` round trip against a scratch bucket (or
   an already-torn-down state bucket) for the `project` layer, and one for
   the `account` layer, each producing the same messages and final state as
   the corresponding original script did.
3. `status.sh`'s temp file cleanup verified by running it and confirming no
   leftover `/tmp` file survives the run (or that it is now created under
   the already-trapped `TMP_DIR`).
4. The credential-probe behavior change from Requirement 3 is named in the
   commit/PR description, with confirmation that `account-state-up.sh`'s old
   behavior (no probe) is gone.

## 7. Status history

- 2026-09-20 — created as READY from the 2026-09-20 shell-layer review.
