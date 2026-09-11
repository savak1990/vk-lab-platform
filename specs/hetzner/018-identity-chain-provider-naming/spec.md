---
id: "HETZ-018"
title: "Roles Anywhere chain names parametrized by provider, with Civo names byte-identical"
status: "DRAFT"
priority: "P0"
milestone: "M0"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Renames objects in the live Civo trust chain (trust anchor, trust-policy CN conditions, issuer Secret); a wrong default breaks every AWS credential on Civo"
effort_estimate: "One session (3–5 h) including a Civo plan and render proof"
estimate_confidence: "medium"
depends_on: ["HETZ-010", "HETZ-016"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-018 — Identity chain names per provider

## 1. Outcome and rationale

The Roles Anywhere chain names its objects `<project>-<provider>-…` instead of
`<project>-civo-…`. For the Civo project every rendered string, ARN, file
name, and trust-policy condition is byte-identical to today. For the Hetzner
project the same code produces `vk-hetzner-lab-hetzner-…` names, files
`secrets/vk-hetzner-lab/hetzner-ca-cert.pem` and `hetzner-ca-key.enc`, and
`make ca-init` with `PROVIDER=hetzner`. CIVO-080 §12 already recorded that a
second non-EKS provider would need this rename; the user chose to
parametrize rather than reuse the `civo` literal or rename globally.

## 2. Scope and non-goals

In scope: `terraform/modules/rolesanywhere`, its terragrunt unit,
`gitops/templates/platform/shared/identity/*` (after the HETZ-016 move),
`scripts/civo-ca-init.sh` → `scripts/ca-init.sh`, the `Makefile` target,
`scripts/secret-decrypt.sh` name, `.gitignore`, `scripts/generate-secrets.sh`,
`ensure_ca_secret` in `argo-up.sh`, the `civoIdentity` values key.
Not in scope: creating any Hetzner resource (HETZ-080), the sidecar
template (unchanged), CIVO-200's intermediate CA (it inherits the variable).

## 3. Current state / evidence

- `terraform/modules/rolesanywhere/main.tf`: trust anchor `${project}-civo-workload-ca`, profile `${project}-civo`, per-consumer roles `${project}-ra-<consumer>` with trust-policy condition `aws:PrincipalTag/x509Subject/CN = ${project}-civo-<consumer>`, issuer CN condition `${project}-civo-workload-ca`. `terragrunt.hcl` reads `secrets/${project}/civo-ca-cert.pem` and guards on `fileexists`.
- `gitops/…/identity/certificates.yaml`: `commonName: <project>-civo-<consumer>`; `issuer.yaml`: ClusterIssuer and Secret `civo-workload-ca`; values key `civoIdentity.consumers`.
- `scripts/argo-up.sh:218-222` `ensure_ca_secret`: reads `secrets/${PROJECT_NAME}/civo-ca-cert.pem`, decrypts `civo-ca-key`, creates Secret `civo-workload-ca` in `cert-manager`.
- `scripts/civo-ca-init.sh:16-20`: file names `civo-ca-cert[-next].pem`, key names `civo-ca-key[-next]`; CN `<project>-civo-workload-ca`. `Makefile:274-280` target `civo-ca-init`. `scripts/generate-secrets.sh:76-85`. `.gitignore:35` `!secrets/*/civo-ca-cert*.pem`.
- The IAM role names `${project}-ra-<consumer>` carry no provider string and stay.

## 4. Design and contracts

- Terraform: `modules/rolesanywhere` gains `variable "provider_name" { type = string }` (not `provider`, a reserved word). Every `-civo-` literal becomes `-${var.provider_name}-`. The terragrunt unit passes `provider_name = local.provider` where `local.provider` derives from the `PROVIDER` environment variable read by `root.hcl` (`get_env("PROVIDER", "aws")`). For the Civo project the value is `civo`, so the plan is a no-op. The CA path becomes `secrets/${project}/${provider}-ca-cert.pem`.
- GitOps: values key `civoIdentity` → `workloadIdentity` with the same shape plus `issuerName` defaulting to `{{ .Values.target }}-workload-ca`. `certificates.yaml` CN `{{ .Values.project }}-{{ .Values.target }}-{{ $consumer }}`. `issuer.yaml` uses `workloadIdentity.issuerName` for both the ClusterIssuer and the Secret. For `target=civo` every string renders as today.
- Scripts: `scripts/ca-init.sh` (git mv from `civo-ca-init.sh`) reads `PROVIDER` through `provider.sh`, refuses `PROVIDER=aws`, and uses `${PROVIDER}-ca-cert[-next].pem`, `${PROVIDER}-ca-key[-next]`, CN `<project>-${PROVIDER}-workload-ca`. `make ca-init` replaces `civo-ca-init`; the old target is removed, not aliased, and the README and CIVO-080 §14 note the rename. `secret-decrypt.sh` needs no change: the name is passed by the caller. `.gitignore`: `!secrets/*/*-ca-cert*.pem`. `generate-secrets.sh` and `ensure_ca_secret` use the same `${PROVIDER}` names.
- Cross-cutting rule, recorded in `secrets/README.md`: the provider string in these names identifies the trust chain, not the cloud API; a project has exactly one chain.

## 5. Files/components affected

- `terraform/modules/rolesanywhere/{main,variables}.tf`, `terraform/live/bootstrap/rolesanywhere/terragrunt.hcl`, `terraform/live/root.hcl` (`local.provider`).
- `gitops/templates/platform/shared/identity/{certificates,issuer}.yaml`, `gitops/values.yaml`, `gitops/bootstrap/values.yaml` and `root-application.yaml` pass-through for the renamed key.
- `scripts/ca-init.sh` (moved), `scripts/generate-secrets.sh`, `scripts/argo-up.sh`, `Makefile`, `.gitignore`, `secrets/README.md`.
- `specs/civo/080`, `082`, `085` §14 notes; CIVO-200 §4 wording (`<project>-<provider>-workload-ica`).

## 6. Implementation steps

1. Capture the Civo golden render and `terragrunt run --all plan` output for `bootstrap/rolesanywhere` under the Civo project (expect no changes before the edit).
2. Add the Terraform variable and the terragrunt wiring; plan again: no changes.
3. Rename the values key and the template strings; render `civo`: identical.
4. Move and edit the script; update the Make target, `.gitignore`, `generate-secrets.sh`, `ensure_ca_secret`.
5. `PROVIDER=hetzner make ca-init PROJECT_NAME=throwaway` in a scratch checkout: files and CN carry `hetzner`; delete the output.
6. Update the Civo spec notes and README.

## 7. Dependencies and blockers

HETZ-016 must have moved `identity/` to `shared/` and introduced the helper. HETZ-080 waits for this spec; CIVO-200 must merge before or rebase on it.

## 8. Acceptance criteria

- `terragrunt run --all plan` in `terraform/live/bootstrap` for `vk-civo-lab`: "No changes" for `rolesanywhere`.
- The `civo` golden render is byte-identical; the `aws` render is unchanged (identity objects are gated off on aws).
- `grep -rn 'civo-workload-ca\|-civo-' terraform/modules/rolesanywhere gitops/templates scripts` returns nothing.
- `PROVIDER=civo make ca-init` refuses to overwrite the existing Civo CA (same guard as before). `PROVIDER=aws make ca-init` exits 1 with a message.
- `argo-up` on Civo finds the CA at the new path expression and creates the Secret with the unchanged name `civo-workload-ca`.

## 9. Validation

Offline: plan, renders, `shellcheck`, `terraform fmt -check`, `terraform validate`. Real cloud: the Civo plan is read-only; one Civo `argo-up` on an existing cluster to prove `ensure_ca_secret` (cents). Cost: under 1 USD.

## 10. AWS regression protection

AWS: identity objects do not render on aws; the golden render and the `bootstrap` plan for the AWS project (guarded off by `fileexists`, no unit applies) are unchanged. Civo: the no-change plan on the live `rolesanywhere` unit is the primary gate; a single changed trust-policy condition would show as an in-place update and fails the spec. The Civo golden render is the second gate.

## 11. Rollout and rollback/recovery

One PR with HETZ-016. A revert restores the literals; because the Civo names never change on disk or in AWS, rollback has no state impact. If the plan ever shows a replacement of the trust anchor, stop: the default is wrong.

## 12. Risks and unresolved questions

- `get_env("PROVIDER")` in `root.hcl` makes Terraform output depend on the environment. This is already true for `PROJECT_NAME`; `provider.sh` sets both, and CI exports both. Document it next to the existing `PROJECT_NAME` read.
- CIVO-200 (intermediate CA) is READY and may land first; its `-civo-workload-ica` strings must then be parametrized here as well.
- A cached `civo-ca-init` in operator shell history: the target is gone; the error message names `make ca-init`.

## 13. Definition of done

- [ ] No-change Civo plan and identical renders attached
- [ ] Old script name and Make target removed; README updated
- [ ] Civo spec notes added; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
