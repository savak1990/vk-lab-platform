# Specs folder reorganization — design

Date: 2026-09-17. Status: approved in chat.

## Goal

Sort every spec into one folder per target, and show each spec's status in its
folder name. This change is file organization only: it does not change spec
requirements, dependencies, or body content.

## Target layout

```
specs/
  README.md      new: layout, status letters, status protocol
  aws/           AWS-only specs, id AWS-NNN
  civo/          unchanged package (README, roadmap, architecture, decisions, research)
  hetzner/       unchanged package
  local/         local-target specs, id LOCAL-NNN
  shared/        cross-provider specs, id SHARED-NNN
```

## Folder name

`NNN-X-name`, for example `aws/025-Z-kafka`.

- `NNN` (with sub-numbers such as `006-1`) and the front-matter `id` are the
  stable identifiers. They never change.
- `X` is the status letter. It changes when `status:` changes, and the folder
  is renamed in the same commit.

## Status letters

| Letter | Meaning | Front-matter `status:` values |
|---|---|---|
| D | done | `DONE` |
| A | active | `IN_PROGRESS`, `IN_REVIEW` |
| P | planned | `DRAFT`, `READY`, `BLOCKED` |
| Z | closed, not done | `DEFERRED`, `SUPERSEDED`, `CANCELLED` |

The front matter keeps the exact status; the letter is a coarse view of it.
`DEFERRED` and `SUPERSEDED` are new values added to the civo/hetzner protocol.

## Header for aws, shared and local specs

These specs get YAML front matter; today they have none.

```yaml
---
id: "AWS-011"
status: "DONE"
updated: "2026-09-17"
---
```

- The `id` comes from the folder number (`006-1` gives `AWS-006-1`), not from
  the in-file title. Nine titles carry an old number (for example `013-secrets`
  is titled "# 012 — Secrets"). They stay as they are; this is out of scope.
- An existing `**Status:** <text>` line becomes `**Status note:** <text>`
  with the free text kept. A spec without a status line gets no note.
- Civo and hetzner specs keep their front matter unchanged.

## Classification and status

### aws/

| Spec | Letter | status | Evidence |
|---|---|---|---|
| 001-bootstrap | D | DONE | `terraform/live/bootstrap`, `terraform/live/account/kms` exist |
| 002-persistent-foundation | D | DONE | recorded Implemented |
| 003-network-and-eks | D | DONE | recorded Implemented |
| 004-argocd-bootstrap | D | DONE | recorded Implemented |
| 005-storage-contract | D | DONE | recorded Implemented |
| 006-karpenter | D | DONE | recorded Implemented |
| 006-1-karpenter-node-lifecycle | D | DONE | recorded Implemented |
| 007-postgres | D | DONE | recorded Implemented |
| 007-1-postgres-persistence-recovery | D | DONE | recorded Implemented |
| 007-2-secrets-for-postgres | D | DONE | recorded Implemented |
| 009-observability | D | DONE | recorded Implemented (aws target) |
| 010-envoy-gateway | D | DONE | no status line; `gitops/templates/platform/shared/envoy-gateway/` exists |
| 011-nlb-edge | D | DONE | recorded Implemented |
| 012-external-dns | D | DONE | recorded Implemented |
| 013-secrets | D | DONE | no status line; `gitops/templates/platform/shared/external-secrets/` exists |
| 014-lifecycle | D | DONE | no status line; Makefile `up`, `down`, `full-up` exist |
| 015-github-oidc-bootstrap | D | DONE | recorded Implemented |
| 016-github-actions-lifecycle | D | DONE | recorded Implemented |
| 018-atlantis-terraform-automation | P | READY | not built (`docs/architecture.md` target-state gaps) |
| 020-ci-full-lifecycle-validation | A | IN_PROGRESS | `lifecycle-test.yml` implements it with the ADR 0026 deviation; `cleanup-stale-ci.yml` does not exist |
| 021-vpc | D | DONE | recorded Implemented |
| 025-kafka | Z | DEFERRED | recorded Deferred (ADR 0017) |
| 026-debezium | P | READY | not built; depends on deferred 025 |
| 028-pod-density-ipv6 | P | READY | "none implemented yet" |
| 029-tracing-otel | Z | DEFERRED | `docs/architecture.md`: deferred (ADR 0018) |
| 030-cluster-status-badge | P | READY | recorded Proposed; no badge workflow |
| 031-non-home-region-cluster | Z | DEFERRED | title "(Deferred)", ADR 0024 |
| 032-argo-bootstrap-resilience | D | DONE | recorded Proposed is stale: root `retry` limit, `ARGO_UP_WATCH_SECONDS` ceiling, fail-fast report in `argo-up.sh`, Gateway health check in `gitops/argocd/values.yaml` all exist |
| 033-lbc-webhook-cert-churn | A | IN_PROGRESS | recorded Partially implemented |

