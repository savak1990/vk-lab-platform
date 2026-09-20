---
id: "SHARED-043"
title: "Merge queue on main, with lifecycle-test answering merge_group events"
status: "READY"
priority: "P2"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One workflow's trigger and gate logic plus branch protection; the risk is a queue that deadlocks, which is visible immediately"
effort_estimate: "One session (2–3 h), including one queued merge to prove it"
estimate_confidence: "medium"
depends_on: ["SHARED-035", "SHARED-017"]
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
completed: ""
---

# SHARED-043 — Merge queue on main

## 1. Outcome and rationale

A pull request merges into `main` only after `pr-gate` has passed against the
**merge result**, not against the pull request's own head commit. GitHub's
merge queue builds that result, tests it, and merges it if green.

Today nothing checks the merge result. `main`'s protection has
`strict: false`, so a branch may sit arbitrarily far behind `main` and still
show a green `pr-gate`. Two failure shapes follow, and both were hit on
2026-09-20:

- **A conflict found at the merge button.** PR #38 and PR #39 both edited the
  `specs/hetzner/` index table. #38 merged; #39 then reported "Branch has
  merge conflicts" with every check green. The conflict was resolved by a
  local rebase and a force-push, which discarded a passing two-cloud
  lifecycle run and started another.
- **A semantic break nothing catches.** Two PRs that do not conflict
  textually can still break each other — one renames a helper, the other adds
  a caller. Each is green alone; `main` is red after the second merge.

The queue removes the first entirely and catches the second before it lands.

`strict: true` ("require branches to be up to date") is the alternative and is
deliberately rejected in §2.

## 2. Scope and non-goals

In scope:

- `.github/workflows/lifecycle-test.yml`: a `merge_group` trigger, and the
  `changes`, `lifecycle-*` and `pr-gate` jobs taught to behave correctly under
  it.
- `main`'s branch protection: require a merge queue, configured as §3.4.
- `docs/adr/` — a short ADR recording why the lifecycle pair does not re-run
  inside the queue.

Not in scope: changing which checks are required (`pr-gate` stays the single
one), the lifecycle jobs' own content, and `ci:lifecycle` as the operator
handle for the heavy half.

**Rejected: `strict: true`.** It forces every pull request to be up to date
before merging, so each merge to `main` invalidates every open pull request
and re-runs `pr-gate` on all of them. With a label-gated two-cloud lifecycle
run at roughly 55 minutes and about 1 USD (SHARED-035 §1), that is the most
expensive option available, and it still does not test the merge result — only
a branch that happens to be current.

## 3. Requirements

### 3.1 The workflow must answer `merge_group`

`.github/workflows/lifecycle-test.yml` triggers on `pull_request` and
`workflow_dispatch` only. A merge queue dispatches `merge_group` events. Until
the workflow answers one, `pr-gate` never starts for a queued entry, the queue
waits for a check that cannot arrive, and **every merge into `main` stops**.

Add `merge_group:` to `on:`. This requirement is the reason the queue is a
workflow change and not a settings toggle; enabling the queue first is the one
ordering mistake that takes the repository offline.

### 3.2 Every read of `github.event.pull_request` must have a `merge_group` answer

A `merge_group` event carries no pull request context. Each site below is empty
there and needs an explicit branch:

| Site | Today | Under `merge_group` |
|---|---|---|
| `changes` job's classifier | diffs against `github.base_ref` | diff `github.event.merge_group.base_sha..head_sha` |
| `lifecycle-aws` / `lifecycle-civo` `if:` | reads `labels.*.name` and `head.repo.full_name` | must not run — see §3.3 |
| `lifecycle-*` `target_revision` | `github.event.pull_request.head.sha` | not evaluated, the jobs are skipped |
| `pr-gate`'s `WANTS_RUN` / `WANTS_SKIP` / `HEAD_REPO` | read the two `ci:` labels and the fork check | see §3.3 |

`changes` already fails closed — an uncomputable diff reports
`docs_only=false` and `terraform=infra=true` — so a missed case over-runs the
validate jobs rather than skipping them. Keep that property.

### 3.3 The lifecycle pair does not run inside the queue

Add `github.event_name != 'merge_group'` to both lifecycle jobs' `if:`.

Two reasons. A queued entry has no labels, so the opt-in handle SHARED-035
built does not exist there. And one two-cloud bring-up per queue entry, at
about 55 minutes, would make the queue slower than merging by hand.

`pr-gate`, on a `merge_group` event, therefore requires the six validate
results and records the lifecycle pair as waived, naming the pull request the
evidence came from.

**State the consequence plainly, in the ADR and in the job's own output:** the
lifecycle proof attaches to the pull request's head commit, never to the merge
result. This is not a regression — it is already true today, and on
2026-09-20 PR #39's lifecycle evidence pointed at a commit that the
subsequent rebase replaced. The queue makes the gap explicit instead of
silent. Closing it would need a queue-time lifecycle run, which §2 rejects on
cost.

### 3.4 Queue configuration

| Setting | Value | Why |
|---|---|---|
| Merge method | Squash | `allow_merge_commit` and `allow_rebase_merge` are both false |
| Required check | `pr-gate` | Already the single required check; do not add a second |
| Maximum entries to build | 5 | One author, few concurrent pull requests |
| Minimum entries to merge | 1 | Never hold a solo pull request behind a batch timer |
| Maximum wait to merge | 5 minutes | The ceiling on that hold |

`required_linear_history: true` and squash-only are both compatible with a
merge queue. No other protection setting changes: `enforce_admins` stays on,
`allow_force_pushes` stays off, required approvals stay at 0 (single author).

### 3.5 Ordering

The workflow change merges **first**, through the ordinary pull-request path.
Only once `main` carries a workflow that answers `merge_group` may the queue
be enabled. Enabling the queue first deadlocks the repository (§3.1).

## 4. Testing / acceptance criteria

- A pull request touching only `README.md` goes through the queue and merges.
  `pr-gate` shows one run on the `merge_group` event with the six validate
  results and the lifecycle pair waived.
- A pull request carrying `ci:lifecycle` runs both lifecycle jobs on the
  `pull_request` event, and runs **neither** on the `merge_group` event.
- Two pull requests queued together, where the second is behind the first,
  merge in order with no manual rebase and no "Branch has merge conflicts".
- A pull request whose merge result breaks `make gitops-check`, although each
  side is green alone, is ejected from the queue and `main` stays green. Build
  this case deliberately: one pull request edits a template, the other updates
  the golden baseline.
- `gh api repos/savak1990/vk-lab-platform/branches/main/protection` still
  reports `enforce_admins.enabled: true`, `allow_force_pushes.enabled: false`,
  `required_linear_history.enabled: true`, and `contexts: ["pr-gate"]`.

## 5. Evidence and status history

- 2026-09-20 — created as READY. Measured on `main` at `9925d36`: no merge
  queue, no rulesets, `strict: false`, `contexts: ["pr-gate"]`,
  `required_linear_history: true`, `enforce_admins: true`, 0 required
  approvals, squash-only, `delete_branch_on_merge: true`.
  `allow_auto_merge` and `allow_update_branch` were turned on the same day,
  outside this spec — they are conveniences, not gates, and neither tests the
  merge result.
