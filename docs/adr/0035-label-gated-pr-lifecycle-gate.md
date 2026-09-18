# ADR 0035: A label-gated, two-provider lifecycle check gates merges to main

## Status

Accepted

## Context

`main` had no branch protection and no rulesets: anyone with write access
could push to it directly. No workflow ran on a pull request at all - all three
workflows were `workflow_dispatch` or push-to-main. Every check in this
repository ran because a human remembered to dispatch it.

ADR 0026 built `lifecycle-test.yml` as a manually-dispatched full lifecycle
run, and its Decision 1 justified that trigger in part with:

> untrusted PRs still cannot trigger it (`workflow_dispatch` only)

That premise is now reversed. Constitution §13 requires such a change be
documented rather than made silently, which is what this ADR does.

Two further facts shaped the design. `lifecycle-test.yml` was AWS-only, so the
Civo target - a whole second execution path with its own Terraform stacks and
its own identity mechanism - had never run in an automated check. And a
measured run costs roughly 55 minutes and a little under one US dollar for both
providers in parallel, which rules out running it on every push.

## Decision

### 1. The `ci:lifecycle` label is the trigger, and the gate is red without it

`lifecycle-test.yml` runs on `pull_request` with types including `labeled` and
`unlabeled`. The static checks run on every event. The two-provider lifecycle
runs only when the pull request carries the `ci:lifecycle` label.

Applying the label starts a run against the pull request's current head
commit, so no empty commit or extra push is needed; removing and re-adding the
label is the re-run handle.

The label replaces `workflow_dispatch` as the trusted-context control. Only a
user with write access to the repository can label a pull request, so an
untrusted contributor cannot start a credentialed run. Every credentialed job
additionally carries an explicit
`github.event.pull_request.head.repo.full_name == github.repository` test
rather than relying on GitHub's implicit fork behavior, and `pr-gate` fails a
fork pull request with a message saying a maintainer must re-run it from a
branch in this repository.

A merge queue was considered and rejected. It would run the check once per
merge attempt against `main` plus the pull request, which is a stronger
guarantee, but it surfaces a failure only at merge time and adds a second
triggering mechanism. The cost of that choice is recorded in Decision 4.

### 2. One always-reporting gate job is the required status check

`pr-gate` is the only required check on `main`. Every other job feeds it, and
it runs `if: always()`. Constitution §11 requires exactly this: a required
check that is itself path-filtered can stay pending forever and block a merge
with no way to clear it.

`pr-gate` decides from the changed paths whether the heavy check is required at
all. A pull request touching `terraform/`, `gitops/`, `scripts/`, `tests/`,
`images/`, `go.mod`/`go.sum`, `Makefile`, `.github/workflows/` or
`.github/actions/` needs the label; anything else passes with an explicit
"no infrastructure change" result. That path list is the merge-blocking surface
of this repository. Without it, `pr-gate` would be red whenever the label was
absent, and a one-line documentation fix could not merge without spending 55
minutes on two clouds - which constitution §11's "success or explicit skip"
wording and spec SHARED-019 Requirement 4 both rule out.

### 3. Each provider is an independent chain that always reaches its teardown

One reusable workflow, `lifecycle-provider.yml`, holds `up` -> `test` ->
`down` for a single provider. `lifecycle-test.yml` calls it twice, from two
explicit jobs: `lifecycle-aws` against `vk-lab-ci`/`ci` and `lifecycle-civo`
against `vk-civo-ci`/`civoci`.

Two jobs rather than one matrix job, deliberately. A matrix names its legs
after the whole row - `lifecycle (aws, vk-lab-ci, ci, true)` - so the run graph
collapses both providers into a single box, and the generated name changes
whenever a matrix field is added. Two jobs cost about ten duplicated lines and
buy two stable names and two readable parallel tracks. A matrix would also have
needed `fail-fast: false` to stop one leg cancelling the other; separate jobs
have no such coupling to disable in the first place.

Neither job needs the other, so a failure in one can never stop the other
reaching its own teardown. `down` keeps ADR 0026's shape: a separate job with
its own `if: always()`, because a step-level `always()` does not survive the
runner being torn down.

The Civo leg uses the Let's Encrypt staging issuer. A labeled run happens per
pull request, and production orders would burn the duplicate-certificate quota
this account shares with the personal lab.

Each job keys its concurrency as `lab-<provider>-<project>`, matching
`lab.yml`. This also repairs a drift: CIVO-140 added the provider segment to
`lab.yml`'s group but not to `lifecycle-test.yml`'s, so since then the two
workflows could run against the same project without queueing - the opposite of
what ADR 0026 Decision 1 and constitution §11 claim. The parity claim in
ADR 0026 was true when written and is true again now.

