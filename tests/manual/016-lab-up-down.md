# 016 — lab-up.yml / lab-down.yml manual test plan

Covers personal-lab-role, eks-access-identity, and the bounded-environment
depth selector (spec 016, ADR 0022) — supersedes spec.md's original
"Testing / acceptance criteria", which only covered the pre-amendment scope.
~2–3h end to end (mostly waiting on `full-up`/`full-down`), needs
`aws`/`kubectl`/`gh`/`terragrunt` CLIs plus repo admin access (Environments,
variables, secrets). Run phases in order — each depends on the previous
phase's end state.

## Phase 0 — One-time setup (workstation only, never CI)

1. `make account-up` — creates the GitHub OIDC provider and `eks-access-identity`.
   Re-run once more, confirm both units report "No changes." (idempotency).
   Run this again any time either module changes - it always applies, never
   skips based on a raw AWS existence check (that check was removed: it
   silently no-opped real trust-policy updates to an already-existing role).
2. `make bootstrap-up` — creates `kms` and `personal-lab-role`. Re-run this
   step after every future change to `personal-lab-role`'s policy, before
   the next `lab-up.yml`/`lab-down.yml` dispatch - a pushed policy change
   doesn't apply itself; a stale live policy produces AccessDenied errors
   that look like new missing actions but aren't.
3. `make github-vars-up` - sets `vars.AWS_ROLE_ARN` (from `personal-lab-role`'s
   own ARN) and `secrets.ROOT_DOMAIN` (decrypted from the already-committed
   `secrets/$PROJECT_NAME/root-domain.enc`) via `gh`. No `AWS_REGION` variable
   needed - both workflows already take `region` as a `workflow_dispatch` input
   and pass `${{ inputs.region }}` straight to `configure-aws-credentials`.
   Re-run once more, confirm it reports the same values (idempotent).
   Then create the `ephemeral-teardown` Environment with a required reviewer
   (yourself) - not scriptable via `gh`, do this once in repo Settings → Environments.

## Phase 1 — GitHub-initiated up, workstation-initiated verification

4. Dispatch `lab-up.yml` with `depth=up` (Persistent must already exist locally,
   or run `depth=full-up` instead the first time). Confirm the run succeeds.
5. From your workstation: `make eks-kubeconfig && kubectl get nodes` — confirms
   `eks-access-identity` gives you cluster access even though GitHub Actions
   created the cluster (the workstation/GitHub equivalence ADR 0022 exists for).
6. `kubectl -n argocd get applications` — confirm Synced/Healthy, matching a local
   `make up`'s end state.

## Phase 2 — Workstation-initiated down, no leftover from step 1

7. Locally: `make down`. Confirm `argo-down`/`cluster-down` succeed regardless of
   which principal created the cluster.
8. `aws eks describe-cluster --name vk-lab-platform-eks` — confirm `ResourceNotFoundException`.

## Phase 3 — GitHub-initiated down-through-persistent

9. `make full-up` locally (or `depth=full-up` via `lab-up.yml`) to get Persistent back.
10. Dispatch `lab-down.yml` with `depth=down-through-persistent`. This job carries
    no environment gate — confirm it runs immediately without an approval step.
11. Confirm `persistent-down.sh` completed without hanging: it detects the
    non-interactive shell (`[ -t 0 ]` false under GitHub Actions) and passes
    `--non-interactive -auto-approve` to terragrunt automatically — both flags;
    `-auto-approve` is the one that actually skips Terraform's own "type yes"
    prompt (`--non-interactive` alone doesn't, hit for real in `account-up.sh`'s
    single-unit `apply` calls — see this same fix there).
12. Confirm Persistent state is gone (`make status`) but Bootstrap/State remain.

## Phase 4 — full-down refuses for vk-lab-platform, on two independent paths

13. Dispatch `lab-down.yml` with `depth=full-down`. Confirm the `ephemeral-teardown`
    Environment prompts for approval before the job starts — approve it.
14. Confirm the job still fails: `bootstrap-down.sh`/`state-down.sh`'s
    `is_ephemeral_project` check refuses (`vk-lab-platform` isn't on
    `EPHEMERAL_PROJECTS`), independent of the approval already given.
15. Separately, via `aws iam simulate-principal-policy` against `personal-lab-role`:
    confirm `kms:ScheduleKeyDeletion`, `kms:DeleteAlias`, and `s3:DeleteBucket` all
    evaluate to `implicitDeny` — the IAM-level guard holds even if the script-level
    check were ever bypassed.

## Phase 5 — Fault injection: does a mistake still let you shut down?

16. Temporarily break `argo-down.sh` (e.g. exit 1 partway) and run `make down`
    locally — confirm `cluster-down.sh` refuses per ADR 0012 rather than deleting
    the cluster out from under Argo CD. Revert the break.
17. Temporarily point `AWS_ROLE_ARN` at a nonexistent ARN and dispatch `lab-up.yml`
    — confirm `configure-aws-credentials` fails cleanly at the auth step, before
    any AWS resource is touched.
18. Delete `eks-access-identity` (`terraform destroy` on that unit only) and run
    `make cluster-up` — confirm `require-persistent.sh`'s new existence check
    fails fast with "Run 'make account-up' first", not a raw
    `couldn't find resource` error from deep inside `terragrunt run --all apply`.
    Re-run `make account-up` to restore it.
19. Confirm `terraform/modules/personal-lab-role`'s own Terraform can still plan
    itself after step 18's `eks-access-identity` deletion: the `SelfAndAccessIdentityIamRolesReadOnly`
    statement covers `iam:GetRole` on the role's own ARN regardless of whether
    `eks-access-identity` currently exists (a `data` lookup failure there fails the
    whole plan, not the IAM statement — this just confirms the policy statement
    that would matter once it exists is present and not the failure point).

## Phase 6 — Operator-identity edge case (added after the SSO-ARN regex bug)

20. Switch your local AWS auth from a plain IAM user to an SSO session (or
    vice versa) and re-run `make account-up`. Confirm the plan shows
    `eks-access-identity`'s `OperatorWorkstation` trust statement's principal
    updated to the new identity's *role* ARN (via `data "aws_iam_session_context"`),
    including its IAM path if one exists (e.g. `/aws-reserved/sso.amazonaws.com/...`)
    — this is the case the original hand-rolled regex silently dropped.
21. Before re-running `make account-up` in step 20, confirm `kubectl` fails with
    `Unauthorized` under the new identity (stale trust principal) — then confirm
    it works again immediately after the re-apply.

## Out of scope for this test plan

- Actually registering a second combination (`vk-lab-ci`/`ci`) — mechanism only,
  per ADR 0022's own "out of scope" section.
- Load/soak testing of the workflows themselves — these are manually-triggered,
  low-frequency operations.
