---
id: "CIVO-082"
title: "Roles Anywhere Terraform: trust anchor, profile, per-consumer roles, lab-role additions"
status: "IN_PROGRESS"
priority: "P0"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "IAM trust-policy conditions and least privilege define the security boundary of the whole chain"
effort_estimate: "One session (4–6 h) including a real apply"
estimate_confidence: "medium"
depends_on: ["CIVO-080"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-09"
completed: null
---

# CIVO-082 — Roles Anywhere Terraform

## 1. Outcome and rationale

`PROVIDER=civo make bootstrap-up` creates a Roles Anywhere trust anchor
from the committed CA certificate. It creates one profile. It creates one
IAM role per consumer. The trust policies are pinned to the certificate CN
and the trust anchor ARN. The outputs go to SSM. AWS-only projects are
unaffected, because the unit is guarded on the CA file.

## 2. Scope and non-goals

In scope: `terraform/live/bootstrap/rolesanywhere`, `modules/rolesanywhere`,
the `lab-role` policy additions, and the SSM outputs. Not in scope: the
certificates (CIVO-085), the sidecar (CIVO-090), and the application roles
(future).

## 3. Current state / evidence

- The trust model and the condition keys are in research.md. The resources are regional (eu-west-1, same as everything else).
- `modules/lab-role/main.tf` has no `rolesanywhere:*`. `PlatformIamRoles` is scoped to `role/*-eks-*` (~`:123-140`). The SSM scope is `parameter/*/bootstrap/*`, `*/persistent/*`, and `*/cluster/*` (`:247-256`).
- `modules/external-dns-pod-identity` and `modules/external-secrets-pod-identity` hold the exact least-privilege policies to reuse. These are `route53:ChangeResourceRecordSets` on the zone, and `ssm:GetParameter` on two ARNs + `kms:Decrypt` with `EncryptionContext:PARAMETER_ARN`.

## 4. Design and contracts

- The module `rolesanywhere` has these inputs: `project`, `ca_cert_pem` (file content), a `consumers` map `{ eso = { policy_json }, external_dns = { policy_json } }`, `hosted_zone_id`, and `session_duration = 3600`.
- The module creates `aws_rolesanywhere_trust_anchor` (source `CERTIFICATE_BUNDLE`, the PEM). It creates `aws_rolesanywhere_profile` (`role_arns` = all consumer roles, `duration_seconds = 3600`, no session policy in M1). It creates one `aws_iam_role` per consumer, named `${project}-ra-${consumer}`. The trust policy of each role has the principal `rolesanywhere.amazonaws.com` and the actions `sts:AssumeRole`, `sts:TagSession`, and `sts:SetSourceIdentity`. The trust policy has three conditions: `ArnEquals aws:SourceArn = trust anchor`, `StringEquals aws:PrincipalTag/x509Subject/CN = ${project}-civo-${consumer}`, and `StringEquals aws:PrincipalTag/x509Issuer/CN = ${project}-civo-workload-ca`. The inline policies are copied from the Pod Identity modules (parameterized by zone id and project).
- The SSM outputs (String) are `/${project}/bootstrap/rolesanywhere/trust_anchor_arn`, `profile_arn`, `role_arn/eso`, and `role_arn/external_dns`.
- The unit `bootstrap/rolesanywhere/terragrunt.hcl` declares `dependency route53` for the zone id. It sets `inputs.ca_cert_pem = fileexists(path) ? file(path) : ""`. The module sets `count = var.ca_cert_pem == "" ? 0 : 1` on every resource. For that reason, AWS-only projects render nothing.
- `x509Issuer/CN` is a module variable. It is the root CN in M1. It becomes the intermediate CN once CIVO-200 lands.
- `lab-role` gets `iam:PassRole` on `role/*-ra-*`. `rolesanywhere:CreateProfile` with `role_arns` needs this; verify it at plan time. It also gets `rolesanywhere:CreateTrustAnchor|UpdateTrustAnchor|DeleteTrustAnchor|GetTrustAnchor|CreateProfile|UpdateProfile|DeleteProfile|GetProfile|TagResource|UntagResource|ListTagsForResource|DisableTrustAnchor|EnableTrustAnchor` on `arn:aws:rolesanywhere:eu-west-1:<acct>:*`. It gets IAM role CRUD on `role/*-ra-*`. It gets the SSM paths `*/persistent-civo/*`, `*/cluster-civo/*`, and `*/bootstrap/rolesanywhere/*`.
- Tags: the standard four via `default_tags` (Lifecycle=bootstrap).

## 5. Files/components affected

The new module and unit; `terraform/modules/lab-role/main.tf`; `terraform/live/account/lab-role`, re-applied via `make account-up` (outside the composites; a documented step).

## 6. Implementation steps

1. Write the module and the unit. Run `validate`/`plan` with the CA file absent (zero resources). Run them again with the CA file present.
2. Add the `lab-role` additions. Run `make account-up` (it applies only the changed units). Record the plan.
3. Run `PROVIDER=civo make bootstrap-up`. Verify that the trust anchor is `ENABLED`. Verify the profile, the roles, and the SSM parameters.
4. Run a negative check from a workstation. Run `aws_signing_helper credential-process` with a self-signed cert that is not from the CA. Expect `AccessDenied`. The positive check waits for CIVO-085/090 (a cluster-issued cert). An operator-issued test cert from the CA (temporary, deleted after) may be used to prove the trust policy. A CN match succeeds. A CN mismatch fails.

## 7. Dependencies and blockers

The CIVO-080 files. Parallel: the CIVO-085 drafting.

## 8. Acceptance criteria

- The AWS project `bootstrap-up` plan shows zero rolesanywhere resources.
- The Civo project has the anchor, the profile, two roles, and four SSM params.
- Trust policy negative tests: a wrong CN is denied. A wrong issuer is denied. A foreign CA is denied.
- The roles have no permissions beyond the copied Pod Identity policies.
- The `lab-role` diff is limited to the listed statements.

## 9. Validation

Offline: fmt/validate/plan, and `checkov` or `tfsec` if available. Real cloud: the bootstrap apply (free) and the STS calls (free).

## 10. AWS regression protection

The unit is guarded. The AWS plan is unchanged. The `lab-role` additions are additive statements.

## 11. Rollout and rollback/recovery

`bootstrap-down` destroys the resources. Disabling the trust anchor is the emergency stop. There is no data.

## 12. Risks and unresolved questions

- The `aws_rolesanywhere_*` resources in AWS provider 6.60.0: confirm the attribute names.
- Does a session policy on the profile add value in M1? No.

## 13. Definition of done

- [ ] Evidence incl. negative tests; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-09 — CIVO-080 (dependency) done; started implementation on branch `civo-082-rolesanywhere-terraform`, promoted to IN_PROGRESS.
