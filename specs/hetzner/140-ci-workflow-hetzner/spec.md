---
id: "HETZ-140"
title: "lab.yml third provider value, hcloud CLI, token mask, label sweep in cleanup-on-failure"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Workflow edits on top of CIVO-140 with one new cleanup path and a Hetzner account-limit constraint"
effort_estimate: "One session (3–4 h) plus one CI run per provider"
estimate_confidence: "medium"
depends_on: ["HETZ-015", "HETZ-045", "CIVO-140"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-140 — CI workflow for Hetzner

## 1. Outcome and rationale

The manual `lab` workflow runs any lifecycle target with
`provider=hetzner`. It decrypts `secrets/hcloud-token.enc` and the SSH key
with the OIDC-assumed role it already uses, never prints either, queues
runs per project-provider, and cleans up on failure by sweeping every
labelled Hetzner resource, not only by destroying servers.

Read `specs/civo/140-ci-workflow-civo/spec.md` first.

## 2. Scope and non-goals

In scope:
- `.github/workflows/lab.yml` input enums and validation.
- The `hcloud` CLI install (pinned, checksummed).
- The token mask pre-step per job.
- The cleanup step's label sweep.
- `provider` in `run-name`, concurrency.

Not in scope: PR validation (spec 019), Kind CI (spec 024),
`lifecycle-test.yml` render of `target=hetzner` (HETZ-050 owns
`lifecycle-test.yml:161-194`).

## 3. Current state / evidence

- `lab.yml:15-41` inputs; `:47-49` concurrency `lab-${project_name}`;
  `:91-95` OIDC role; `:97` `make ${{ inputs.target }}`; `:106-124` test
  job. CIVO-140 adds `provider` (choice `aws|civo`), project and subdomain
  choices, the `civo` CLI, the `civo_token` pre-step, cleanup, and
  `TLS_ISSUER=letsencrypt-staging` / `E2E_INSECURE_TLS=1` on civo.
- `scripts/lib/provider.sh` `hcloud_token` prints `::add-mask::` under
  `GITHUB_ACTIONS` (HETZ-010). The SSH private key is decrypted by
  `configure_kubeconfig` (HETZ-040) into a `mktemp` file with mode 0600
  and removed on exit; it is never a workflow secret or output.
- Hetzner default limit: 5 servers per project (research.md). One
  3-node cluster fits; two do not.

## 4. Design and contracts

- Inputs: `provider` choice `aws|civo|hetzner`; `project_name` choice
  gains `vk-hetzner-lab`; `subdomain` choice gains `hetzner`. The
  validation step fails when provider and project/subdomain disagree.
- Steps: install `hcloud` v1.67.0 from the GitHub release with
  `sha256sum -c` against the published checksums (same pattern as
  Terragrunt at `lab.yml:74-81`). Skip on aws and civo.
- Pre-step on hetzner: `hcloud_token >/dev/null` once per job so the mask
  registers before any output. Emit the mask on stdout; never inside a
  `$(...)` capture.
- Concurrency: `lab-${{ inputs.project_name }}-${{ inputs.provider }}`,
  `cancel-in-progress: false`. Consequence: because the Hetzner project
  allows 5 servers, the CI project and the personal lab cannot both hold a
  3-node cluster. Until a limit increase is granted (one month as a
  customer and a paid invoice), CI runs use the same Hetzner project as
  the lab and must not run while the lab is up. Document this in the
  workflow header comment and in `README.md`.
- Cleanup on failure of `up`, `platform-up`, `full-up`: run `make down`
  with `CI_TEARDOWN_ALLOW_DATA_LOSS=1`. If that fails, run
  `make cluster-down`. In every case, then run the label sweep from
  HETZ-040 directly (`scripts/cluster-down.sh --sweep-only` or the
  equivalent entry point), because on Hetzner a dead server does not reap
  its load balancer, its CSI volumes, or a detached primary IP, and each
  keeps billing. Log every deleted resource by id.
- After `full-down`, delete the TLS parameter
  `/${PROJECT_NAME}/persistent/hetzner/tls/platform-public`, ignoring
  `ParameterNotFound`.
- TLS issuer: every hetzner `up`-like step sets
  `TLS_ISSUER=letsencrypt-staging`. The `test` job sets
  `E2E_INSECURE_TLS=1` on hetzner and calls `hcloud_token` again first
  (mask is per job). Same reasoning as CIVO-140 §4: the rate limit is
  shared with the personal lab. DNS-01 wildcard (HETZ-070) removes the
  HTTP-01 ordering flake but not the quota.
- Secrets: none added. `permissions` unchanged.

## 5. Files/components affected

`.github/workflows/lab.yml`; `README.md` CI section.

## 6. Implementation steps

1. Edit the workflow. Run `actionlint`.
2. Dispatch `status` for aws and for civo: no behaviour change.
3. Dispatch `status` for hetzner. Inspect the log for `***` where the
   token would be.
4. Dispatch `up`, then `down`, for hetzner.
5. Force a failure (wrong `TLS_ISSUER` value) on `up`. Confirm the cleanup
   step runs, the sweep lists and deletes the LB, volumes and primary IPs,
   and `hcloud server list` is empty afterwards.

## 7. Dependencies and blockers

HETZ-015 (ADR 0030 amendment names the token handling), HETZ-045
(scripts), CIVO-140 (workflow shape).

## 8. Acceptance criteria

- Neither the token nor the SSH key is visible in the logs; `set -x` is
  never enabled around them.
- Two simultaneous hetzner dispatches for the same project queue.
- The cleanup step runs on failure of up-like targets and leaves
  `hcloud server|load-balancer|volume|primary-ip list` empty.
- aws and civo dispatches behave as before.
- A hetzner `full-up` run shows `Certificate platform-public` `Ready` with
  `issuerRef.name: letsencrypt-staging`.

## 9. Validation

Offline: `actionlint`. Real cloud: one hetzner up/down through CI, about
0.20 EUR; one aws and one civo `status`.

## 10. AWS regression protection

Default inputs reproduce today's aws behaviour; record one aws `status`
run. Civo: record one civo `status` run and one civo `up`/`down` run
after the edit, because the cleanup step is shared.

## 11. Rollout and rollback/recovery

Revert the workflow.

## 12. Risks and unresolved questions

- Masking covers exact string matches. Do not transform the token.
- The 5-server limit also blocks HETZ-170's autoscaler headroom in CI.
- The sweep runs with the CI project's token; a mis-set `PROJECT_NAME`
  cannot reach another Hetzner project because tokens are per project.

## 13. Definition of done

- [ ] Evidence for aws, civo and hetzner dispatches; forced-failure cleanup
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
