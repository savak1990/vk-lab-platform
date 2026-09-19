---
id: "SHARED-038"
title: "tfstate_resource_count: one reader for whether a lifecycle layer has state, replacing ten hand-rolled copies across nine scripts"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "A single extracted reader with a fixed calling convention; every caller and its expected output is already enumerated below"
effort_estimate: "Half a session (2-3 h)"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
---

# SHARED-038 — `tfstate_resource_count`: one reader for "does this layer have state"

## 1. Outcome and rationale

One function answers "how many resources does this Terraform state file
track", and every script that guards a destroy or reports status calls it.
Today the same block - list state keys under a prefix, download each one,
count `.resources` with `jq` - is copied by hand into ten call sites across
nine scripts, each a slightly different transcription of the same four
AWS/jq calls.

**Priority 3, optional.** Every copy today is correct. This is a duplication
cleanup: a bug fixed in one copy (as happened with the explicit-`return`
version in `persistent-down.sh`) does not propagate to the other eight until
someone notices and repeats the fix by hand.

## 2. The problem

The same "list state keys under a prefix, download, count resources" block
appears, in this shape or a close variant, in:

- `scripts/account-down.sh` — the `for prefix in bootstrap persistent
  cluster` loop, lines 29-48 (keys at 32-33, `get-object` at 38, `jq` count at
  39).
- `scripts/bootstrap-down.sh` — the `for prefix in persistent persistent-civo
  cluster cluster-civo` loop, lines 35-55 (keys at 39-40, `get-object` at 45,
  count at 46).
- `scripts/persistent-down.sh` — `count_resources()`, lines 53-80 (keys at
  56-57, `get-object` at 69, count at 73), the one copy that already checks
  every AWS/`jq` call's own exit status by hand rather than relying on
  `set -e` to catch a failed command substitution.
- `scripts/require-persistent.sh` — two copies: lines 14-27 (the
  `persistent/` prefix) and lines 35-45 (the Civo-only `persistent-civo/network/`
  prefix).
- `scripts/status.sh` — the `for prefix in bootstrap persistent persistent-civo
  cluster cluster-civo` loop, lines 27-53 (keys at 33-34, `get-object` at 43,
  count at 44). Its own separate `"$(mktemp)"` at line 69 is passed inline to
  `argo_state` with no `trap` to clean it up - the only untrapped temp file
  among the ten call sites.
- `scripts/state-down.sh` — the `for prefix in bootstrap persistent
  persistent-civo cluster cluster-civo` loop, lines 30-50 (keys at 34-35,
  `get-object` at 40, count at 41).
- `scripts/account-state-down.sh` — the single `account/` prefix, lines 30-40
  (keys at 30-31, `get-object` at 36, count at 37).
- `scripts/require-unique-subdomain.sh` — a single known-key `get-object` at
  line 47 (no `list-objects-v2`, since the key - `bootstrap/route53/
  terraform.tfstate` - is fixed), with the resource-count `jq` filter at line
  57 (it filters for a specific resource type, not a plain length).
- `scripts/force-clean-ci.sh` — a single known-key `get-object` at lines
  76-80, with the same resource-type `jq` filter at line 79.

`scripts/lib/` has no shared state-reading helper today; every script above
inlines its own `aws s3api` and `jq` invocations.

## 3. Scope and non-goals

In scope:

- `scripts/lib/tfstate.sh`, a new helper file.
- The ten call sites named above, rewritten to use it.
- `status.sh`'s untrapped temp file at line 69.
- A unit test for the helper.

Non-goals:

- Changing which lifecycle prefixes any script checks, or what it does with
  a nonzero count.
- Changing bucket names or key layout.

## 4. Requirements

1. `scripts/lib/tfstate.sh` MUST define `tfstate_keys <bucket> <prefix>`,
   which lists the `terraform.tfstate` keys under `<prefix>/` in `<bucket>`
   and prints one per line (empty output for none - the caller does not see
   `list-objects-v2`'s literal `"None"`).
2. It MUST define `tfstate_resource_count <bucket> <key>`, which downloads
   `<key>` to a `mktemp`-created file guarded by its own `trap … RETURN` (or
   equivalent), prints the `.resources | length` count, and prints `0` for a
   missing object rather than failing.
3. Both functions MUST fail closed on an AWS or `jq` error - matching
   `persistent-down.sh`'s existing explicit-check behavior, not the plain-
   statement `set -e` behavior the other eight copies rely on - so every
   caller gets the stricter of the two existing behaviors, not the looser
   one.
4. Every one of the ten call sites in §2 MUST be replaced by calls to
   `tfstate_keys`/`tfstate_resource_count`. `require-unique-subdomain.sh` and
   `force-clean-ci.sh` keep their own resource-type-specific `jq` filter after
   the download; only the download-and-decode step is shared.
5. `status.sh`'s temp file at line 69 MUST get a `trap` (or MUST be replaced
   by a call into the new helper's own trapped temp file), removing the one
   untrapped temp file among the ten call sites.
6. `make status` output MUST be byte-identical before and after, against a
   recorded baseline captured before this change.
7. A unit test MUST exist with a fake `aws` on `PATH`, in the pattern of
   `tests/scripts/secret-scope-test.sh`, covering: a prefix with no matching
   keys, a prefix with one key whose state has N resources, and a missing
   object.

## 5. Implementation hints

- `require-persistent.sh`'s two copies and `persistent-down.sh`'s
  `count_resources` differ from the other six only in strictness (explicit
  `return 1` on a failed `aws`/`jq` call vs. relying on `set -e`); folding
  both into the stricter behavior removes that inconsistency for free.
- `require-unique-subdomain.sh` and `force-clean-ci.sh` both know the exact
  state key in advance (`bootstrap/route53/terraform.tfstate`) and filter for
  `aws_route53_zone` specifically - `tfstate_resource_count` is not the right
  fit for them as-is; they can call a small helper that only wraps the
  download-to-trapped-temp-file step (shared with `tfstate_resource_count`)
  and keep their own `jq` filter afterward.
- Record the `make status` baseline (with real or fake AWS state, whichever
  the environment used for testing has) before touching any of the nine
  scripts (ten call sites), so the "byte-identical" acceptance criterion has
  something to diff against.

## 6. Testing / acceptance criteria

1. The new unit test passes for all three cases in Requirement 7.
2. `make status` output is identical, byte for byte, to the recorded
   pre-change baseline.
3. Every one of the nine scripts (ten call sites) named in §2 still
   refuses/reports/destroys
   under the same conditions it did before, verified against at least one
   populated and one empty state prefix.
4. AWS and Civo `make -n` output identical before and after, for every
   target whose script changed.

## 7. Status history

- 2026-09-20 — created as READY from the 2026-09-20 shell-layer review.
