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
- Make: for civo, `persistent-up` runs `run --all --queue-exclude-dir vpc` in `persistent`. Then it runs `run --all` in `persistent-civo`. `persistent-down` runs the same steps in reverse order. `bootstrap-up` uses `--queue-exclude-dir acm`. The `--queue-exclude-dir` flag exists in Terragrunt 1.x. It is an alias of `--filter`. It takes a glob relative to the working directory. Test whether `acm` or `./acm` matches under 1.1.3.
- Guards: `persistent-down.sh` refuses to run while the `cluster-civo/` state has resources. After the destroy, it checks that `persistent/secrets` and both civo units are empty. `bootstrap-down.sh` refuses to run when `persistent-civo/` exists.
- Tags: set `tags = "Project=${project} Lifecycle=persistent ManagedBy=terraform"` on each resource that supports tags.

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

CIVO-010 supplies PROVIDER, the defaults, and the token helper. CIVO-015 (ADR 0025) declares the stack. CIVO-050 can run in parallel.

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

- The name of the Terragrunt exclusion flag for 1.1.3 is not confirmed.
- The reserved IP price is unknown. Fill it in from the spike.

## 13. Definition of done

- [ ] Acceptance criteria met with evidence
- [ ] AWS no-op plan recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