### 4. `strict: false` on the required check, deliberately

Branch protection does not require a branch to be up to date with `main` before
merging. The gate therefore proves "this pull request's code works", not "this
pull request merged into current `main` works". Requiring strictness would
re-run a 55-minute check after every unrelated merge, and the merge queue that
would close the gap properly was rejected in Decision 1. This is a known,
accepted gap, recorded so it is not later read as an oversight.

`required_approving_review_count` is `0`. SHARED-017 Requirement 1 asks for a
pull request, not an approval; requiring one approval on a single-maintainer
repository would lock the maintainer out of their own `main`.

### 5. A leak check, because a successful destroy is not a successful shutdown

`scripts/verify-no-leaks.sh <provider>` runs as the last step of every `down`
job and fails the job if any Bootstrap- or Persistent-lifecycle resource for
that project survives: the state bucket, the backup bucket, the hosted zone,
any SSM parameter under the project prefix, the cluster, the Civo network,
firewalls and reserved IP, and the four Roles Anywhere consumer roles.

It deliberately does not re-check the Disposable layer - ADR 0026 Decision 2
already made `cluster-down.sh` delete leaked disposable resources and still
exit non-zero.

It reads live AWS and Civo APIs rather than Terraform state, because
`bootstrap-down.sh` ends by deleting `s3://<project>-tf-state`: by the time
this runs there is no state left to inspect. It reports a leaked hosted zone by
zone id rather than name, since the fqdn embeds the root domain (§14).

One parameter is exempt: `/<project>/persistent/civo/tls/platform-public`,
which `argo-down` exports on purpose so the next bring-up can skip an ACME
order. The `down` job deletes it first when the stored certificate is a staging
one, classifying by the certificate's own issuer rather than by this run's
input.

The check uses only calls `lab-role` already grants. It looks each Roles
Anywhere consumer role up by exact name rather than enumerating, because
`iam:ListRoles` is deliberately not granted. This matters: ADR 0026 records a
leak check that had no IAM grant at all and therefore "has never actually run",
its failure swallowed by `|| true`. Both directions of this script were
exercised against the live account before it was trusted.

### 6. No scheduled reaper; recovery is a documented dispatch

Spec AWS-020 Requirement 8's tag-based stale-resource reaper remains deferred,
as does its `Ephemeral=true` tag - no resource in this repository carries that
tag today, so the reaper would be a large change to every Terraform stack.

The residual risk is unchanged from ADR 0026 but now costs more: a run that
dies without completing `down` leaves a hosted zone that makes
`require-unique-subdomain.sh` refuse every later run for that project - which,
with a merge gate, means every merge. Recovery is to dispatch `lab.yml` with
`target: full-down`, the CI project name, and the same name in
`confirm_destroy`. That path already exists and needs no new machinery; it is
documented in the README rather than automated.

## Consequences

- A pull request that touches infrastructure cannot merge until one EKS cluster
  and one Civo cluster have been created, tested and destroyed. Direct pushes
  to `main` are rejected.
- A documentation-only pull request merges with no cloud spend.
- Squash is the only merge method, and merged branches are deleted.
- `make gitops-check` and `make specs-check` now gate merges. Neither ran in any
  workflow before. `specs-check` needed a fix to stop it reading other sessions'
  worktrees under `.claude/`, where it had been failing locally.
- `tfsec` stays `soft_fail: true`. Its 41 untriaged findings cannot become a
  merge blocker in the same change that introduces the blocker.
- GitHub holds at most one pending job per concurrency group. Labeling a third
  pull request while two labeled runs are in flight cancels its `lifecycle` job
  rather than queueing it. No infrastructure exists at that point, so nothing
  leaks, but `pr-gate` goes red for a non-obvious reason.
- `lab.yml` still has no cleanup-on-failure step. A failed manual dispatch still
  leaves infrastructure standing; the guarantee added here covers CI runs only.

## Related

- ADR 0026 (this ADR reverses its `workflow_dispatch`-only premise, repairs the
  concurrency-group parity it claims, and keeps its `down`-job shape and its
  disposable-layer sweep)
- ADR 0022 (the naming-convention IAM scoping that lets a new CI project name
  need no IAM change)
- ADR 0023 (the SSM path convention the leak check walks, and why the fqdn is
  private)
- ADR 0029 (the Roles Anywhere consumers the leak check looks up)
- `specs/shared/035-A-pr-lifecycle-gate/spec.md` (the spec this implements)
- `specs/shared/017-P-branch-protection/spec.md` (the branch protection this
  finally applies)
- `specs/aws/020-A-ci-full-lifecycle-validation/spec.md` (Requirement 5's
  trigger, amended here; Requirements 3 and 8 still deferred)