`READY` is used for not-started AWS specs because they have no draft/review
history to distinguish.

### shared/

| Spec | Letter | status | Evidence |
|---|---|---|---|
| 000-constitution | D | DONE | standing rulebook in force |
| 017-branch-protection | P | READY | GitHub API: `main` is not protected |
| 019-ci-fast-validation | P | READY | no `validate.yml` |
| 023-e2e-test-framework | D | DONE | `tests/e2e/` suite and framework exist |
| 027-alt-cloud-targets | Z | SUPERSEDED | recorded Superseded by `specs/civo/` |
| 034-github-secrets | P | READY | recorded Ready, not started |

### local/

| Spec | Letter | status |
|---|---|---|
| 022-local-dev-mode | P | READY |
| 024-ci-kind-integration-test | P | READY |

024 goes to `local/`: it runs the `local` target on kind and has no AWS resources.

### civo/ and hetzner/

The letter comes from the existing `status:` field, as recorded. No status is
changed. Known recorded-vs-history gaps (civo 170 READY but deferred by the user;
hetzner 120 and 182 DRAFT but promoted to READY in history) all map to `P`
either way and stay as recorded. `civo/185-aws-logical-backup-migration` stays
in `civo/`.

## References

Fix in this change:

- `CLAUDE.md`, `README.md`, `docs/architecture.md`, `docs/argocd-design.md`,
  `docs/architecture-review-2026-09-06.md`, `docs/civo-high-level-design.md`,
  `docs/hetzner-high-level-design.md`, ADRs 0001, 0002, 0014, 0017, 0026, 0027,
  0032, `terraform/live/cluster/README.md`, `tests/manual/024-kafka.md`,
  `scripts/cluster-down.sh` comment (only if its path changes).
- Paths and relative links inside `specs/`, including the civo and hetzner
  README index tables.
- The civo and hetzner README rule "the folder name is the stable identifier":
  the number and `id` are stable; the letter follows `status:`. The letter
  table lives once in `specs/README.md`; the package READMEs link to it.

Leave as is:

- Paths in `docs/superpowers/plans/`: records of completed runs.
- Prose mentions such as "spec 025", `CIVO-070`: IDs, not paths.
- Paths that were already wrong before this change (for example ADR 0017's
  `specs/024-kafka`) are corrected to the new real path where the target is
  clear.

## Method

- Rename with plain `mv`; git detects renames at commit time. Move one folder,
  stage, and confirm git reports a rename before moving the rest.
- One commit for the moves and header edits, one for reference fixes, so the
  rename commit stays near 100% similarity.

## Verification

A script under `scripts/` checks:

1. No `specs/NNN-` path (old top-level form) remains outside
   `docs/superpowers/plans/`.
2. Every relative markdown link inside `specs/` resolves.
3. Every spec folder has front matter with `id` and `status`, and its letter
   matches `status:` under the table above, in both directions.

## Risk

Other worktrees (`civo-185-foundations`, `civo-130-e2e-tests`) edit
`specs/civo/` files. After this merges, those branches see rename conflicts;
git rename detection resolves most of them on merge.
