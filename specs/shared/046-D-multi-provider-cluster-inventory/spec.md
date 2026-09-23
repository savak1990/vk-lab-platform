---
id: "SHARED-046"
title: "make clusters lists every provider's live clusters, not only AWS"
status: "DONE"
priority: "P2"
milestone: "M2"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "One script, two new listing arms and a jq grouping; the judgement is in which provider's tags can be trusted as a filter"
effort_estimate: "Half a session (2 h), no live apply required"
estimate_confidence: "high"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-23"
updated: "2026-09-23"
completed: "2026-09-23"
---

# SHARED-046 — multi-provider cluster inventory

## 1. Outcome and rationale

`make clusters` answers "is anything running right now, and for how long?"
for every provider in one invocation, and names any provider it could not
look at.

It answered for AWS only. `aws eks list-clusters` was the whole of it, so a
live Civo or Hetzner cluster was invisible. That is the worst failure this
particular command can have: an operator runs it after a teardown, reads
`No EKS clusters`, and walks away from a running bill.

The gap was found in practice. A Hetzner teardown in the session that produced
this spec needed three CLIs driven by hand to prove the account was clean —
servers, load balancers, volumes, primary IPs and firewalls — which is exactly
the work this command exists to remove.

## 2. Scope and non-goals

In scope: `scripts/clusters.sh`, a test for it, the constitution §17 clause
that bound the command to EKS, and the `README.md` and `docs/architecture.md`
lines that repeat the AWS-only claim.

Not in scope: the `local` (kind) target, which owns no cloud resources and
costs nothing to leave running. Not in scope: an Argo column for Hetzner
(§3.3). Not in scope: SHARED-045's multi-region AWS work — this discharges
only its §3.4 clause about this one script, not the region split itself.

## 3. Requirements

### 3.1 One invocation covers every provider

`make clusters` MUST sweep aws, civo and hetzner together and MUST NOT be
narrowed by an inherited `PROVIDER`, `PROJECT_NAME` or `REGION`.

That is not the default. `Makefile:1` exports all three into every recipe, and
`provider.sh`'s `export X="${X:-default}"` cannot then change them — once
exported non-empty they freeze for the life of the process. So the script
unsets them and each arm exports its own `PROVIDER`.

Each arm is a paren-bodied function, `list_x() ( ... )`, so the body *is* a
subshell and one arm's `PROVIDER` cannot reach the next.

### 3.2 What identifies a platform cluster, per provider

| Provider | Marker | Why |
|---|---|---|
| aws | tag `Scope=platform` | §16; set by `default_tags`, reliable |
| hetzner | label `scope=platform` on each server | `hcloud-nodes/main.tf` sets it on every server and ignores no change to it |
| civo | **nothing** — every cluster is listed | see below |

Civo rows MUST NOT be filtered on a tag. Civo's update API rejects tags, so
`terraform/modules/civo-k8s/main.tf` carries `ignore_changes = [tags, ...]`
and §16 already calls Civo tagging best-effort. A running, billing cluster can
therefore carry no tags at all, and for a bill-safety command an extra row
costs a glance while a hidden row costs money. The project name is recoverable
without a tag: `civo-k8s/main.tf` sets `name = var.project`, so the cluster's
name **is** the project's name.

Civo's CLI is region-scoped and answers "zero matches" for a cluster in
another region, so every region `catalog_regions civo` lists MUST be asked.
The row names the region it was found in. Hetzner's server list is
account-wide and needs no region loop.

### 3.3 Hetzner has no cluster object, and no Argo column

Hetzner sells no managed Kubernetes, so there is nothing to list. A cluster
there is the set of servers sharing a `project` label, and the row is grouped
from them:

- PROJECT and CLUSTER are both the `project` label — on that target
  `CLUSTER_NAME` equals `PROJECT_NAME`, so the duplication is correct
- STATUS is the servers' common status, or the literal `mixed` when they
  disagree, because a partly-off cluster must not read as healthy
- NODES is the group's size
- AGE is the **oldest** server's, which is the control plane's. An ISO 8601
  stamp sorts lexically, so this needs no date parsing
- ARGO is `-`

ARGO stays `-` deliberately. Reading it routes through `hetzner_kubeconfig`,
which costs an SSM lookup, a KMS decrypt and an SSH poll of the control plane
of up to `HETZNER_K3S_WAIT_SECONDS` — 600s by default — **per cluster**, and
needs a private key that only some projects commit. An inventory command
cannot pay that. `make status` and `kubectl` answer Argo health for a project
already known.

### 3.4 A provider that cannot be reached is named, never omitted

A missing CLI, an undecryptable token or a dead API MUST print what was
skipped, and MUST NOT stop the other arms or change the exit code. Silence
from this command reads as "nothing is running", which is the one answer that
costs money. Every early return prints a line, and every arm is called with
`|| true`.

### 3.5 The latent bug this fixes on the way past

Before this change, `PROVIDER=civo make clusters` ran the EKS listing while
`argo_state` took its **civo** arm, so every ARGO cell read
`unknown (cluster unreachable)`. The inherited `PROVIDER` selected the Argo
path and not the listing path. §3.1's unset closes it, and the aws arm exports
`PROVIDER=aws` for the same reason rather than trusting what it inherited.

### 3.6 Two defects the first CI run found

Both were invisible locally, and both are now pinned by tests that fail without
their fix.

