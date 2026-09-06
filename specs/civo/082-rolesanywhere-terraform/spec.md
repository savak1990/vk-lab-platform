---
id: "CIVO-082"
title: "Roles Anywhere Terraform: trust anchor, profile, per-consumer roles, lab-role additions"
status: "DRAFT"
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
updated: "2026-09-06"
completed: null
---

# CIVO-082 — Roles Anywhere Terraform

## 1. Outcome and rationale

`PROVIDER=civo make bootstrap-up` creates a Roles Anywhere trust anchor
from the committed CA certificate, one profile, and one IAM role per
consumer with trust policies pinned to the certificate CN and the trust
anchor ARN; outputs go to SSM. AWS-only projects are unaffected because
the unit is guarded on the CA file.

## 2. Scope and non-goals

In scope: `terraform/live/bootstrap/rolesanywhere`, `modules/rolesanywhere`,
`lab-role` policy additions, SSM outputs. Not in scope: certificates
(CIVO-085), sidecar (CIVO-090), application roles (future).

## 3. Current state / evidence

- Trust model and condition keys in research.md; resources regional (eu-west-1, same as everything else).
- `modules/lab-role/main.tf`: no `rolesanywhere:*`; `PlatformIamRoles` scoped to `role/*-eks-*` (~`:123-140`); SSM scope `parameter/*/bootstrap/*`, `*/persistent/*`, `*/cluster/*` (`:247-256`).
- `modules/external-dns-pod-identity` and `modules/external-secrets-pod-identity` hold the exact least-privilege policies to reuse (`route53:ChangeResourceRecordSets` on the zone; `ssm:GetParameter` on two ARNs + `kms:Decrypt` with `EncryptionContext:PARAMETER_ARN`).

## 4. Design and contracts

- Module `rolesanywhere` inputs: `project`, `ca_cert_pem` (file content), `consumers` map `{ eso = { policy_json }, external_dns = { policy_json } }`, `hosted_zone_id`, `session_duration = 3600`.
- Resources: `aws_rolesanywhere_trust_anchor` (source `CERTIFICATE_BUNDLE`, the PEM), `aws_rolesanywhere_profile` (`role_arns` = all consumer roles, `duration_seconds = 3600`, no session policy in M1), per consumer `aws_iam_role` named `${project}-ra-${consumer}` with trust policy: principal `rolesanywhere.amazonaws.com`, actions `sts:AssumeRole`, `sts:TagSession`, `sts:SetSourceIdentity`, conditions `ArnEquals aws:SourceArn = trust anchor`, `StringEquals aws:PrincipalTag/x509Subject/CN = ${project}-civo-${consumer}`, `StringEquals aws:PrincipalTag/x509Issuer/CN = ${project}-civo-workload-ca`; inline policies copied from the Pod Identity modules (parameterized by zone id and project).
- SSM outputs (String): `/${project}/bootstrap/rolesanywhere/trust_anchor_arn`, `profile_arn`, `role_arn/eso`, `role_arn/external_dns`.
- Unit `bootstrap/rolesanywhere/terragrunt.hcl`: `dependency route53` for the zone id; `inputs.ca_cert_pem = fileexists(path) ? file(path) : ""`; module `count = var.ca_cert_pem == "" ? 0 : 1` on every resource, so AWS-only projects render nothing.
- `lab-role`: `rolesanywhere:CreateTrustAnchor|UpdateTrustAnchor|DeleteTrustAnchor|GetTrustAnchor|CreateProfile|UpdateProfile|DeleteProfile|GetProfile|TagResource|UntagResource|ListTagsForResource|DisableTrustAnchor|EnableTrustAnchor` on `arn:aws:rolesanywhere:eu-west-1:<acct>:*`; IAM role CRUD on `role/*-ra-*`; SSM paths `*/persistent-civo/*`, `*/cluster-civo/*`, `*/bootstrap/rolesanywhere/*`.
- Tags: standard four via `default_tags` (Lifecycle=bootstrap).

## 5. Files/components affected

New module and unit; `terraform/modules/lab-role/main.tf`; `terraform/live/account/lab-role` re-applied via `make account-up` (outside composites; documented step).

## 6. Implementation steps

1. Module + unit; `validate`/`plan` with the CA file absent (zero resources) and present.
2. `lab-role` additions; `make account-up` (applies only changed units; record plan).
3. `PROVIDER=civo make bootstrap-up`; verify trust anchor `ENABLED`, profile, roles, SSM.
4. Negative check from a workstation: `aws_signing_helper credential-process` with a self-signed cert not from the CA → `AccessDenied`. Positive check waits for CIVO-085/090 (cluster-issued cert), but an operator-issued test cert from the CA (temporary, deleted after) may be used to prove the trust policy: CN match succeeds, CN mismatch fails.

## 7. Dependencies and blockers

CIVO-080 files. Parallel: CIVO-085 drafting.

## 8. Acceptance criteria

- AWS project `bootstrap-up` plan shows zero rolesanywhere resources.
- Civo project: anchor, profile, two roles, four SSM params.
- Trust policy negative tests: wrong CN denied; wrong issuer denied; foreign CA denied.
- Roles have no permissions beyond the copied Pod Identity policies.
- `lab-role` diff limited to the listed statements.

## 9. Validation

Offline: fmt/validate/plan, `checkov` or `tfsec` if available. Real cloud: bootstrap apply (free), STS calls (free).

## 10. AWS regression protection

Guarded unit; AWS plan unchanged; `lab-role` additions are additive statements.

## 11. Rollout and rollback/recovery

`bootstrap-down` destroys; disabling the trust anchor is the emergency stop. No data.

## 12. Risks and unresolved questions

- `aws_rolesanywhere_*` resources in AWS provider 6.60.0: confirm attribute names.
- Whether a session policy on the profile adds value in M1: no.

## 13. Definition of done

- [ ] Evidence incl. negative tests; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
