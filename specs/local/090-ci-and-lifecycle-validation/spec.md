---
id: "LOCAL-090"
title: "lifecycle-test.yml provider=local on a kind runner; full lifecycle evidence"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Workflow restructuring with a known constraint (one runner per cluster); the validation checklist is fixed"
effort_estimate: "One session (4–6 h) including two or three workflow runs"
estimate_confidence: "medium"
depends_on: ["LOCAL-080"]
blocked_by: []
supersedes: ["spec 024"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-090 — `lifecycle-test.yml` `provider=local` on a kind runner; full lifecycle evidence

## 1. Outcome and rationale

`lifecycle-test.yml` dispatched with `provider: local` creates a kind
cluster on a hosted runner (the workflow's job, not the platform's), runs
`PROVIDER=local make up`, `make test`, a `down`/`up` data-survival check,
and `make down`, all in one job, then deletes the cluster and proves
nothing is left. The same workflow, not a second one, so the AWS path
keeps its shape and the local path gets the same validate gates. The
lifecycle evidence for constitution §18 (as amended) is recorded here.

## 2. Scope and non-goals

In scope:
- `workflow_dispatch` input `provider` (choice `aws`, `local`, default
  `aws`); `project_name` default provider-dependent (`vk-lab-ci` /
  `vk-local-ci`).
- New job `local-lifecycle` (`if: inputs.provider == 'local'`), needs the
  five `validate-*` jobs; the existing `up`/`test`/`down` jobs gain
  `if: inputs.provider == 'aws'`.
- `local-lifecycle` steps: OIDC assume (KMS only); `helm/kind-action`
  creating cluster `vk-local-ci` (the context is then `kind-vk-local-ci`,
  which LOCAL-010's guard accepts); prune runner disk;
  `PROVIDER=local make full-up`; `make test`; write a marker row;
  `make down`; `make up`; assert the row; `make test` again;
  `make full-down` with `if: always()`; `kind delete cluster` with
  `if: always()`; leak check (`kind get clusters` empty, `docker ps -a`
  shows no `vk-local-ci-control-plane`).
- CI secrets per `decisions.md` §3 (b): `FIXED_TEST_PASSWORDS=true`;
  `persistent-up` on local generates and encrypts the three secret files
  when `secrets/<project>/` is missing (the one thing `persistent-up`
  does on local). Ciphertext for `vk-local-ci` is committed once.
- `make gitops-check` added to `validate-gitops`.
- `permissions` for `local-lifecycle`: `id-token: write`,
  `contents: read`; concurrency group per provider.

Not in scope:
- A `pull_request` trigger (spec 019).
- `lab.yml` (`PROVIDER=civo` there is CIVO-140).
- Image caching between runs (measure first).

## 3. Current state / evidence

- `.github/workflows/lifecycle-test.yml`: five `validate-*` jobs
  (`:51-236`), `up` (`:255`), `test` (`:299`), `down` (`:323`), each on
  its own runner; `FIXED_TEST_PASSWORDS: "true"` (`:46`);
  `CONFIRM_DESTROY` passed at `:364`.
- No workflow sets `PROVIDER`; none runs `make gitops-check`.
- `terraform/modules/lab-role/main.tf:378-379` grants `kms:*` on the
  `alias/lab-secrets` key — decrypt and encrypt both covered.
- Public-repo `ubuntu-latest`: 4 vCPU, 16 GB, 14 GB disk.
- The platform never creates a cluster (LOCAL-010); the workflow does.

## 4. Design and contracts

Single-job shape (abridged):

```yaml
local-lifecycle:
  if: inputs.provider == 'local'
  needs: [validate-terraform, validate-gitops, validate-yaml, validate-actions, validate-secrets]
  runs-on: ubuntu-latest
  timeout-minutes: 60
  env: { PROVIDER: local, PROJECT_NAME: ${{ inputs.project_name }}, FIXED_TEST_PASSWORDS: "true" }
  steps:
    - checkout
    - configure-aws-credentials (OIDC)          # kms only
    - helm/kind-action  { cluster_name: vk-local-ci }
    - prune disk
    - make full-up                              # persistent-up generates secrets if missing
    - make test
    - write marker row
    - make down && make up
    - assert marker row
    - make test
    - make full-down                            # if: always()
    - kind delete cluster --name vk-local-ci    # if: always()
    - leak check                                # if: always()
```

Evidence uploaded as a job artifact: `kubectl get application -n argocd
-o wide`, `kubectl top nodes`, `kubectl get pv`, timings per step.

## 5. Files/components affected

`.github/workflows/lifecycle-test.yml`; `Makefile`/`scripts` for the
`persistent-up` generate-secrets branch on local;
`secrets/vk-local-ci/` (three generated ciphertext files).

## 6. Implementation steps

1. Workflow edits; `actionlint` locally.
2. `persistent-up` local generate-secrets branch; run it once locally with
   `PROJECT_NAME=vk-local-ci` to commit `secrets/vk-local-ci/`.
3. Dispatch with `provider: local`; iterate on disk/timeouts.
4. Dispatch with `provider: aws` (or `make -n` + `actionlint` if a cloud
   run is not wanted) to prove the aws jobs still gate and run as before.
5. Record timings and the artifact in §14.

## 7. Dependencies and blockers

LOCAL-080.

## 8. Acceptance criteria

- `provider: local` run is green end to end, including the marker-row
  survival check and both `make test` runs.
- Leak check finds no cluster or container; cluster deletion runs even
  when an earlier step fails.
- `provider: aws` job graph unchanged (`up` → `test` → `down`).
- `make gitops-check` runs in `validate-gitops`.
- Total local job time recorded; target ≤ 25 min.

## 9. Validation

`actionlint`; two workflow dispatches (local green; aws graph intact).

## 10. AWS regression protection

The aws jobs gain only an `if:`; a `make -n` and `actionlint` diff show
nothing else changed.

## 11. Rollout and rollback/recovery

Workflow-only; revert the file. Runner state is disposable.

## 12. Risks and unresolved questions

- 14 GB runner disk: prune first; add an image cache only if pruning is
  insufficient.
- Runtime: two Argo bring-ups plus two test runs may approach 25 min; if
  so drop the second `make test` (the marker row already proves
  persistence) and record the decision.
- The CI-secrets decision (`decisions.md` §3) must be confirmed before
  step 2; the default is (b).

## 13. Definition of done

- [ ] Workflow and `persistent-up` branch landed; `secrets/vk-local-ci/` committed
- [ ] Green local dispatch with artifact; aws graph verified
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `DRAFT` (blocked on LOCAL-080).
- 2026-09-11 — replanned: the workflow creates and deletes the kind cluster; the platform only installs into it.
