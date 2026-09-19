---
id: "SHARED-036"
title: "Per-pull-request CI projects, so parallel lifecycle checks run in parallel"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Workflow and naming changes plus a scheduled reaper; the design decisions are settled below"
effort_estimate: "One to two sessions, plus provider quota requests that take days to be granted"
estimate_confidence: "medium"
depends_on: ["SHARED-035"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-19"
---

# SHARED-036 — Per-pull-request CI projects

## 1. Outcome and rationale

Two pull requests carrying `ci:lifecycle` run their lifecycle checks at the same
time, instead of one waiting for the other.

**Priority 3, optional.** The current design is correct and safe; it is slow
under parallel load. Do this when several agents routinely hold labeled pull
requests open at once and the queueing becomes the bottleneck. Until then the
queue costs latency, not correctness.

## 2. The problem

SHARED-035 runs every labeled pull request against two fixed CI projects:
`vk-lab-ci`/`awsci` on AWS and `vk-civo-ci`/`civoci` on Civo. Each cluster job
takes a concurrency lock named after its project, shared by every pull request:

| Lock | Key | Shared across pull requests? |
|---|---|---|
| Workflow | `lifecycle-test-<PR number>` | no |
| Cluster job | `lab-aws-vk-lab-ci`, `lab-civo-vk-civo-ci` | **yes** |

So static validation runs in parallel, but the clusters serialize. The lock is
held across the whole `up` -> `test` -> `down` chain, so a second pull request
starts only after the first has **finished tearing down**:

```
PR A:  validate -> [up -> test -> down] --------------------------> result ~50 min
PR B:  validate -> waiting ............ -> [up -> test -> down] --> result ~100 min
```

This is safe - two runs never touch the same Terraform state or cluster - but
it scales badly with parallel work. Three consequences:

1. **Latency grows linearly.** The Nth labeled pull request waits for N-1 full
   lifecycles, roughly 50 minutes each, bounded by the AWS leg.
2. **A third pull request is cancelled, not queued.** GitHub keeps at most one
   pending job per concurrency group. With A running and B waiting, C's arrival
   cancels B's cluster job. B never started, so nothing leaks, but its
   `pr-gate` goes red with `the aws lifecycle did not pass (cancelled)` and must
   be re-labeled.
3. **One orphan blocks everyone.** A run killed mid-bring-up leaves a hosted zone
   and SSM parameters that make `require-unique-subdomain.sh` refuse the shared
   project. Every open pull request's gate then stays red until
   `scripts/force-clean-ci.sh` runs. This happened on 2026-09-18.

With one maintainer the queue is rarely deep. With several agents working
different tasks at once, it is the bottleneck.

## 3. Why not simply use per-pull-request names now

Naming each run's project after its pull request - `vk-lab-ci-pr42`,
`awsci-pr42` - removes the shared lock and gives real parallelism. Several
objections to it do **not** hold, and are recorded so they are not raised again:

- **Cost.** Each run costs about one US dollar regardless of its name. Parallel
  runs overlap in time; total spend is runs times one dollar either way.
- **Blast radius.** Per-pull-request names *shrink* it: an orphan blocks only its
  own pull request instead of all of them.
- **Let's Encrypt.** The Civo leg uses the staging issuer, whose limits are far
  above what parallel CI needs.
- **IAM.** `lab-role` scopes by naming wildcard (`*-eks`, `*-tf-state`, ADR
  0022), so a new project name needs no IAM change.
- **Name length.** `vk-civo-ci-pr1234` is 17 characters, inside the 23-character
  limit `require-valid-project-name.sh` derives from the EKS node-group role.

The objections that **do** hold, and are why this is not done yet:

### 3.1 Provider quotas cap parallelism far below "unlimited"

Measured 2026-09-19 against the live accounts, with one Civo CI cluster running:

| Civo resource | One CI cluster uses | Account limit | Clusters that fit |
|---|---|---|---|
| CPU cores | 6 | 16 | **2** |
| Disk GB | 192 | 400 | **2** |
| Disk volumes | 8 | 16 | **2** |
| Networks | 1 | 10 | 9 |

| AWS resource (`eu-west-1`) | One project uses | Quota | In use at rest |
|---|---|---|---|
| VPCs | 1 | 5 | 2 |

Civo fits **two clusters at once, and the personal Civo lab counts as one of
them.** With the lab up, per-pull-request names buy exactly one extra parallel
slot. AWS fits roughly three more projects.

### 3.2 A quota wall fails ugly, where the queue fails clean

The concurrency lock makes an extra run **wait**. A quota does not: the extra run
gets partway through `up` - network, firewall and reserved IP already created -
before Civo refuses the node pool. The run dies holding orphans, by
construction. Per-pull-request names without a cap would turn clean queueing
into routine orphan creation.

### 3.3 Orphans stop announcing themselves

With shared names a leak is loud: the next run collides with it. With unique
names, `vk-civo-ci-pr42` leaks and nothing ever reuses the name, so it bills
until someone looks. `verify-no-leaks.sh` catches leaks at the end of a run that
finishes; it cannot catch a run that was killed. AWS-020 Requirement 8's
scheduled reaper, deferred so far, becomes mandatory.

### 3.4 The queue is also a spending throttle

Five agents labeling at once costs about one dollar per hour today. With
per-pull-request names it costs about five dollars in the same hour, with
nothing slowing it.

### 3.5 It reverses a constitutional rule

Constitution §11 requires "one shared, isolated CI environment" with serialized
runs. Per-pull-request projects reverse that, which constitution §13 requires be
recorded in an ADR rather than done silently.

## 4. Scope and non-goals

In scope:

- Raising the Civo and AWS quotas as a prerequisite.
- Per-pull-request CI project and subdomain names.
- A cap on concurrent CI clusters, below the raised quota.
- A scheduled reaper for abandoned CI projects.
- An ADR amending constitution §11 and ADR 0035.

Non-goals:

- AWS-020's separate `terraform/live/ci/` state tree. Isolation stays by
  project name.
- Changing what the lifecycle check verifies.
- Per-pull-request names for `lab.yml`'s manual dispatches.

## 5. Requirements

1. **Quotas first.** Before any per-pull-request naming lands, the Civo quota
   MUST be raised enough for at least three concurrent CI clusters plus the
   personal lab, and the AWS VPC quota in `eu-west-1` enough for at least three
   concurrent AWS CI projects plus the personal lab. Record the request, the
   granted values and the date. Both are soft limits raised through the
   providers' support channels at no charge.
2. **Names derive from the pull request.** A labeled run MUST use a project and
   subdomain derived from its pull request number, within the 23-character
   project-name limit. A manual `workflow_dispatch` of `lifecycle-test.yml` MUST
   keep a fixed name, so it stays serialized.
3. **Parallelism MUST be capped below the quota.** A run that would exceed the
   cap MUST wait, not start. Hitting a provider quota mid-bring-up is the failure
   this spec exists to prevent (§3.2). The cap MUST leave room for the personal
   lab.
4. **A reaper MUST exist.** A scheduled workflow MUST find CI projects whose pull
   request is closed or whose run ended without a successful `down`, and run
   `scripts/force-clean-ci.sh` against each. It MUST identify candidates by the
   CI naming pattern and never touch `vk-lab-platform` or `vk-civo-lab`.
5. **Per-run cleanup stays.** `verify-no-leaks.sh` MUST still run at the end of
   every `down`. The reaper covers killed runs; it does not replace the per-run
   check.
6. **An ADR MUST record the reversal** of constitution §11's single shared CI
   environment, the quota values it rests on, and the cap.

## 6. Implementation hints

- A pool of N fixed slots - `vk-lab-ci-1` ... `vk-lab-ci-N` - is simpler to cap
  than open-ended per-pull-request names, because each slot keeps its own
  concurrency lock and GitHub queues on it natively. Assigning slot
  `pr_number % N` needs no coordination, at the cost of occasionally queueing two
  pull requests that hash to the same slot while another slot is idle. Weigh this
  against true per-pull-request names plus an explicit cap.
- GitHub concurrency groups cannot express "at most N concurrent" directly. A
  slot pool gets the cap for free; open-ended names need the cap enforced some
  other way.
- `force-clean-ci.sh` already refuses a zone the project's own state tracks, and
  a zone holding records beyond its NS and SOA. The reaper can call it as-is.

## 7. Testing / acceptance criteria

1. Two pull requests labeled together run their lifecycles concurrently; neither
   waits for the other.
2. A pull request labeled beyond the cap waits and then runs; it does not start
   and fail against a quota.
3. A deliberately killed run leaves an orphan that the next reaper run removes,
   and the reaper leaves `vk-lab-platform` and `vk-civo-lab` untouched.
4. The personal Civo lab can be brought up while CI runs are in flight.
5. The raised quota values are recorded in this spec.
