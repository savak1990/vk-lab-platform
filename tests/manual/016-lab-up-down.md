# 016 — lab.yml manual test plan

Covers the account-role/KMS redesign: a single account-global `lab-role` and
`alias/lab-secrets` KMS key (replacing per-project `personal-lab-role`/
per-project KMS key), Route53/ACM moved from Persistent to Bootstrap-lifecycle,
`state-up` folded into `bootstrap-up`, a dedicated Account-layer state bucket,
and the `CONFIRM_DESTROY` guard (replacing the deleted `EPHEMERAL_PROJECTS`
allow-list). Supersedes the previous revision of this plan, written against
`personal-lab-role`. `lab-up.yml`/`lab-down.yml` were consolidated into a
single `lab.yml` before this redesign; that consolidation is unaffected.

This is also the actual migration path for the live `vk-lab-platform`
environment, not just a mechanism test — Phase 0/1 below **is** the
migration sequence, run for real, once. ~3–4h end to end (mostly waiting on
`full-up`/`full-down`), needs `aws`/`kubectl`/`gh`/`terragrunt` CLIs plus
repo admin access (variables, secrets). Run phases in order — each depends
on the previous phase's end state.

## Phase 0 — Migration: tear down the old design

Run this against the **current, unmodified** `main` (before merging the
redesign), against the live `vk-lab-platform` environment.

1. `make full-down` — tears down Disposable → Persistent (old: VPC,
   route53, acm, secrets) → stop before `bootstrap-down` destroys the old
   `kms` unit.
2. Before letting `bootstrap-down` reach the `kms` unit: decrypt and hold
   **locally, uncommitted** the plaintext of all three secrets under the
   still-live old per-project key:
   ```
   scripts/secret-decrypt.sh root-domain > /tmp/root-domain.txt
   scripts/secret-decrypt.sh postgres-app-password > /tmp/postgres-app-password.txt
   scripts/secret-decrypt.sh grafana-admin-password > /tmp/grafana-admin-password.txt
   ```
3. Let `bootstrap-down` finish (old `kms`/`personal-lab-role` now destroyed).
   Confirm `make status` shows bootstrap/persistent/disposable all absent.

## Phase 1 — Migration: bring up the new design

Merge the redesign to `main`, then:

4. `make account-up` — creates the account's own dedicated state bucket
   (`${github_repo_owner}-account-state`), `kms` (`alias/lab-secrets`),
   `github-oidc`, `lab-role`, `eks-access-identity`. Confirm it reports
   `vars.AWS_ROLE_ARN` set; `secrets.ROOT_DOMAIN` will report **skipped**
   (no `root-domain.enc` under the new key yet — expected at this point).
5. Re-encrypt the three secrets held in step 2 under the new shared key:
   ```
   SECRET_NAME=root-domain SECRET_VALUE="$(cat /tmp/root-domain.txt)" ./scripts/secret-encrypt.sh
   SECRET_NAME=postgres-app-password SECRET_VALUE="$(cat /tmp/postgres-app-password.txt)" ./scripts/secret-encrypt.sh
   SECRET_NAME=grafana-admin-password SECRET_VALUE="$(cat /tmp/grafana-admin-password.txt)" ./scripts/secret-encrypt.sh
   ```
   Commit the new ciphertext. Securely delete the `/tmp/*.txt` plaintext files.
6. Re-run `make account-up` — confirm `secrets.ROOT_DOMAIN` now sets
   successfully.
7. `make bootstrap-up` — creates this project's own state bucket, then
   `route53`+`acm` under `terraform/live/bootstrap/`. Confirm `require-unique-subdomain.sh`
   passes (it now checks `bootstrap/route53/terraform.tfstate`, not
   `persistent/...`).
8. `make persistent-up` — now applies only `vpc`+`secrets`. Confirm it
   reports the already-generated passwords as "already exists", not
   regenerated.
9. `make cluster-up && make argo-up`. Confirm Argo CD Synced/Healthy,
   `kubectl get nodes` works, DNS/ACM resolve correctly for the lab
   subdomain (unchanged end-user behavior — only the ownership/lifecycle
   tagging moved).

## Phase 2 — Idempotency of the new account-up

10. Re-run `make account-up` once more. Confirm every unit reports "No
    changes" and both GitHub vars/secrets report the same values
    (idempotent, matching the old `github-vars-up.sh` behavior it absorbed).

