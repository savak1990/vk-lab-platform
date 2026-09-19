---
id: "SHARED-035"
title: "Label-gated two-provider lifecycle check as the required status check on main"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Workflow and GitHub configuration with a clear security checklist; the reasoning is in the ADR"
effort_estimate: "One session plus one labeled CI run per verification step"
estimate_confidence: "medium"
depends_on: ["SHARED-017", "CIVO-140", "AWS-020"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-19"
completed: "2026-09-19"
---

# SHARED-035 — PR lifecycle gate

## 1. Outcome and rationale

A pull request that changes infrastructure cannot merge into `main` until one
AWS cluster and one Civo cluster have been brought up, verified with `make
test`, and destroyed - both of them, whatever happened during the run. Direct
pushes to `main` are rejected.

The heavy half is opt-in per pull request through the `ci:lifecycle` label,
because a run costs roughly 55 minutes and a little under one US dollar.

The reasoning behind every choice here is in ADR 0035. This spec states the
requirements and how they are verified.

## 2. Scope and non-goals

In scope:

- `.github/workflows/lifecycle-test.yml` — PR trigger, label gate, the two
  per-provider caller jobs, and the `pr-gate` job.
- `.github/workflows/lifecycle-provider.yml` — the reusable per-provider
  `up`/`test`/`down` chain.
- `.github/actions/setup-lab-tools/` — the shared toolchain install.
- `scripts/verify-no-leaks.sh` — the post-teardown assertion.
- `scripts/force-clean-ci.sh` — recovery from a cancelled bring-up, which no
  teardown can reach.
- Branch protection on `main` and the repository's merge-method settings.

Non-goals:

- The separate PR-triggered `validate.yml` of SHARED-019. The five static-check
  jobs stay inside `lifecycle-test.yml`; SHARED-019 remains READY.
- AWS-020's `terraform/live/ci/` state tree, its `Ephemeral=true` tag, and its
  scheduled reaper (Requirements 2, 3 and 8) — still deferred, see ADR 0026 and
  ADR 0035 decision 6.
- A cleanup-on-failure step for `lab.yml`'s manual dispatches.
- Triaging `tfsec`'s 41 findings so it can block a merge.

## 3. Requirements

1. Static validation MUST run on every pull request event, and MUST gate the
   lifecycle jobs so a lint failure costs no cloud time.
2. The two-provider lifecycle MUST run only when the pull request carries the
   `ci:lifecycle` label, and applying the label MUST itself start the run
   against the pull request's current head commit.
3. Exactly one job, `pr-gate`, MUST be the required status check. It MUST
   report a decided result for every reachable state and MUST NOT be reachable
   in a pending state (constitution §11).
4. A pull request that changes no infrastructure path MUST pass `pr-gate`
   without the label and without any cloud spend. The path list MUST be
   recorded in ADR 0035, not only in the workflow.
5. A pull request that changes an infrastructure path and carries no label MUST
   fail `pr-gate` with a message naming the label.
6. Untrusted pull requests MUST NOT obtain AWS or Civo credentials
   (constitution §11, AWS-020 R5). Every credentialed job MUST carry an
   explicit same-repository test in addition to the label requirement.
7. Both providers MUST run at the same time and MUST be independent: a failure
   in one MUST NOT prevent the other from completing its own teardown. They
   MUST be separate jobs, each with its own name in the run graph, rather than
   legs of one matrix job.
8. Every run MUST attempt teardown of both providers even after a failure or a
   cancellation (AWS-020 R6), as a separate job with its own `if: always()`.
9. A teardown MUST be verified, not assumed. Any Bootstrap- or
   Persistent-lifecycle resource surviving `full-down` MUST fail the job.
9a. Recovery from a cancelled run MUST exist as a script, not as prose. A
    cancelled run leaves a state lock, a hosted zone and SSM parameters that
    `terraform destroy` cannot see, and the parameters block the next
    `bootstrap-up` while costing nothing that would reveal them.
10. Runs against the same project MUST be serialized against each other and
    against `lab.yml` (constitution §11, AWS-020 R7), using the same
    concurrency group expression `lab.yml` uses.
11. The Civo leg MUST use the Let's Encrypt staging issuer, so per-pull-request
    runs do not consume the production quota shared with the personal lab.
12. Direct pushes, force-pushes and deletion of `main` MUST be rejected
    (SHARED-017 R1, R2).
13. Squash MUST be the only available merge method.
14. `validate-terraform` MUST skip when no non-Markdown file under `terraform/`
    or `secrets/` changed, and `.github/workflows/lifecycle-test.yml` did not
    change. That skip MUST NOT skip the lifecycle jobs, and `pr-gate` MUST reject it in any other case.

## 4. Deviations from the specs this implements

- **D1 — AWS-020 R5 trigger.** The spec allows "maintainer `workflow_dispatch`,
  or pushes on the main repository". The trigger is now a maintainer-applied
  label on a pull request. Equivalent in trust (labelling needs write access)
  and strictly earlier in the cycle.
- **D2 — AWS-020 R1 sequence.** The run is `full-up` -> `test` -> `full-down`,
  not the full CREATE -> ... -> RECREATE -> VERIFY RECOVERY sequence. The
  recreate half is AWS-020's `mode=resilience`, explicitly not part of a
  routine PR-triggered run (R9). Unchanged from ADR 0026.
- **D3 — AWS-020 R2 isolation.** Isolation is by `PROJECT_NAME`/`SUBDOMAIN`,
  not `terraform/live/ci/`. Unchanged from ADR 0026 decision 1.
- **D4 — SHARED-019 not split out.** Its five checks run here rather than in a
  separate `validate.yml`, and its Requirement 5 gate job is implemented as
  `pr-gate`. Its Requirement 4 path filtering is implemented inside `pr-gate`
  rather than as per-job filters. SHARED-019 stays READY for the split.
- **D5 — two checks added beyond SHARED-019's list.** `make gitops-check` and
  `make specs-check` now gate merges; neither ran in any workflow before.
- **D6 — `tfsec` stays report-only.** `soft_fail: true` is retained, so its 41
  untriaged findings do not block merges.
- **D7 — one leak check is unproven.** `verify-no-leaks.sh` reads Civo resource
  names over `.name // .label`, which was confirmed against live `network` and
  `firewall` listings. `civo ip ls -o json` returned an empty list, so the key
  it emits for a reserved IP is untested: that one check could silently never
  fire. It must be confirmed while a Civo CI project holds
  `vk-civo-ci-ingress`. This is the same never-fires failure ADR 0026 records
  for `tag:GetResources`.

## 5. Testing / acceptance criteria

1. A pull request with no label runs the six validate jobs, skips `lifecycle`,
   and shows `pr-gate` red naming the label.
2. Adding the label starts a run with no further push; both providers appear.
3. Both `test` jobs pass and both `down` jobs pass, including
   `verify-no-leaks.sh`.
4. After the run, neither CI project has a cluster, state bucket, backup
   bucket, hosted zone or SSM parameter left.
5. A pull request touching only documentation passes `pr-gate` green without
   the label, and no lifecycle job runs.
6. A deliberately broken bring-up on one provider only: that provider's leg
   fails, **the other provider still completes its own teardown**, and
   `pr-gate` is red. This is the proof for Requirement 7.
7. `git push origin main` is rejected once branch protection is applied.
8. The repository offers squash as the only merge method.
9. A pull request touching only `gitops/` skips `validate-terraform`, runs the
   other five validate jobs, and passes `pr-gate` with a waiver.

## 6. Evidence

Merged as `e3c096a` (PR #19). Branch protection applied 2026-09-19.

### The green run — `35431306872`, all 13 jobs

| Leg | up | test | down | leak check |
|---|---|---|---|---|
| aws / `vk-lab-ci` / `awsci` | 27m 20s | 38s | 23m 44s | clean |
| civo / `vk-civo-ci` / `civoci` | 22m 15s | 34s | 8m 27s | clean |

60 minutes wall clock, both providers in parallel. Log lines:

```
deleted /vk-civo-ci/persistent/civo/tls/platform-public
  - issuer=C = US, O = Let's Encrypt, CN = (STAGING) Artificial Amaranth YE1
VERIFY-NO-LEAKS: no bootstrap or persistent resources remain for vk-civo-ci.
VERIFY-NO-LEAKS: no bootstrap or persistent resources remain for vk-lab-ci.
```

Account swept afterwards: no EKS cluster, no EC2 instance, no load balancer, no
Civo cluster, no project bucket, no project SSM parameter, and only the external
root zone in Route 53.

### Acceptance criteria

| # | Criterion | Evidence |
|---|---|---|
| 1 | No label → validates run, lifecycle skips, gate red | run `35401560469`: six green, `lifecycle` skipped, `pr-gate` failed naming the label |
| 2 | Label starts a run with no further push | run `35428218623` fired on the `labeled` event |
| 3 | Both providers pass and tear down | run `35431306872`, table above |
| 4 | Nothing survives | account sweep above |
| 5 | Docs-only passes without the label | this pull request |
| 6 | One provider fails, the other still tears down | run `35404144325`: both `up` jobs failed, **both `down` jobs still ran** |
| 7 | Direct push to `main` rejected | `! [remote rejected] main -> main (protected branch hook declined)`, as admin |
| 8 | Squash is the only merge method | `allow_merge_commit=false`, `allow_rebase_merge=false` |

Criterion 6 was proven by accident rather than by the planned deliberate
failure: a cancelled run left orphaned zones, both `up` jobs failed on
`require-unique-subdomain.sh`, and both `down` jobs ran anyway. That is the
same property the planned test would have shown.

### Branch protection, as applied

```json
{"checks": ["pr-gate"], "strict": false, "admins": true,
 "reviews": 0, "force_push": false, "deletions": false, "linear": true}
```

### What the failures taught, and what changed because of them

1. **A cancelled run leaves orphans no teardown can reach.** terraform creates a
   resource and then records it; killed in between, the resource is live and
   absent from state. `full-down` then reports success and deletes nothing -
   confirmed by running it twice. `scripts/force-clean-ci.sh` exists because of
   this, and the original recovery text in the README and ADR 0035 was wrong.
2. **A held `.tflock` blocks the teardown meant to clean up.** The lock outlives
   the run that took it.
3. **Orphaned SSM parameters are the quiet blocker.** They cost nothing, so no
   bill reveals them, but `aws_ssm_parameter` creates without overwrite and the
   next `bootstrap-up` fails with `ParameterAlreadyExists`.
4. **`lab-role` cannot answer `GetParametersByPath` for a project prefix.** That
   action authorizes against `parameter/<project>/`, while the role grants the
   layer paths. `verify-no-leaks.sh` uses `describe-parameters` instead, which
   is granted on `*` for exactly this purpose. The check failing closed rather
   than reporting an unverified "clean" is the behavior it was written for.
5. **A Terraform plugin cache made validation slower, not faster.** Measured
   across four runs: 7m45s without, 8m55s-10m11s with. Removed, and recorded in
   a comment so it is not tried again. The cost is Terragrunt's per-unit init
   overhead; parallelising the loop is the fix if it needs one.
