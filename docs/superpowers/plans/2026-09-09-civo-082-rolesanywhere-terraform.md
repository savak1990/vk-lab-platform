# CIVO-082 — Roles Anywhere Terraform (trust anchor, profile, per-consumer roles, lab-role additions)

## Context

CIVO-080 (done, merged) produced the offline root CA: a committed public
cert (`secrets/vk-civo-lab/civo-ca-cert.pem`) and a KMS-encrypted private
key, self-signed with `CA:TRUE, pathlen:1`. That CA exists but nothing in
AWS trusts it yet. CIVO-082 is the next link in the Roles Anywhere chain
(ADR 0029): it teaches AWS IAM to trust certificates issued by that CA, by
creating a Roles Anywhere trust anchor from the cert, a profile, and one
narrowly-scoped IAM role per future workload consumer (`eso`,
`external_dns`), with trust policies pinned to the CA's issuer CN and to
individual consumer subject CNs. It also extends `lab-role` (the CI/local
automation identity) with the narrow set of permissions needed to manage
these new resources via Terraform.

This is AWS-side infrastructure only — no certificates are issued yet
(CIVO-085), no cluster-side sidecar exists yet (CIVO-090). The unit is
built to be a no-op for AWS-only projects (guarded on the CA file's
presence), so this must not change any existing AWS project's plan.

## Design decisions (resolved from spec + verified against the codebase)

1. **New module** `terraform/modules/rolesanywhere/` (main.tf,
   variables.tf, outputs.tf, versions.tf — following the shape of
   `external-dns-pod-identity`/`external-secrets-pod-identity`).

   Inputs: `project` (string), `ca_cert_pem` (string, PEM content — `""`
   means "not a Civo project, render nothing"), `hosted_zone_id` (string),
   `consumers` (`map(object({ policy_json = string }))`, keys `eso` and
   `external_dns` for M1), `x509_issuer_cn` (string, defaults to
   `"${project}-civo-workload-ca"` — the root CA's CN today; becomes the
   intermediate CN once CIVO-200 lands, per the spec — module takes it as
   a variable rather than hardcoding the derivation), `session_duration`
   (number, default `3600`).

   Guard: `locals { create = var.ca_cert_pem != "" }`. Trust anchor and
   profile use `count = local.create ? 1 : 0`; the per-consumer IAM roles
   use `for_each = local.create ? var.consumers : {}` (a map, not count,
   since Terraform can't `count` conditionally alongside a `for_each`-shaped
   set of named consumers — module must be internally consistent about
   this, not use `count` on a resource that also needs per-consumer
   identity).

   Resources:
   - `aws_rolesanywhere_trust_anchor.this[0]`: `name = "${var.project}-civo-workload-ca"`,
     `source { source_type = "CERTIFICATE_BUNDLE", source_data { x509_certificate_data = var.ca_cert_pem } }`,
     `enabled = true`. (Verified against the actual `hashicorp/aws` 6.60.0
     provider docs: `source` is a required block containing `source_type`
     and a `source_data` block; `x509_certificate_data` is the PEM field
     for the `CERTIFICATE_BUNDLE` source type — the spec's own open risk,
     "confirm the attribute names," is resolved by this check.)
   - `aws_rolesanywhere_profile.this[0]`: `name = "${var.project}-civo"`,
     `role_arns = local.create ? [for k, r in aws_iam_role.consumer : r.arn] : []`,
     `duration_seconds = var.session_duration`, `enabled = true`.
   - `aws_iam_role.consumer["eso"]`, `aws_iam_role.consumer["external_dns"]`
     (via `for_each`): `name = "${var.project}-ra-${each.key}"`,
     assume-role policy: principal `rolesanywhere.amazonaws.com`, actions
     `sts:AssumeRole`, `sts:TagSession`, `sts:SetSourceIdentity`, three
     conditions — `ArnEquals aws:SourceArn = aws_rolesanywhere_trust_anchor.this[0].arn`,
     `StringEquals aws:PrincipalTag/x509Subject/CN = "${var.project}-civo-${each.key}"`,
     `StringEquals aws:PrincipalTag/x509Issuer/CN = var.x509_issuer_cn`.
   - `aws_iam_role_policy.consumer[each.key]`: inline policy =
     `each.value.policy_json` (the caller supplies the exact Pod-Identity-derived
     JSON per consumer — this module does not know Route53/SSM/KMS specifics,
     it only wires trust and attaches whatever policy the terragrunt unit hands it).

   Outputs: `trust_anchor_arn`, `profile_arn`, `role_arns` (map keyed by consumer).