**An absent timestamp MUST NOT acquire an age.** GNU `date -d ''` succeeds and
answers today at midnight, so a Civo cluster with no `created_at` reported an
age of however long the day had been — a fabricated number in the one column an
operator reads to decide whether something has been billing too long. BSD
`date` refuses the empty string, so a developer's Mac printed `-` and the bug
appeared only on a Linux runner. `age_of` now returns `-` before it calls
`date` at all.

**A decrypted token MUST NOT be able to reach a printed column.** `civo_token`
emits an `::add-mask::` line under Actions, and `argo_state`'s civo arm
decrypts again *inside* the `$( )` that fills the ARGO column — so that line was
captured as the column's value. GitHub honours `::add-mask::` only at the start
of a line, so printed mid-row it is ignored and the token would have appeared in
clear text in a public repository's logs. The arm now lets the first mask reach
the log unsuppressed, then blanks `GITHUB_ACTIONS` so no later decrypt can
re-emit it.

The second is why this spec's tests set `GITHUB_ACTIONS`. A test that does not
cannot exercise the masking path at all, and that is precisely how the defect
survived a green local run.

## 4. Testing / acceptance criteria

1. `tests/scripts/clusters-test.sh` passes under `make scripts-check`, with no
   credentials and no cloud.
2. `civo` absent from `PATH` prints `(civo: CLI not installed - skipped)` and
   still exits 0. This is the assertion that matters: the difference between
   "no Civo clusters" and "I could not look".
3. Three Hetzner servers sharing a `project` label, one of them `off`, become
   exactly one row with NODES `3` and STATUS `mixed`. A fourth server with no
   `scope=platform` label is not listed.
4. A Civo cluster whose JSON has no `created_at` still gets a row, with AGE
   `-`.
5. `make clusters` against an empty account names all three providers.
6. `PROVIDER=hetzner make clusters` and `PROVIDER=civo REGION=FRA1 make
   clusters` produce output identical to `make clusters`.
7. A live cluster appears in the right arm with a climbing AGE, and is gone
   after `make down`.
8. With a `date` that answers `-d ''` the way GNU does, an absent `created_at`
   still yields AGE `-` (§3.6). The test supplies that `date`, so the case is
   reproducible on a Mac as well as a runner.
9. No line of output outside an `::add-mask::` directive contains a decrypted
   token, with `GITHUB_ACTIONS` set (§3.6).

Criteria 1-6, 8 and 9 need no cloud resources. Criterion 7 is the only one that
does.

## 5. Risks and deferred work

- **Civo's `.created_at` is inferred, not observed.** `-o json` returns the raw
  API object — `argo-watch.sh` reads snake_case `.num_target_nodes` and
  `.instances[].hostname` from it — so the field is very likely present, but the
  CLI's own documented field list omits it. `(.created_at // "")` feeds
  `age_of`, which now refuses an empty argument outright (§3.6). Criteria 4 and
  8 pin that degradation on both `date` implementations, so the worst case is a
  missing age, never a crash and never a fabricated one.
- **A non-platform Civo cluster would be listed** (§3.2). Accepted. If the
  account ever holds one, append ` (untagged)` to its STATUS rather than
  dropping the row.
- **Deferred: the Argo column on Hetzner** (§3.3). The upgrade path is recorded
  in the script at the line that prints `-`.
- **Deferred: multi-region AWS.** SHARED-044 §5.1 deferred it and SHARED-045
  §3.4 carries it forward; the aws arm still reads `LAB_REGION` only. That is
  correct today, because ADR 0040 fixes the platform to one AWS region.

## 6. Evidence and status history

**Implemented and verified 2026-09-23**, offline plus a live read of an empty
account.

Criteria 1-4, 8 and 9, `make scripts-check`:

    SCRIPTS-CHECK: tests/scripts/clusters-test.sh
    CLUSTERS-TEST: ok - a missing CLI is reported, hetzner servers group by
    project, no token reaches a row, and an absent age stays '-' on either date.

The first CI run failed here, and earned its keep: it found both §3.6 defects,
neither of which a Mac can reproduce. Criterion 8's fake `date` was written
afterwards and verified by reverting the fix — without the guard it reports
`365d` for a cluster with no timestamp, which is the shape of the original
failure.

`shellcheck -x -S warning` clean, and the test was picked up by the existing
`tests/scripts/*-test.sh` glob with no registration.

Criteria 5 and 6, against the real account after a Hetzner teardown:

    PROJECT                  CLUSTER                      STATUS   NODES  AGE    ARGO
    (aws: no EKS clusters in eu-west-1)
    (civo: no clusters in LON1 NYC1 FRA1 MUM1)
    (hetzner: no servers labelled scope=platform)

`PROVIDER=hetzner make clusters` and `PROVIDER=civo REGION=FRA1 make clusters`
both printed exactly that, which is criterion 6 and the §3.5 fix. Both tokens
decrypted, so the four Civo regions and the Hetzner account were really
queried rather than skipped.

**Outstanding: criterion 7.** No cluster was live on any provider when this
shipped, so a populated row has not been observed against a real API. Two
field paths are therefore unconfirmed: Civo's `.created_at` (§5) and Hetzner's
`.datacenter.location.name`. Both are guarded by `// "-"` or by `age_of`'s
fallback, so the failure mode is a `-` in one cell. The next Hetzner or Civo
bring-up for any other reason answers it at no extra cost.

**This spec discharges SHARED-045 §3.4** and its acceptance criterion 4 for
the Civo and Hetzner arms, by naming the region in each row. SHARED-045 keeps
that clause for the AWS arm, which it changes for its own reasons.
