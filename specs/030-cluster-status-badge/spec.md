# 030 — Cluster Status Badge

**Status:** Proposed

**Complexity:** Small
**Risk:** Low — read-only against AWS; the only mutating action is the
workflow committing a small state file back to this repo.
**Estimated cost:** ~0.5 day · AWS runtime cost: negligible (a few
`DescribeCluster`/read-only API calls every poll interval, none of them
billed). GitHub Actions cost: free on a public repo, bounded by the poll
interval (Implementation hints).
**Recommended model:** Sonnet.
**Depends on:** 016-github-actions-lifecycle (`personal-lab-role`, OIDC auth,
the `vars.AWS_ROLE_ARN` repo variable already wired by `make github-vars-up`).
**Lifecycle class(es) touched:** None — this is read-only observability
tooling, not part of `make up`/`make down`, and creates no AWS resource.

## Scope

A scheduled GitHub Actions workflow that polls whether the disposable EKS
cluster is currently up, and a badge in `README.md` that reflects that state
- not whether the last `lab.yml` dispatch succeeded, which
a plain workflow-status badge would show instead and which is a poor proxy
for current state (a successful `lab-up` followed by a later `lab-down`
still reads as green on a workflow-status badge).

Excludes: any change to `lab.yml`/`make up`/`make down`
themselves; any new AWS resource; any alerting/notification (Slack, email -
out of scope per spec 016's own precedent of leaving notifications
optional); a general-purpose observability dashboard (Prometheus/Grafana,
specs 009/029 already own that for in-cluster metrics - this spec is
specifically the always-visible, no-login-required badge on the repo's
front page).

## Requirements

1. A new scheduled workflow (e.g. `.github/workflows/cluster-status.yml`),
   `on: schedule` plus `workflow_dispatch` for manual/on-demand checks, MUST
   authenticate the same way `lab.yml` do - OIDC via
   `personal-lab-role` (`vars.AWS_ROLE_ARN`), no new IAM role and no new
   long-lived credential.
2. Core check (MUST): `aws eks describe-cluster --name <cluster>`. A
   `ResourceNotFoundException` means "down"; a response with
   `status: ACTIVE` means "up"; any other status (`CREATING`, `DELETING`,
   `UPDATING`, `DEGRADED`) MUST surface as its own distinct badge state, not
   be collapsed into "up" or "down" - a cluster mid-teardown reading as
   healthy is the specific failure mode this requirement exists to prevent.
3. `personal-lab-role`'s existing `Eks` statement already grants
   `eks:DescribeCluster` scoped to this cluster's ARN (spec 016) - this
   workflow requires no IAM policy change if it stays at the core check
   (Requirement 2). Confirm this before assuming Requirement 4's deeper
   check is free of new grants too.
4. Deeper check (SHOULD, not a blocker for the core badge): once the cluster
   is confirmed `ACTIVE`, chain-assume `eks-access-identity` (same pattern
   `argo-up.sh` uses, spec 016's later amendment) and check node readiness
   (`kubectl get nodes`) and Argo CD application health
   (`kubectl -n argocd get applications`). If added, badge state MUST
   distinguish "cluster up, workloads unhealthy" from "fully healthy" -
   don't silently report green on the coarser signal alone once a finer one
   exists.
5. State MUST be published as a small JSON file committed back to this repo
   (e.g. `badges/cluster-status.json`), not a Gist or other external store -
   this avoids provisioning a new secret (a Gist needs a PAT with `gist`
   scope; the default `GITHUB_TOKEN`, scoped to `contents: write` on this
   repo only, already covers a commit to this repo and nothing more). The
   workflow MUST only commit when the state actually changed (`git diff
   --quiet` guard) - a poll interval in the range this spec expects
   (Implementation hints) would otherwise produce a high-frequency commit
   history of no-op updates.
6. `README.md` MUST render a [shields.io endpoint
   badge](https://shields.io/badges/endpoint-badge) pointing at that
   committed file's raw GitHub URL (`raw.githubusercontent.com/.../badges/
   cluster-status.json`) - no third-party badge host needs write access to
   this repo or any AWS credential.
7. The committed JSON MUST NOT contain the AWS account ID, cluster ARN, or
   any other value not already public in this repo (constitution's "hygiene,
   not a security control" framing for non-secret identifiers still applies
   - keep the badge payload to a state label, a color, and a last-checked
   timestamp).

## Implementation hints

- Poll interval: start at 15-30 minutes (`schedule: cron: '*/15 * * * *'` or
  `'*/30 * * * *'`) - tight enough to be useful, loose enough to keep commit
  volume and Actions-minutes usage low. Revisit only if it proves too coarse
  in practice.
- GitHub disables a repo's scheduled workflows automatically after 60 days
  with no repository activity - note this in the workflow's own comments so
  a long-idle lab doesn't leave a silently-stale badge; `workflow_dispatch`
  is the manual escape hatch to refresh it.
- Guard against the badge-commit triggering other workflows unnecessarily:
  either scope the commit to skip CI (`[skip ci]` in the message, checked
  against whatever fast-validation workflow spec 019 added) or add a
  `paths-ignore` entry for `badges/**` to that workflow.
- Shields.io endpoint-badge JSON shape:
  `{"schemaVersion": 1, "label": "cluster", "message": "up", "color": "brightgreen"}`
  (or `"down"`/`"red"`, `"degraded"`/`"orange"`, per Requirement 2's distinct
  states).
- Reuse `require-*.sh`-style small, single-purpose scripts
  (`scripts/cluster-status-check.sh`) rather than inlining a long shell
  block in the workflow YAML, matching this repo's existing convention.

## Testing / acceptance criteria

- With the cluster down: workflow run reports `"down"`/red, badge in
  `README.md` reflects it within one poll interval of a manual
  `workflow_dispatch`.
- With the cluster up and healthy (post `make up`/`lab.yml` with `target=up`):
  badge reflects `"up"`/green (or the deeper-check equivalent, if
  Requirement 4 is implemented) within one poll interval.
- Mid-teardown (`lab.yml` with `target=down` in progress): badge reflects a
  distinct transitional state, never silently reads as `"up"`.
- No AWS resource is created or destroyed by this workflow, confirmed via
  the IAM policy: it needs no permission beyond what spec 016 already
  granted for the core check (Requirement 3).
- A run where cluster state hasn't changed produces zero new commits
  (Requirement 5's diff guard actually works, not just documented).
- The committed JSON contains no account ID/ARN/other non-public identifier
  (Requirement 7), confirmed by inspection of a real committed file.