## Phase 3 — GitHub-initiated up, workstation-initiated verification

11. Dispatch `lab.yml` with `target=up`. Confirm the run succeeds.
12. From your workstation: `make eks-kubeconfig && kubectl get nodes` —
    confirms `eks-access-identity` gives you cluster access even though
    GitHub Actions created the cluster, and confirms `eks-access-identity`'s
    trust condition on `role/lab-role` (renamed from `personal-lab-role`)
    still resolves correctly.
13. `kubectl -n argocd get applications` — confirm Synced/Healthy.

## Phase 4 — Workstation-initiated down, no leftover

14. Locally: `make down`. Confirm `argo-down`/`cluster-down` succeed
    regardless of which principal created the cluster.
15. `aws eks describe-cluster --name vk-lab-platform-eks` — confirm
    `ResourceNotFoundException`.

## Phase 5 — GitHub-initiated platform-up / platform-down

16. Dispatch `lab.yml` with `target=platform-up`. Confirm the run succeeds
    and produces the same healthy end state as `target=up`.
17. Dispatch `lab.yml` with `target=platform-down`. Confirm it runs
    immediately - no approval step.
18. Confirm Persistent state is gone (`make status`) but Bootstrap/Account
    remain — `persistent-down` no longer touches `route53`/`acm` (they're
    Bootstrap-lifecycle now), only `vpc`/`secrets`.

## Phase 6 — CONFIRM_DESTROY guard: negative and positive

19. `lab.yml`'s dropdown only exposes composite targets
    (`status`/`up`/`down`/`platform-up`/`platform-down`/`full-up`/`full-down`)
    — `bootstrap-down` alone isn't dispatchable, so exercise its
    `CONFIRM_DESTROY` guard via `full-down` instead. Dispatch `lab.yml` with
    `target=full-down` and `confirm_destroy` left blank. Confirm the job
    fails fast, once it reaches `bootstrap-down`, with `Refusing: set
    CONFIRM_DESTROY=vk-lab-platform to confirm destroying it.` before any
    Route53/ACM/state-bucket call — `argo-down`/`cluster-down`/`persistent-down`
    (which run first, unguarded) still complete.
20. Dispatch again with `confirm_destroy=vk-lab-platform`. Confirm it
    proceeds: destroys `route53`+`acm`, then this project's own state
    bucket via raw AWS API (`scripts/state-down.sh`) — confirm no Terraform
    "backend bucket not found" error appears (the self-reference case ADR
    0004 exists to avoid).
21. `make status` — confirm Bootstrap is absent. Locally, `make full-up` to
    restore the environment for later phases.
