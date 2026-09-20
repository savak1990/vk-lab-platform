---
id: "HETZ-018"
title: "Roles Anywhere chain names parametrized by provider, with Civo names byte-identical"
status: "IN_REVIEW"
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
updated: "2026-09-20"
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

## 4a. Deviations from §4 and §5

Each deviation below was measured on the branch, not assumed.

- **D1 — Terraform learns the provider from disk, not from `PROVIDER`.** §4
  passes `provider_name` from `get_env("PROVIDER", "aws")`. Rejected. The CA
  bytes come from a `PROJECT_NAME`-derived path and the name would come from a
  separate variable, so the two can drift. A bare
  `terragrunt run --all plan` against the Civo project without `PROVIDER` set —
  which is exactly what §9 asks an operator to run — would resolve the path to
  `aws-ca-cert.pem`, find nothing, set `ca_cert_pem = ""`, drop every resource
  to `count = 0`, and plan **a destroy of the whole live chain** with state
  pointed at the correct bucket. Today that is unreachable, because the path is
  a literal. `bootstrap/rolesanywhere/terragrunt.hcl` now resolves the provider
  by an ordered `fileexists` lookup over `civo` then `hetzner`, falling through
  to `aws`, and derives both the path and the name from the file it finds. One
  source for the name and the bytes; no new environment dependency.
- **D2 — `root.hcl` is not changed.** §5 names it for a `local.provider`.
  Included locals are not visible to a child unit's own `locals` block — which
  is why all 18 units re-read `get_env("PROJECT_NAME", ...)` themselves — so a
  local there could not be consumed by the unit that needs it. D1 makes it
  unnecessary in any case.
- **D3 — five Terraform sites, not the four §3 lists.** The profile at
  `modules/rolesanywhere/main.tf:173` is `"${var.project}-civo"`, with no
  trailing hyphen, so §8's `grep -- '-civo-'` does not match it. The
  acceptance criterion is amended to a bare
  `grep -rn civo terraform/modules/rolesanywhere`.
- **D4 — the issuer name resolves through a helper, not through the values key
  alone.** §4 gives `workloadIdentity.issuerName` a default of
  `{{ .Values.target }}-workload-ca`. Helm cannot default a value in
  `values.yaml` against another value, so the default lives in a new
  `platform.workloadIssuerName` helper beside `platform.selfManaged`, and
  `issuerName: ""` in `values.yaml` selects it. Both the ClusterIssuer and the
  Certificates include the helper, so the two can never disagree.
- **D5 — one PR, not shared with HETZ-016.** §11 says "one PR with HETZ-016".
  Stale: PR #39 was already open and in review when this spec started. HETZ-018
  is its own PR, branched from the HETZ-016 branch and rebased onto it.
- **D6 — the no-change Civo plan of §8 could not be run.** The `vk-civo-lab`
  project is torn down to zero: `vk-civo-lab-tf-state` does not exist, so
  `terragrunt` fails at `init` before it can plan. The live trust anchor in the
  account is `vk-civo-ci-civo-workload-ca`, created by the CI lifecycle run for
  PR #39 against the disposable CI project. The plan gate is therefore replaced
  by the three-project expression probe in §14, which proves the resolution
  directly, plus the `lifecycle-civo` CI job, which builds the whole chain from
  nothing and is the real end-to-end gate.
- **D7 — `tests/manifests/civo-090/wrong-ca-issuer.yaml` is left alone.** Its
  `commonName: "vk-civo-lab-civo-eso"` is a deliberate wrong-CN negative-test
  fixture, not a chain name.
- **D8 — the hetzner issuer is added to the render check's object set.**
  `REQUIRED_OBJECTS_HETZNER` gains
  `ClusterIssuer__cluster__hetzner-workload-ca`. Inert until HETZ-050 puts
  `hetzner` in the render loop, but it is the durable form of the correctness
  check.

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
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-20 — implemented on branch `hetzner-018-identity-chain-provider-naming`,
  branched from `hetzner-016-non-aws-generalisation` and rebased onto it after
  that branch was rebased on `main` at `9925d36`. Deviations D1 to D8 in §4a.

  Civo byte-identity is a regression gate only: it passes equally if the
  parametrization is correct or if `civo` was accidentally hardcoded again. The
  correctness gate is the hetzner render.

  | Gate | Result |
  |---|---|
  | `helm template` of `gitops/` and `gitops/bootstrap/` for aws and for civo, full `--set` list, normalized one file per object | `diff -ru` before/after empty (49 aws objects, 45 civo objects) |
  | `helm template --set target=hetzner`, same normalization | exactly 6 objects change, and only as intended: `ClusterIssuer/civo-workload-ca` becomes `ClusterIssuer/hetzner-workload-ca` with `spec.ca.secretName` tracking it, and four Certificates move from CN `<project>-civo-<consumer>` to `<project>-hetzner-<consumer>` |
  | `make gitops-check` | aws matches the golden baseline; civo and local object sets unchanged. The golden holds no identity object at all, so it could not move |
  | Provider resolution, the D1 expression run against real directories | `vk-civo-lab` to `civo` and `vk-civo-lab-civo-workload-ca` with the module creating; `vk-lab-platform` to `aws` and the module creating nothing; a `hetzner-ca-cert.pem` fixture to `hetzner` and `vk-hetzner-lab-hetzner-workload-ca`. The civo case was run with `PROVIDER` unset, which is the case D1 exists for |
  | `terraform init -backend=false && terraform validate` on `modules/rolesanywhere` | valid |
  | `terraform fmt -check`, `terragrunt hcl fmt --check` | clean |
  | `make -n`, 25 targets x {unset, aws, civo, hetzner} | `diff -ru` against the HETZ-016 baseline empty, over all 100 combinations |
  | `helm lint gitops/`, `helm lint gitops/bootstrap` | 0 charts failed |
  | `bash -n` on the four edited scripts | clean |
  | `PROVIDER=aws make ca-init` | exits 1, naming Pod Identity |
  | `PROVIDER=civo make ca-init` | still refuses to overwrite `secrets/vk-civo-lab/civo-ca-cert.pem` |
  | `PROVIDER=hetzner PROJECT_NAME=hz-ca-probe make ca-init` | wrote `hetzner-ca-cert.pem` and `hetzner-ca-key.enc`, subject `CN=hz-ca-probe-hetzner-workload-ca`. Output deleted after the check |
  | `.gitignore` | `hetzner-ca-cert.pem` is tracked by `!secrets/*/*-ca-cert*.pem`; a `hetzner-ca-key-next.pem` stays ignored, preserving the CIVO-080 §8 property |
  | `grep -rn civo terraform/modules/rolesanywhere` | one hit, the `provider_name` description naming the valid values |
  | `make specs-check` | valid |

  `shellcheck`, `yamllint` and `actionlint` are not installed locally; CI runs
  them. The Civo `argo-up` proof of `ensure_ca_secret` is deferred to the
  `lifecycle-civo` CI job, which mints a CA, applies the chain and brings up
  the cluster from nothing — a stronger gate than the read-only plan §9 asked
  for, and the only one available (D6).