2. **Policy JSON to reuse, verified from the actual modules** (do not
   redesign — copy their `data.aws_iam_policy_document` statements
   verbatim into the new terragrunt unit's `locals`, parameterized by
   `hosted_zone_id`/`project`/account/region, since this module is
   AWS-target-and-Civo-target agnostic and the pod-identity modules are
   EKS-Pod-Identity-specific, not directly reusable as Terraform modules
   here):
   - `eso` consumer: `ssm:GetParameter` on the project's
     `postgres-app-password`/`grafana-admin-password` SSM parameter ARNs,
     plus `kms:Decrypt` on `alias/lab-secrets`' target key ARN, condition
     `kms:EncryptionContext:PARAMETER_ARN` = those same two ARNs (copy of
     `external-secrets-pod-identity/main.tf`).
   - `external_dns` consumer: `route53:ChangeResourceRecordSets` +
     `route53:ListResourceRecordSets` scoped to
     `arn:aws:route53:::hostedzone/${hosted_zone_id}`, plus
     `route53:ListHostedZones`/`route53:GetChange` on `"*"` (copy of
     `external-dns-pod-identity/main.tf`).

3. **New terragrunt unit** `terraform/live/bootstrap/rolesanywhere/terragrunt.hcl`,
   modeled exactly on `bootstrap/acm/terragrunt.hcl` (the existing
   `dependency "route53"` pattern):
   ```
   dependency "route53" {
     config_path = "../route53"
     mock_outputs = { zone_id = "MOCK", fqdn = "lab.example.invalid" }
     mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
   }
   ```
   `locals.project = get_env("PROJECT_NAME", "vk-civo-lab")` (this unit
   only ever matters for Civo projects — but must not hardcode "civo" as
   a requirement, since the guard is the CA file's existence, not the
   `PROVIDER` env var, matching CIVO-080's own generalization intent).
   `locals.ca_cert_path = "${get_repo_root()}/secrets/${local.project}/civo-ca-cert.pem"`.
   `inputs.ca_cert_pem = fileexists(local.ca_cert_path) ? file(local.ca_cert_path) : ""`.
   `inputs.hosted_zone_id = dependency.route53.outputs.zone_id`.
   `inputs.consumers` built from the two `data.aws_iam_policy_document`
   blocks in this same terragrunt file's `locals` (terragrunt HCL supports
   `locals` but not native `data` sources for policy documents the way a
   `.tf` file does — so the two JSON policy documents must live as a tiny
   companion module or inline JSON literals in terragrunt `locals` using
   `jsonencode(...)`, not a `data "aws_iam_policy_document"` block, since
   terragrunt config files are HCL evaluated by Terragrunt itself, not by
   Terraform — the implementer must resolve this mechanically: either (a)
   move the two consumer policy documents into the `rolesanywhere` module
   itself as fixed named locals (`local.eso_policy`, `local.external_dns_policy`)
   built from `var.project`/`var.hosted_zone_id`/`data.aws_caller_identity`/`data.aws_region`/`data.aws_kms_alias`
   inside the module, dropping the generic `consumers` map input in favor
   of two fixed consumers — **this is the preferred resolution**, since it
   keeps the terragrunt unit a thin wiring layer like every other unit in
   this repo and avoids inventing an HCL-JSON policy-authoring convention
   that doesn't exist elsewhere in `terraform/live/`).

   **Revised module design given this**: drop the generic `consumers` map
   input. The module hardcodes two named resources
   (`aws_iam_role.eso`/`aws_iam_role.external_dns` or a `for_each` over a
   local map computed inside the module from `var.project` and
   `var.hosted_zone_id`) and builds their policies internally, the same
   way `external-secrets-pod-identity`/`external-dns-pod-identity` do
   today. Module inputs become: `project`, `ca_cert_pem`, `hosted_zone_id`,
   `x509_issuer_cn` (default as above), `session_duration` (default 3600).
   This is simpler, matches the existing repo's module style exactly, and
   avoids a policy-authoring layer that has no precedent here.

4. **`lab-role` additions** (`terraform/modules/lab-role/main.tf`) —
   verified against the actual current file, keep this minimal:
   - New statement `RolesAnywhereManagement`: actions
     `rolesanywhere:CreateTrustAnchor`, `UpdateTrustAnchor`, `DeleteTrustAnchor`,
     `GetTrustAnchor`, `CreateProfile`, `UpdateProfile`, `DeleteProfile`,
     `GetProfile`, `TagResource`, `UntagResource`, `ListTagsForResource`,
     `DisableTrustAnchor`, `EnableTrustAnchor`; resource
     `arn:aws:rolesanywhere:eu-west-1:${local.account}:*`.
   - Extend the existing `PlatformIamRoles` statement's `resources` list
     to add `arn:aws:iam::${local.account}:role/*-ra-*` alongside the
     existing `role/*-eks-*` — it already carries every action needed
     (`iam:CreateRole`, `PutRolePolicy`, `PassRole`, etc.), so this is a
     one-line resource-list addition, not a new statement. Update its
     3-line comment to say it covers both `-eks-` and `-ra-` platform
     roles.
   - **No SSM statement change needed.** Verified: the existing
     `PlatformConfigSsmParameters` statement already includes
     `arn:aws:ssm:*:${local.account}:parameter/*/bootstrap/*`, which
     already matches `parameter/<project>/bootstrap/rolesanywhere/*` — the
     spec's proposed explicit `*/bootstrap/rolesanywhere/*` addition is
     redundant with what's already there. Do not add a redundant
     statement (least-privilege review is more about not padding the
     policy with overlapping grants than about literal spec-text
     compliance) — ledger this as a deliberate deviation from spec §4's
     literal wording if using subagent-driven-development, citing the
     existing wildcard.

5. **`account-up` re-apply**: per spec, `lab-role` lives under
   `terraform/live/account/lab-role/`, applied via `make account-up`
   (account-global, outside the disposable/persistent/bootstrap
   composites, ADR 0021). This step is a real, if small, blast-radius
   change to the live automation identity used by every project (AWS and
   Civo) — gate it the same way as any real-AWS-apply step.

## Global constraints for implementation

- Do not touch AWS-only projects' plans: `ca_cert_pem == ""` must yield
  zero `rolesanywhere`/`ra-*`-role resources, verified by an actual `plan`
  run against the real `vk-lab-platform` project (or any project name with
  no `secrets/<project>/civo-ca-cert.pem`) before and after.
- Do not create a second IAM role or new OIDC trust relationship for this
  work — CIVO-205 (already filed, DRAFT, depends on this spec + CIVO-200)
  is where that gets decided later. This task only adds statements to the
  existing `lab-role`.
- Never put ticket/spec references in Terraform/HCL comments — same rule
  as code comments elsewhere. Comments here explain *why* (e.g., why
  `role/*-ra-*` needs PassRole) not "per CIVO-082".
- The real `bootstrap-up` apply and the negative credential-helper test
  against live AWS are gated: implement and validate everything offline
  (fmt/validate/plan with CA absent and present) first, then stop and ask
  before running the real apply, matching the CIVO-080 ceremony's
  precedent of gating the one truly external/irreversible-ish step
  separately from the rest of autonomous execution.
- `PROVIDER` env var must never leak across commands — any shell run
  during implementation/validation sets `PROVIDER=civo` inline on the
  same command it's needed for, never exported ambient.

## Task breakdown

1. **Module**: write `terraform/modules/rolesanywhere/{main,variables,outputs,versions}.tf`
   per the revised design in point 3 above (two fixed named consumers,
   guarded by `ca_cert_pem`). Run `terraform fmt` and `terraform validate`
   standalone (no terragrunt yet needed for a syntax-level check).

2. **Unit**: write `terraform/live/bootstrap/rolesanywhere/terragrunt.hcl`
   per point 3, wired to `dependency "route53"`. Run
   `PROVIDER=civo PROJECT_NAME=vk-civo-lab terragrunt plan` (or the
   Makefile-wrapped equivalent) twice: once with the real committed CA
   file present (expect the full resource set to appear in the plan),
   and once against a scratch/nonexistent project name with no CA file
   (expect zero `rolesanywhere`/`aws_iam_role` resources — proves the
   AWS-only guard). Neither run applies anything.

3. **`lab-role` additions**: apply the two edits from point 4 to
   `terraform/modules/lab-role/main.tf`. Run `make account-up` in
   plan-only fashion first if the Makefile target supports a dry run;
   otherwise inspect the Terraform plan output before letting the real
   task proceed to apply (see the gate below) — this touches the one IAM
   role every CI run and every local session assumes, for every project.

4. **Real apply (gated — ask before running)**: `PROVIDER=civo make
   bootstrap-up` for `vk-civo-lab`, applying the new `rolesanywhere` unit,
   and the `account-up` apply for the `lab-role` change. Verify: trust
   anchor `ENABLED`, profile exists with 2 role ARNs, both IAM roles
   exist with the expected trust policy conditions, and the four SSM
   outputs (`trust_anchor_arn`, `profile_arn`, `role_arn/eso`,
   `role_arn/external_dns`) are set correctly.

5. **Negative trust-policy test (gated — same ask as Task 4)**: using
   `aws_signing_helper credential-process` from a workstation, prove:
   (a) a self-signed cert not from this CA → `AccessDenied`; (b) an
   operator-issued test leaf cert from the real CA with a wrong CN (not
   matching either consumer's expected subject CN) → `AccessDenied`; (c)
   a correctly-named test leaf cert → succeeds. Any temporary test
   cert/key created for this must be deleted afterward and never
   committed. (The positive/real-workload check that CIVO-085/090 will
   exercise end-to-end is out of scope here — this is a manual trust-model
   proof only.)

6. **Close out**: update `specs/civo/082-rolesanywhere-terraform/spec.md`
   (status → DONE, §14 execution evidence, DoD checkbox) and the
   `specs/civo/README.md` index row.

## Verification

- `terraform fmt -check` / `terraform validate` on the new module.
- `terragrunt plan` for the `rolesanywhere` unit, twice (CA present /
  absent), both offline and free.
- `terragrunt plan` for `terraform/live/bootstrap` against the *AWS-only*
  default project name, confirming no diff beyond the `lab-role` addition
  (proves regression protection).
- Real `bootstrap-up` apply + AWS console/CLI checks (trust anchor state,
  profile role count, SSM parameters) — gated, ask first.
- The three-case negative/positive `aws_signing_helper` test — gated, ask
  first.
- `checkov`/`tfsec` if available in this environment (spec §9), non-blocking
  advisory only if not installed.

## Files touched

- New: `terraform/modules/rolesanywhere/main.tf`, `variables.tf`,
  `outputs.tf`, `versions.tf`.
- New: `terraform/live/bootstrap/rolesanywhere/terragrunt.hcl`.
- Edit: `terraform/modules/lab-role/main.tf` (two additions per point 4).
- Edit: `specs/civo/082-rolesanywhere-terraform/spec.md`,
  `specs/civo/README.md` (index row).
