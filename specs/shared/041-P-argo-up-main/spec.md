---
id: "SHARED-041"
title: "argo-up.sh gets a main: every top-level phase named and called from one place, at the end of the file"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "No behavior changes and the phase boundaries are already named below, but correctly carrying the idempotency fast path and every variable a later phase reads from an earlier one needs care across a 566-line file"
effort_estimate: "Half a session (2-3 h)"
estimate_confidence: "medium"
depends_on: ["SHARED-037"]
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
---

# SHARED-041 — `argo-up.sh` gets a `main`

## 1. Outcome and rationale

`scripts/argo-up.sh`'s run order is visible in one place: a `main "$@"` call
at the end of the file, calling named phase functions in sequence. Today the
same information - what happens, in what order - is scattered across four
separate top-level blocks interleaved with 19 function definitions, readable
only by reading the whole file start to finish.

**Priority 3, optional.** The script runs correctly today. This is a
readability change, sequenced after SHARED-037 so the watch-loop phase this
spec extracts can call `wait_until` directly rather than inheriting its own
copy of the loop.

## 2. The problem

`scripts/argo-up.sh` is 566 lines and defines 19 functions: `eks_output`,
`ssm_output`, `aws_resolve_inputs`, `backup_resolve_generation`,
`civo_resolve_inputs`, `current_nlb_ips`, `dns_status`,
`civo_wait_for_lb_ip`, `civo_wait_for_dns`, `ensure_ca_secret`,
`aws_wait_for_dns`, `install_argocd`, `aws_install_root_application`,
`backup_publish_server_name`, `backup_prune_generations`,
`civo_install_root_application`, `print_app_status`, `pending_resources`,
and `operation_state`.

Top-level flow runs at four separate points among those definitions, not in
one place:

- Provider dispatch, lines 157-161 (`civo_resolve_inputs` vs.
  `aws_resolve_inputs`) and 163-165 (`civo_import_tls_secret`, called only on
  civo - aws has no counterpart call here).
- `ensure_ca_secret`, called conditionally at lines 292-294.
- Root Application install, lines 474-478 (`civo_install_root_application`
  vs. `aws_install_root_application`).
- The root-Application watch loop, lines 518-550 (setup at 518-522, the
  `while` loop itself at 523-548).

A reader cannot see the script's order without reading start to finish and
mentally re-assembling these four points against the function definitions
between them.

## 3. Scope and non-goals

In scope:

- Extracting each top-level block in §2 into a named phase function.
- One `main "$@"` at the end of the file, calling every phase in order.
- A `ARGO-UP: <phase>` line printed at the start of each phase.

Non-goals:

- Changing any wait/timeout logic (SHARED-037's job).
- Splitting provider-specific code into separate files (SHARED-040's job).
- Any change to what gets installed, waited for, or reported.

## 4. Requirements

1. All top-level flow currently outside a function MUST move into named
   phase functions: `resolve_inputs` (the provider-dispatch block at lines
   157-165), `install_argocd_release` (the existing `install_argocd`
   function's call site plus `ensure_ca_secret`'s conditional call at
   292-294), `install_root` (the root-Application install block at
   474-478), `watch_root` (the watch loop at 518-550), `wait_for_edge` (any
   DNS-wait logic currently interleaved with the above, if distinct from
   `watch_root`), and `publish_backup_handle` (the backup-generation
   bookkeeping currently threaded through `backup_resolve_generation`/
   `backup_publish_server_name`/`backup_prune_generations`).
2. Exactly one `main "$@"` call MUST exist, at the end of the file, calling
   the phase functions in the same order the script executes them today.
3. No behavior change: every command, every condition, every message stays
   as it is - this is a pure reorganization.
4. The idempotency fast path (the early-return when the root Application is
   already `Synced`/`Healthy`) MUST stay intact and MUST still run before
   `watch_root`'s full loop, exactly as it does today.
5. Every phase function MUST print exactly one `ARGO-UP: <phase>` line
   naming itself when it starts, in addition to whatever it already prints.
6. `make -n` output for every target that invokes `argo-up.sh`, on both AWS
   and Civo, MUST be identical before and after.
7. One real `argo-up` run on AWS and one on Civo MUST complete, each showing
   the new `ARGO-UP: <phase>` lines in the order `main` calls them.

## 5. Implementation hints

- Variables set inside one former top-level block and read by another
  (`ROUTE53_ZONE_ID`, `PRIOR_OPERATION_STARTED_AT`, and similar) need to
  stay reachable across the new function boundaries - since this script
  does not `set -u` strictly by convention elsewhere, the safest path is
  passing them as explicit arguments or keeping them as script-global
  variables set by an earlier phase and read by a later one, not converting
  them to function-local without checking every read site first.
- SHARED-037 lands first specifically so `watch_root` can call `wait_until`
  directly instead of carrying its own `elapsed`/`WATCH_SECONDS` loop through
  this extraction and then immediately rewriting it again.
- Extract one phase at a time and re-run a syntax check (`bash -n`) after
  each, rather than moving all four blocks in one pass - a 566-line file is
  easy to leave with a dangling brace.

## 6. Testing / acceptance criteria

1. `main "$@"` is the only top-level statement below the function
   definitions; every other top-level line moved into a named phase.
2. AWS and Civo `make -n` output identical before and after.
3. One AWS and one Civo `argo-up` run recorded, each showing every
   `ARGO-UP: <phase>` line in call order and completing with the same
   outcome as before this change.
4. The idempotency fast path is exercised by a second `argo-up` run against
   an already-`Synced`/`Healthy` root Application, confirming it still skips
   the full watch.

## 7. Status history

- 2026-09-20 — created as READY from the 2026-09-20 shell-layer review.
