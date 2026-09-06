---
id: "CIVO-025"
title: "persistent-civo stack: Civo network and reserved IP, with additive persistent-up dispatch"
status: "READY"
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
updated: "2026-09-06"
completed: null
---

# CIVO-025 — Persistent Civo stack

## 1. Outcome and rationale

`PROVIDER=civo make persistent-up` creates the Civo network and a reserved
IP for the `vk-civo-lab` project and the AWS `persistent/secrets` unit,
skipping the VPC. `PROVIDER=civo make bootstrap-up` creates the state
bucket and the `civo.<root-domain>` zone, skipping ACM. These are the
persistent-lifecycle resources the disposable cluster attaches to.

## 2. Scope and non-goals

In scope: `terraform/live/persistent-civo/{network,reserved-ip}`, modules
`civo-network` and `civo-reserved-ip`, `root.hcl` provider/lifecycle
changes, Make wiring for exclusions and the extra stack, `persistent-down`
and `bootstrap-down` handling, guards. Not in scope: cluster (CIVO-030),
Roles Anywhere unit (CIVO-082).

## 3. Current state / evidence

- `Makefile:104-107` `persistent-up` runs `terragrunt run --all` in `terraform/live/persistent` (units `vpc`, `secrets`).
- `scripts/bootstrap-up.sh` runs `run --all` in `terraform/live/bootstrap` (units `route53`, `acm`).
- `root.hcl:48` lifecycle lookup; `:51-68` provider generation; `:72-85` backend.
- `scripts/persistent-down.sh:74,116` prefix checks; `scripts/bootstrap-down.sh:31`.
- Civo provider: `CIVO_TOKEN` env; `civo_network`, `civo_reserved_ip` resources (research.md).

## 4. Design and contracts

- `root.hcl`: `lifecycle_class` lookup gains `"persistent-civo" = "persistent"`, `"cluster-civo" = "disposable"`; a `civo_region` local `"LON1"`; provider generation emits `provider "civo" { region = "LON1" }` in addition to `aws` when `path_parts[0]` starts with the civo stacks. Token from `CIVO_TOKEN` only.
- Units: `persistent-civo/network` (`civo_network` named `${project}`), `persistent-civo/reserved-ip` (`civo_reserved_ip` named `${project}-ingress`; writes SSM `/${project}/persistent-civo/reserved-ip/address` and `/${project}/persistent-civo/network/id` as plain String).
- Make: for civo, `persistent-up` = `run --all --queue-exclude-dir vpc` in `persistent` then `run --all` in `persistent-civo`; `persistent-down` reverse; `bootstrap-up` = `--queue-exclude-dir acm`. Terragrunt 1.1.3 flag name to be confirmed at implementation (`--queue-exclude-dir` or `--exclude-dir`).
- Guards: `persistent-down.sh` refuses while `cluster-civo/` state has resources; verifies `persistent/secrets` and both civo units empty after destroy; `bootstrap-down.sh` refuses on `persistent-civo/`.
- Tags: `tags = "Project=${project} Lifecycle=persistent ManagedBy=terraform"` where the resource supports tags.

## 5. Files/components affected

- `terraform/live/root.hcl` (edit), `terraform/live/persistent-civo/{network,reserved-ip}/terragrunt.hcl` (new), `terraform/modules/civo-network`, `terraform/modules/civo-reserved-ip` (new, with `versions.tf` pinning `civo/civo` and lock files).
- `Makefile`, `scripts/bootstrap-up.sh`, `scripts/bootstrap-down.sh`, `scripts/persistent-down.sh`, `scripts/status.sh` (edit).
- `terraform/modules/lab-role/main.tf`: SSM path allowance for `*/persistent-civo/*` (coordinate with CIVO-082).
- State: new keys in `vk-civo-lab-tf-state`. No AWS project state touched.

## 6. Implementation steps

1. Pin the Civo provider version in the modules; `terraform init` for lock files.
2. Edit `root.hcl`; run `terragrunt hclfmt`, `validate` in both new units with `CIVO_TOKEN` set.
3. Wire Make and scripts; keep aws branches literally unchanged (golden `make -n` from CIVO-010 re-run).
4. `PROVIDER=civo make bootstrap-up` then `persistent-up` for real; verify SSM params and Civo dashboard.
5. `PROVIDER=civo make persistent-down`; verify empty states; keep bootstrap up.

## 7. Dependencies and blockers

CIVO-010 (PROVIDER, defaults, token helper); CIVO-015 (ADR 0025 declares the stack). Parallel: CIVO-050.

## 8. Acceptance criteria

- `PROVIDER=civo make bootstrap-up` creates `vk-civo-lab-tf-state`, zone `civo.<root-domain>` with NS delegation, no ACM.
- `PROVIDER=civo make persistent-up` creates network and reserved IP; no VPC in the civo project; SSM params present.
- `make persistent-up` (aws) unchanged: same units, same plan (no-op plan against the existing AWS project).
- `persistent-down` refuses while `cluster-civo/` state exists (simulate by seeding an object) and cleans both civo units.
- `terraform state` for the civo units contains no token or kubeconfig.

## 9. Validation

Offline: `terraform fmt -check`, `terragrunt validate`, `tflint` if present, `make -n` golden. Real cloud: apply/destroy under the civo project; expected cost: reserved IP for minutes, cents.

## 10. AWS regression protection

`make -n` golden diff; `terragrunt run --all plan` in `terraform/live/persistent` for the AWS project shows no changes; `root.hcl` changes are additive (new lookup keys, provider block only for civo paths).

## 11. Rollout and rollback/recovery

Revert Make/root.hcl; `persistent-down` for civo removes resources. Reserved IP deletion releases the address (DNS must be re-pointed on recreate; ExternalDNS handles it).

## 12. Risks and unresolved questions

- Terragrunt exclusion flag name for 1.1.3.
- Reserved IP price (fill from spike).

## 13. Definition of done

- [ ] Acceptance criteria met with evidence
- [ ] AWS no-op plan recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
