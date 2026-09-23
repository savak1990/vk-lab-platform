---
id: "HETZ-140"
title: "lab.yml third provider value, hcloud CLI, token mask, label sweep in cleanup-on-failure"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Workflow edits on top of CIVO-140 with one new cleanup path and a Hetzner account-limit constraint"
effort_estimate: "One session (3–4 h) plus one CI run per provider"
estimate_confidence: "medium"
depends_on: ["HETZ-015", "HETZ-045", "CIVO-140", "HETZ-047"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-23"
completed: "2026-09-23"
---

# HETZ-140 — CI workflow for Hetzner

## 1. Outcome and rationale

The manual `lab` workflow runs any lifecycle target with
`provider=hetzner`. It decrypts `secrets/hetzner-token.enc` and the SSH key
with the OIDC-assumed role it already uses, never prints either, queues
runs per project-provider, and cleans up on failure by sweeping every
labelled Hetzner resource, not only by destroying servers.

Read `specs/civo/140-D-ci-workflow-civo/spec.md` first.

## 2. Scope and non-goals

In scope:
- `.github/workflows/lab.yml` input enums and validation.
- The `hcloud` CLI install (pinned, checksummed).
- The token mask pre-step per job.
- The cleanup step's label sweep.
- `provider` in `run-name`, concurrency.

Added to scope on 2026-09-23, by agreement: the `lifecycle-hetzner` caller
job in `lifecycle-test.yml`, so that the `ci:lifecycle-hetzner` label runs a
real lifecycle instead of being refused by `pr-gate`. The exclusion below
never covered that job - it names the *render* of `target=hetzner`, which
HETZ-050 owns.

Not in scope: PR validation (spec 019), Kind CI (spec 024),
`lifecycle-test.yml` render of `target=hetzner` (HETZ-050 owns it).

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
- Cleanup on failure of `up`, `platform-up`, `full-up`: run `make down`.
  If that fails, run
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
- `ci:lifecycle-hetzner` runs a lifecycle rather than being refused, and
  `pr-gate` judges its result like any other cloud's.

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
- There is no separate CI token. `hcloud_token` is `SECRET_SCOPE=global`
  and there is one `secrets/hetzner-token.enc`, so the CI project and the
  personal lab are two names inside one Hetzner project. Hetzner tokens are
  per project, but that protects nothing here. The real hazard runs the other
  way: `hcloud_list_names` selects `project=$PROJECT_NAME`, so a mis-set name
  matches nothing and reports clean while resources bill - and a name typed
  toward `vk-hetzner-lab` would have a CI sweep delete the personal lab.

## 13. Definition of done

- [x] Evidence for aws, civo and hetzner dispatches; forced-failure cleanup
- [x] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — depends on HETZ-047 (argo-down LB ordering).
- 2026-09-20 — the token ciphertext is `secrets/hetzner-token.enc`.

- 2026-09-22 — found while HETZ-047 traced the teardown, and it belongs
  here. `scripts/verify-no-leaks.sh:17-23` accepts only `aws` and `civo`,
  and exits 2 on anything else. `.github/workflows/lifecycle-provider.yml`
  calls it with the provider input, so a Hetzner lifecycle run has **no
  post-teardown leak check at all**. The local sweep in `cluster-down` is
  not a substitute: it deletes what it finds, and CI needs an independent
  reader that only reports.

  HETZ-047's `wait_for_lb_gone()` shows the shape the Hetzner arm needs.
  A label selector cannot be used, because the cloud controller manager
  labels nothing it creates; match load balancers on the `$PROJECT_NAME-`
  name prefix and everything else on `project=$PROJECT_NAME`.

- 2026-09-23 - closed together with HETZ-115 and HETZ-130, which share its
  evidence cycle.

  Scope grew by agreement, and the growth is the point: `ci:lifecycle-hetzner`
  has existed as a repository label since the HETZ-045 era, and `pr-gate` was
  written to refuse it by name so that a label with nothing behind it would
  fail loudly rather than do nothing. This spec builds the job and deletes the
  refusal. The CI project is `vk-hetzner-ci` / `hzci`, two nodes.

  Two nodes, not three. `hcloud_token` is `SECRET_SCOPE=global` and there is
  one `secrets/hetzner-token.enc`, so the CI project and the personal lab are
  two names inside one Hetzner project with one 5-server limit. Two leaves
  room for the lab's three, and a control plane plus one worker still
  exercises the private-network k3s join. §12's claim that per-project tokens
  protect against a mis-set `PROJECT_NAME` is corrected above; it was
  backwards.

  Four things were civo-shaped rather than self-managed-shaped, and each would
  have failed the first hetzner run alone: `yq` installed only for civo
  although `export_tls_secret` needs it on every non-AWS target; the token
  mask step named `civo_token` directly; `E2E_INSECURE_TLS` was gated on
  `provider == 'civo'`; and the staging TLS parameter left by `full-down` was
  read from a path with `civo` written into it. All four now key on "not aws".

  `node_count` and `node_type` are exported only when non-blank. An empty
  environment variable still counts as defined for make's `?=`, so passing
  either through unconditionally would have blanked the aws and civo defaults
  rather than kept them - the same reasoning `lab.yml`'s Resolve step already
  carried.

  `secrets/vk-hetzner-ci/hetzner-ssh-key.{enc,pub}` is committed, and it is
  the one artifact the Civo CI project never needed. `lifecycle-provider.yml`
  puts up, test and down on three runners, and every hetzner job fetches its
  kubeconfig over SSH, so a key regenerated per job cannot log into servers
  the previous job created. It is safe across runs because `alias/lab-secrets`
  belongs to `terraform/live/account/kms` and `account-up` owns it - no
  composite target destroys it.

  `verify-no-leaks.sh` accepted only `aws|civo` and exited 2 otherwise, so a
  hetzner run had no independent leak check at all. Its first run:

      VERIFY-NO-LEAKS: checking project vk-hetzner-lab on hetzner.
      VERIFY-NO-LEAKS: keeping /vk-hetzner-lab/persistent/hetzner/tls/platform-public - the deliberately retained serving certificate.
      VERIFY-NO-LEAKS: no bootstrap or persistent resources remain for vk-hetzner-lab.

  The Roles Anywhere consumer-role loop moved out of the civo branch. Those
  roles exist wherever a workload CA does (`rolesanywhere/main.tf:9`,
  `create = var.ca_cert_pem != ""`), which is every target but aws, so civo's
  copy was never civo-specific. It is *not* an aws bug: aws has no workload CA,
  so `consumers` is empty there and the roles are never created.

  **Stock, and why HETZ-175 is now urgent.** The first bring-up failed at
  placement: `error during placement (resource_unavailable)` for the control
  plane and both workers on `cx33`, the Makefile default. The API's datacenter
  listing showed `fsn1-dc14` with an empty availability list and no `cx` type
  (ids 114-117) available in *any* location - not an ARM problem and not an
  `fsn1` problem, but the platform's default node type unbuyable worldwide.
  `cpx32` is the same 4 vCPU / 8 GiB and was sold in `fsn1` the same minute,
  so the flag was wrong in both directions at once, exactly as
  `catalog.sh:63-65` warns. The CI leg names `cpx32` explicitly as a
  workaround; the real fix is HETZ-175, whose P2/M2 priority now understates
  it - every Hetzner run is one stock check away from being unable to start.

  **Outstanding.** §8's forced-failure cleanup case and the two-simultaneous-
  dispatch queueing case are not yet exercised; the first `ci:lifecycle-hetzner`
  run on this pull request is what answers the rest.
