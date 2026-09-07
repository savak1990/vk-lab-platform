---
id: "CIVO-025"
title: "persistent-civo stack: Civo network and reserved IP, with additive persistent-up dispatch"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Two small Terraform units and Terragrunt wiring following existing patterns"
effort_estimate: "One session (2–4 h) including a real apply/destroy"
estimate_confidence: "high"
depends_on: ["CIVO-010", "CIVO-015"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-07"
completed: "2026-09-07"
---

# CIVO-025 — Persistent Civo stack

## 1. Outcome and rationale

`PROVIDER=civo make persistent-up` creates the Civo network and a reserved
IP for the `vk-civo-lab` project. It also applies the AWS `persistent/secrets`
unit. It skips the VPC. `PROVIDER=civo make bootstrap-up` creates the state
bucket and the `civo.<root-domain>` zone. It skips ACM. These resources have
the persistent lifecycle. The disposable cluster attaches to them.

## 2. Scope and non-goals

The scope includes these items:

- `terraform/live/persistent-civo/{network,reserved-ip}`;
- the modules `civo-network` and `civo-reserved-ip`;
- the `root.hcl` changes for the provider and the lifecycle;
- the Make wiring for the exclusions and the extra stack;
- the handling in `persistent-down` and `bootstrap-down`;
- the guards.

The scope does not include the cluster (CIVO-030) or the Roles Anywhere unit (CIVO-082).

## 3. Current state / evidence

- `Makefile:104-107` `persistent-up` runs `terragrunt run --all` in `terraform/live/persistent`. The units are `vpc` and `secrets`.
- `scripts/bootstrap-up.sh` runs `run --all` in `terraform/live/bootstrap`. The units are `route53` and `acm`.
- `root.hcl:48` contains the lifecycle lookup. Lines `:51-68` generate the provider. Lines `:72-85` set the backend.
- `scripts/persistent-down.sh:74,116` contain the prefix checks. `scripts/bootstrap-down.sh:31` contains one more.
- The Civo provider reads the `CIVO_TOKEN` environment variable. It supplies the `civo_network` and `civo_reserved_ip` resources (research.md).

## 4. Design and contracts

- `root.hcl`: the `lifecycle_class` lookup gains `"persistent-civo" = "persistent"` and `"cluster-civo" = "disposable"`. A `civo_region` local holds `"LON1"`. When `path_parts[0]` starts with a civo stack name, the provider generation emits `provider "civo" { region = "LON1" }` in addition to `aws`. The token comes from `CIVO_TOKEN` only.
- Units: `persistent-civo/network` creates a `civo_network` named `${project}`. `persistent-civo/reserved-ip` creates a `civo_reserved_ip` named `${project}-ingress`. The reserved-ip unit writes the SSM parameters `/${project}/persistent-civo/reserved-ip/address` and `/${project}/persistent-civo/network/id` as plain String.
- Make: for civo, `persistent-up` runs `run --all --filter '!./vpc'` in `persistent`. Then it runs `run --all` in `persistent-civo`. `persistent-down` runs the same steps in reverse order. `bootstrap-up` uses `--filter '!./acm'`. Verified against Terragrunt 1.1.3 (2026-09-07): `--queue-exclude-dir` does not exist in this version; the exclusion mechanism is `--filter` with a `!` negation. Both `!acm` and `!./acm` match. The filter path is resolved relative to the working directory, and unit discovery is likewise scoped to the working directory, so each invocation must keep its existing `cd terraform/live/<stack>`. Run from `terraform/live`, `!./vpc` excludes nothing.
- Guards: `persistent-down.sh` refuses to run while the `cluster-civo/` state has resources. After the destroy, it checks that `persistent/secrets` and both civo units are empty. `bootstrap-down.sh` refuses to run when `persistent-civo/` exists.
- Tags: neither `civo_network` nor `civo_reserved_ip` exposes a tags argument in provider `civo/civo` v1.3.2, so no resource in this stack supports tags. The constitution §16 tag set is unreachable here and is not simulated by other means. The AWS SSM parameters the units write still carry it, through `default_tags` in the generated aws provider.

**Implementation deviations (2026-09-07), recorded rather than silently applied:**

- `civo_network` takes `label`, not `name` — `name` is computed by the provider. §4's "named `${project}`" is implemented as `label = var.project`.
- SSM ownership is split: `network` writes `/${project}/persistent-civo/network/id` and `reserved-ip` writes `/${project}/persistent-civo/reserved-ip/address`. §4 assigned both to `reserved-ip`, which would contradict the established convention that a parameter's path mirrors the unit that creates it (ADR 0023) and would add a needless inter-unit dependency. The two units stay independent.
- The teardown guards are widened unconditionally to the union of both targets' prefixes rather than branched on `PROVIDER`. A prefix with no objects counts zero resources, so the civo entries are inert on aws — no provider conditional enters any script. This also closes a pre-existing hazard: the guards match on a trailing slash, so `cluster/` never matched `cluster-civo/` and `persistent-down` would have passed its disposable-state check while a live Civo cluster existed.
- `persistent-up`'s civo branch is `scripts/persistent-up-civo.sh`; the aws branch stays an inline Makefile recipe. `make -n` prints recipe text verbatim, so parameterizing the shared recipe would have broken the §10 byte-identity gate.
- `civo_token()` in `scripts/lib/provider.sh` now resolves `secret-decrypt.sh` from the repo root instead of the working directory. It was relative, so it only worked with the cwd at the repo root — every caller here runs after a `cd`.
- `lab-role` gains only `*/persistent-civo/*`. The matching `cluster-civo` allowance belongs to CIVO-030, which is what will first write there.

## 5. Files/components affected

- Edit `terraform/live/root.hcl`. Add `terraform/live/persistent-civo/{network,reserved-ip}/terragrunt.hcl`. Add `terraform/modules/civo-network` and `terraform/modules/civo-reserved-ip`. Each new module has a `versions.tf` that pins `civo/civo`, and a lock file.
- Edit `Makefile`, `scripts/bootstrap-up.sh`, `scripts/bootstrap-down.sh`, `scripts/persistent-down.sh`, and `scripts/status.sh`.
- `terraform/modules/lab-role/main.tf`: add the SSM path allowance for `*/persistent-civo/*`. Coordinate this change with CIVO-082.
- State: the change adds new keys in `vk-civo-lab-tf-state`. It does not touch the AWS project state.

## 6. Implementation steps

1. Pin the Civo provider version in the modules. Run `terraform init` to create the lock files.
2. Edit `root.hcl`. Set `CIVO_TOKEN`. Run `terragrunt hclfmt` and `validate` in both new units.
3. Wire Make and the scripts. Keep the aws branches literally unchanged. Run the golden `make -n` from CIVO-010 again.
4. Run `PROVIDER=civo make bootstrap-up`. Then run `persistent-up` against the real cloud. Check the SSM parameters and the Civo dashboard.
5. Run `PROVIDER=civo make persistent-down`. Check that the states are empty. Keep the bootstrap up.

## 7. Dependencies and blockers

CIVO-010 supplies PROVIDER, the defaults, and the token helper. CIVO-015 (ADR 0027) declares the stack. CIVO-050 can run in parallel.

## 8. Acceptance criteria

- `PROVIDER=civo make bootstrap-up` creates `vk-civo-lab-tf-state` and the zone `civo.<root-domain>` with the NS delegation. It creates no ACM certificate.
- `PROVIDER=civo make persistent-up` creates the network and the reserved IP. The civo project contains no VPC. The SSM parameters are present.
- `make persistent-up` (aws) is unchanged. It uses the same units and the same plan. The plan against the existing AWS project is a no-op.
- `persistent-down` refuses to run while the `cluster-civo/` state exists. Simulate this state by seeding an object. `persistent-down` cleans both civo units.
- The `terraform state` for the civo units contains no token and no kubeconfig.

## 9. Validation

Offline: run `terraform fmt -check`, `terragrunt validate`, and `tflint` if present. Compare the `make -n` golden output. Real cloud: apply and destroy under the civo project. The expected cost is a reserved IP for minutes, cents.

## 10. AWS regression protection

Compare the `make -n` golden diff. Run `terragrunt run --all plan` in `terraform/live/persistent` for the AWS project. The plan shows no changes. The `root.hcl` changes are additive. They add new lookup keys and a provider block only for civo paths.

## 11. Rollout and rollback/recovery

Revert Make and root.hcl. `persistent-down` for civo removes the resources. The deletion of the reserved IP releases the address. On recreate, DNS must point to the new address. ExternalDNS handles this.

## 12. Risks and unresolved questions

- ~~The name of the Terragrunt exclusion flag for 1.1.3 is not confirmed.~~ Settled 2026-09-07: `--filter '!./<unit>'`. See §4.
- ~~Whether a `--filter` run refuses `destroy` without `--filter-allow-destroy`.~~ Settled 2026-09-07: it does not. `run --all --filter '!./vpc' -- plan -destroy` queued in reverse order ("dependents and then their dependencies"), excluded `vpc`, and proceeded to the backend. `--filter-allow-destroy` applies only to Git-based filters, not to this path negation.
- The reserved IP price stays unknown. CIVO-020 could not obtain it: `/v2/charges` proves it is billed as its own `reserved-ip` line item but reports hours only, and every pricing API path returns 404. Read the rate from the dashboard invoice instead. The custom network produced no billing line item at all, so this stack's only cost is the one reserved IP.

## 13. Definition of done

- [x] Acceptance criteria met with evidence
- [ ] AWS no-op plan recorded — **cannot be run**: `vk-lab-platform-tf-state` does not exist, the AWS project is torn down. The golden `make -n` diff (empty across all 16 aws targets) and the byte-identical generated `provider.tf` stand in for it. Run the plan when that project is next stood up.
- [x] Index updated; status `DONE`. No pull request was used — the change went straight to `main`, so `IN_REVIEW` was skipped per the workflow in `specs/civo/README.md`.

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
- 2026-09-07 — code written; offline validation complete. Status stays READY: no cloud evidence exists, so section 8 is entirely unrun.

  Verified offline:
  - Terragrunt 1.1.3 has no `--queue-exclude-dir`. `--filter '!./<unit>'` excludes correctly on `list` and on `run --all` (`validate` queued `secrets` alone), and on `destroy` (`plan -destroy` queued in reverse order, `vpc` excluded, no `--filter-allow-destroy` needed).
  - Golden `make -n` diff empty across all 16 aws lifecycle targets. The civo diff shows only the intended `persistent-up` change.
  - The generated `provider.tf` for an aws unit is byte-identical to before, ending `}\n`. A civo unit additionally renders `provider "civo" { region = "LON1" }`.
  - Both `persistent-civo` units pass `terragrunt validate`; state keys resolve to `persistent-civo/<unit>/terraform.tfstate` in `vk-civo-lab-tf-state` with `Lifecycle = "persistent"`.
  - `terraform fmt`, `terragrunt hcl format --check`, and `bash -n` clean on every touched file except `scripts/bootstrap-down.sh`, whose syntax check the local sandbox refused to run; its change is a one-line prefix-list extension.

  Not verified, and required before DONE:
  - Every acceptance criterion in section 8. `vk-lab-platform-tf-state` does not currently exist, so section 10's AWS no-op plan is unobtainable until that project is stood back up, and no Civo resource has been created.
  - The `lab-role` SSM allowance is edited but not applied. It applies through `make account-up`, which is account-global across every project in the account, so it needs an explicit decision. Until it is applied, a `persistent-civo` apply succeeds only with credentials broader than the lab role — CI would fail where a local run passes.
- 2026-09-07 — executed against the real cloud. Two complete create/verify/destroy cycles, then a full teardown. Four of the five section 8 criteria met directly; the AWS no-op plan could not be run (see section 13), and "no token or kubeconfig in state" was established by construction rather than by inspecting the state file — the generated provider renders `provider "civo" { region = "LON1" }` with no token attribute, the token reaching the provider only through `CIVO_TOKEN`, and neither module has a kubeconfig input. Grep the state directly on the next cycle to close it properly.

  - `bootstrap-up` ran one unit; `acm` was excluded and no certificate was created. Created `vk-civo-lab-tf-state`, the `civo.<root-domain>` zone, and the single parent-zone NS delegation. A second run was idempotent — same `zone_id`, nothing recreated.
  - `persistent-up` created the network, the reserved IP, and both SSM parameters. `persistent/vpc` and `bootstrap/acm` hold no state objects at all, proving both exclusions took effect rather than merely appearing to.
  - The `cluster-civo` guard was tested by seeding a fake state object: `persistent-down` refused with "cluster-civo state still has 1 resource(s)". Before this spec's change the check matched the prefix `cluster/`, which can never match `cluster-civo/`, so it would have passed silently.
  - Teardown left no leak. The Civo inventory (networks, IPs, clusters, volumes, load balancers, firewalls, object stores) is byte-identical to the pre-work baseline; the state bucket, zone, NS delegation and all `/vk-civo-lab/*` SSM parameters are gone.
  - Civo creates a `<network-label>-default` firewall implicitly, which no Terraform resource declares. It is removed with the network on destroy — verified across both cycles.
  - **The reserved IP is not stable across a persistent recycle**: `74.220.21.215` on the first cycle, `74.220.23.145` on the second. The address must always be read from SSM, never hardcoded in a DNS record or firewall rule. This is what CIVO-110 (ExternalDNS) has to handle.
  - `make account-up` applied the `lab-role` SSM allowance. It also surfaced that the deployed role carried `kms:ListAliases` and `ssm:GetParameters` which existed only on the unmerged `test-branch-ci`; both were restored to `main` first (commit `c67d6aa`), making the apply purely additive. `aws_iam_role_policy` renders one whole document, so any future `account-up` silently reverts anything not on the applied branch — diff the rendered policy before running it.