22. Locally, `account-down`'s same guard: run `CONFIRM_DESTROY=wrong-name
    make account-down` (do **not** use the real project name) — confirm it
    refuses. Do not actually run `account-down` for real in this test pass;
    it destroys every project in the account.

## Phase 7 — Region-portability of the shared role and KMS key

The shared `lab-role`'s permission policy is applied once, in
`ACCOUNT_MAIN_REGION`, but must authorize a project's resources in *any*
`PROJECT_REGION` — its EKS/SSM/Secrets Manager resource ARNs are wildcarded on
region (`arn:aws:eks:*:...`, not `arn:aws:eks:eu-west-1:...`) specifically
for this. The shared `alias/lab-secrets` KMS key, unlike the role, isn't
region-portable — it only exists in `ACCOUNT_MAIN_REGION` — so
`secret-encrypt`/`secret-decrypt`/`generate-secrets` must keep resolving it
there even while `PROJECT_REGION` (this project's own region) changes.

23. Leave `ACCOUNT_MAIN_REGION` unset (defaults `eu-west-1`, matching
    wherever `account-up` actually ran). Pick a second region (e.g.
    `us-east-1`) and a throwaway `PROJECT_NAME` (e.g. `vk-lab-region-test`).
    `PROJECT_REGION=us-east-1 PROJECT_NAME=vk-lab-region-test ROOT_DOMAIN=<domain>
    make generate-secrets` — confirm this succeeds: `generate-secrets`
    calls `secret-encrypt.sh`, which must resolve `alias/lab-secrets` under
    `ACCOUNT_MAIN_REGION` (still `eu-west-1`), not the `PROJECT_REGION=us-east-1`
    this command was invoked with. Then `PROJECT_REGION=us-east-1
    PROJECT_NAME=vk-lab-region-test make bootstrap-up` (a different
    `SUBDOMAIN` too, to avoid the uniqueness guard) — confirm this project's
    own state bucket and Route53/ACM units apply in `us-east-1`
    (`PROJECT_REGION`), while `secret-decrypt.sh`/`secret-encrypt.sh` calls
    anywhere in this flow still succeed against `eu-west-1`
    (`ACCOUNT_MAIN_REGION`).
24. `PROJECT_REGION=us-east-1 PROJECT_NAME=vk-lab-region-test make persistent-up
    cluster-up`. Confirm the cluster actually comes up — this is the real
    test that `lab-role`'s EKS/SSM-AMI-lookup/Secrets-Manager statements
    aren't silently denying every action outside `account-up`'s own region.
25. `PROJECT_REGION=us-east-1 PROJECT_NAME=vk-lab-region-test CONFIRM_DESTROY=vk-lab-region-test
    make full-down` to tear it down again (no `account-down` needed — the
    shared role/KMS survive, only this throwaway project's own resources
    are destroyed).

## Phase 8 — IAM self-protection: the shared role can't escalate itself

26. Via `aws iam simulate-principal-policy` against `lab-role`: confirm
    `iam:PutRolePolicy`/`iam:AttachRolePolicy`/`iam:DeleteRole` all evaluate
    to `explicitDeny` when the resource ARN is `lab-role`'s own ARN or
    `eks-access-identity`'s ARN (the `DenySelfAndAccessIdentityIamRoleMutation`
    statement) — confirms the role can create/manage `*-eks-*` project
    roles but never modify itself or `eks-access-identity`, even though both
    match a broad `iam:*`-shaped Allow elsewhere in the same policy.
27. Also confirm `kms:ScheduleKeyDeletion`/`kms:DisableKey`/`kms:DeleteImportedKeyMaterial`
    against `alias/lab-secrets`'s key ARN evaluate to `implicitDeny` (or
    `explicitDeny` via `DenySharedKmsKeyDestruction`) — the shared key is
    never destroyable by any per-project operation, only `account-down`.
28. Confirm `s3:DeleteBucket` against **this project's own** state bucket
    ARN evaluates to `allowed` (no permanent Deny — ephemeral projects must
    be fully destroyable, unlike the KMS key above).

## Phase 9 — Fault injection: does a mistake still let you shut down?

29. Temporarily break `argo-down.sh` (e.g. exit 1 partway) and run
    `make down` locally — confirm `cluster-down.sh` refuses per ADR 0012
    rather than deleting the cluster out from under Argo CD. Revert the
    break.
30. Temporarily point `AWS_ROLE_ARN` at a nonexistent ARN and dispatch
    `lab.yml` with `target=up` — confirm `configure-aws-credentials` fails
    cleanly at the auth step, before any AWS resource is touched.
31. Delete `eks-access-identity` (`terraform destroy` on that unit only)
    and run `make cluster-up` — confirm `require-persistent.sh`'s existence
    check fails fast with "Run 'make account-up' first". Re-run
    `make account-up` to restore it.

## Phase 10 — Operator-identity edge case (unchanged by this redesign)

32. Switch your local AWS auth from a plain IAM user to an SSO session (or
    vice versa) and re-run `make account-up`. Confirm the plan shows
    `eks-access-identity`'s `OperatorWorkstation` trust statement's
    principal updated to the new identity's *role* ARN.
33. Before re-running `make account-up` in step 32, confirm `kubectl` fails
    with `Unauthorized` under the new identity (stale trust principal) —
    then confirm it works again immediately after the re-apply.

## Out of scope for this test plan

- Registering a second, permanently-dispatchable `PROJECT_NAME` dropdown
  entry for `vk-lab-ci` — Phase 7 above proves the shared role/KMS already
  support any `PROJECT_NAME`/`PROJECT_REGION` mechanically; wiring a permanent
  second dropdown option is a separate, smaller follow-up.
- Numeric per-PR ephemeral clusters — a stated future idea, not yet
  designed; a full EKS cluster per PR was flagged as likely the wrong tool
  (namespace/vcluster-based previews on one shared cluster would be
  cheaper) if it's ever pursued.
- Load/soak testing of the workflows themselves — these are
  manually-triggered, low-frequency operations.
