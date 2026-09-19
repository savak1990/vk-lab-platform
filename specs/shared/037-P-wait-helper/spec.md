---
id: "SHARED-037"
title: "One shared wait_until poll loop, replacing five hand-rolled copies across the lifecycle scripts"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "fast"
model_rationale: "A single extracted helper with a fixed calling convention; the loop shape and the callers are already settled below"
effort_estimate: "Half a session (2-3 h)"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
---

# SHARED-037 — `wait_until`: one poll loop for the lifecycle scripts

## 1. Outcome and rationale

One function, `wait_until`, runs every poll-until-ready loop in the lifecycle
scripts. Today five loops repeat the same shape by hand, each with its own
elapsed-time bookkeeping and its own timeout message. A sixth loop is one
`git blame` away from copying the same fifteen lines again.

**Priority 3, optional.** None of the five loops is wrong today. This is a
duplication cleanup, not a bug fix - do it when touching one of the five
callers costs more than the extraction would, or ahead of SHARED-041, which
depends on it to keep `argo-up.sh`'s watch loop a single named function.

## 2. The problem

Five loops share the shape `elapsed=0; while [ "$elapsed" -lt "$watch" ]; do
…; sleep "$poll"; elapsed=$((elapsed + poll)); done`, each hand-rolled:

- `scripts/argo-up.sh` `civo_wait_for_lb_ip` — loop at lines 207-215 (function
  starts 203).
- `scripts/argo-up.sh` `civo_wait_for_dns` — loop at lines 225-240 (function
  starts 221).
- `scripts/argo-up.sh` `aws_wait_for_dns` — loop at lines 266-279 (function
  starts 262).
- `scripts/argo-up.sh`'s top-level root-Application watch — loop at lines
  523-548 (`WATCH_SECONDS`/`elapsed` set up at 518-522).
- `scripts/lib/provider.sh` `backup_teardown` — loop at lines 241-258 (timeout
  and poll variables set up at 199-201).

Each pair defines its own env-var names for the timeout and poll interval
(`ARGO_UP_WATCH_SECONDS`/`ARGO_UP_POLL_INTERVAL`, `ARGO_DOWN_WATCH_SECONDS`/
`ARGO_DOWN_POLL_INTERVAL`, and so on), and each prints its own progress line
in its own format. `kubectl wait` is used only twice, in
`scripts/argo-down.sh` at lines 253 and 269, for PVC/PV deletion - a case
`wait_until` does not need to replace, since a native primitive already
covers it.

## 3. Scope and non-goals

In scope:

- `scripts/lib/wait.sh`, a new helper file.
- The five loops named above, rewritten to call it.
- A unit test for the helper.

Non-goals:

- Changing any timeout or poll-interval value, or its env-var name.
- Replacing the two `kubectl wait` calls in `scripts/argo-down.sh`.
- Changing what each loop prints beyond the label passed to `wait_until`.

## 4. Requirements

1. `scripts/lib/wait.sh` MUST define `wait_until <timeout_s> <interval_s>
   <label> <cmd...>`. It runs `<cmd...>` repeatedly until it exits 0, or until
   `<timeout_s>` seconds have elapsed, sleeping `<interval_s>` seconds between
   attempts.
2. It MUST print `<label>: still waiting (Ns/Ts)` to stdout, and only when
   `<cmd...>`'s own stdout output changes between polls, mirroring the
   existing "only log on a state change" behavior in `argo-up.sh`'s watch
   loop.
3. On timeout it MUST print a message naming `<label>` and the elapsed time,
   plus the last captured output, to stderr, and MUST return 1 without
   calling `exit` itself - the caller decides whether a timeout is fatal.
4. It MUST be bash-3.2 compatible: no `declare -A`, no `mapfile`, no process
   substitution the function itself cannot avoid.
5. All five loops listed in §2 MUST call `wait_until` instead of their own
   `while`/`elapsed` bookkeeping. Behavior for a caller MUST NOT change:
   same timeout, same poll interval, same exit code on timeout, same
   information in the printed message.
6. Every existing env-var name for a timeout or poll interval MUST keep
   working unchanged (`ARGO_UP_WATCH_SECONDS`, `ARGO_UP_POLL_INTERVAL`,
   `ARGO_DOWN_WATCH_SECONDS`, `ARGO_DOWN_POLL_INTERVAL`, and
   `scripts/lib/provider.sh`'s own pair) - this is an internal refactor, not a
   change to what an operator or a workflow sets.
7. A new Make target `scripts-check` MUST exist (created here; see
   SHARED-039 for what else it grows to run) and MUST run every
   `tests/scripts/*-test.sh`.
8. `tests/scripts/wait-until-test.sh` MUST exist, wired into `scripts-check`,
   covering: a fake command that fails twice and succeeds on its third call
   before timeout, and a fake command that never succeeds, exercising the
   timeout path and its exit code.

## 5. Implementation hints

- `civo_wait_for_lb_ip`, `civo_wait_for_dns`, and `aws_wait_for_dns` each also
  compute a value (an IP, a resolved-count) that the loop body needs after it
  breaks, not just a pass/fail. `wait_until`'s `<cmd...>` can write that value
  to a variable the caller already has in scope, the same way the existing
  loop bodies do - the helper only owns the timing and the message, not the
  per-caller side effect.
- `backup_teardown`'s loop also inspects a `phase` field on every iteration to
  decide whether to fail immediately (`phase == "failed"`) rather than wait out
  the timeout. That immediate-fail path stays in the caller: `wait_until`'s
  `<cmd...>` can itself `exit`/`return` a distinguishing code the caller checks
  after `wait_until` returns, or the caller can keep a thin wrapper function as
  its `<cmd...>` that does the phase check and returns non-zero either way,
  leaving `wait_until` itself untouched by that distinction.
- `tests/scripts/secret-scope-test.sh` (already in the tree) is the pattern to
  follow for a fake command on `PATH` and a self-contained pass/fail script.

## 6. Testing / acceptance criteria

1. `tests/scripts/wait-until-test.sh` passes: the third-call-succeeds case
   returns 0 before its timeout, and the never-succeeds case returns 1 after
   its timeout with the last output on stderr.
2. `make scripts-check` runs it and reports success.
3. AWS and Civo `make -n` output identical before and after, for every target
   that touches `argo-up.sh` or `scripts/lib/provider.sh`.
4. One real `argo-up` and one real `argo-down` run, either provider, complete
   with unchanged wall-clock behavior and unchanged log wording apart from the
   loop's own progress line.

## 7. Status history

- 2026-09-20 — created as READY from the 2026-09-20 shell-layer review.
