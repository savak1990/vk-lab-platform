---
id: "HETZ-025"
title: "persistent-hetzner stack: private network, subnet, and SSH key, with additive persistent-up dispatch"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "S"
recommended_model_tier: "standard"
model_rationale: "Two small Terraform units and Terragrunt wiring following the persistent-civo pattern"
effort_estimate: "One session (2–4 h) including a real apply/destroy"
estimate_confidence: "high"
depends_on: ["HETZ-010", "HETZ-015", "HETZ-080"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-025 — Persistent Hetzner stack

## 1. Outcome and rationale

`PROVIDER=hetzner make persistent-up` creates the private network, its
subnet, and the SSH key for the `vk-hetzner-lab` project. It also applies the
AWS `persistent/secrets` unit and the backup bucket, and skips the VPC.
`PROVIDER=hetzner make bootstrap-up` creates the state bucket, the
`hetzner.<root-domain>` zone, and the Roles Anywhere unit, and skips ACM.
These resources are Persistent. The disposable servers attach to them.

There is no reserved IP unit. Hetzner primary IPs attach to servers only,
and the CCM cannot bind a floating IP to a load balancer, so nothing
persistent can hold the ingress address (decisions.md §3).

## 2. Scope and non-goals

In scope: `terraform/live/persistent-hetzner/{network,ssh-key}`, modules
`hcloud-network` and `hcloud-ssh-key`, the `root.hcl` provider and lifecycle
entries, `scripts/lib/region.sh`, `scripts/persistent-up-hetzner.sh`, the
guards, the `lab-role` SSM allowance, and the SSH key material.
Not in scope: the firewall and servers (HETZ-030), the CA ceremony (HETZ-080,
which must run first).

## 3. Current state / evidence

- `root.hcl:48` lifecycle lookup has `persistent-civo`/`cluster-civo`; `:52` `civo_region`; `:58` `civo_stack = contains([...])`; `:62,80` emit `provider "civo"`.
- `scripts/persistent-up-civo.sh` is the civo `persistent-up` branch; the aws recipe is inline (`make -n` byte identity).
- Guards: `persistent-down.sh:87,123,143`, `bootstrap-down.sh:35`, `state-down.sh:30`, `status.sh:27` hold prefix lists; `require-persistent.sh:34-48` checks that `persistent-civo/network/` state is non-empty and hardcodes that unit name.
- `lab-role` allows SSM `*/persistent-civo/*` and `*/cluster-civo/*`.
- `research.md`: `hcloud_network { name, ip_range }`, `hcloud_network_subnet { network_id, type = "cloud", network_zone, ip_range }`; `hcloud_ssh_key { name, public_key }`; both free; the provider reads `HCLOUD_TOKEN`.
- `scripts/generate-secrets.sh` mints a throwaway CA for any non-AWS project when none exists (after HETZ-016).

## 4. Design and contracts

- `root.hcl`: lookup gains `"persistent-hetzner" = "persistent"` and `"cluster-hetzner" = "disposable"`; `hcloud_location = "nbg1"`; `hetzner_stack = contains(["persistent-hetzner", "cluster-hetzner"], path_parts[0])`; when true, emit `provider "hcloud" {}` beside `aws`. No token argument; `HCLOUD_TOKEN` only.
- `scripts/lib/region.sh`: `HCLOUD_LOCATION=nbg1`, `HCLOUD_NETWORK_ZONE=eu-central`.
- `persistent-hetzner/network`: `hcloud_network` named `${project}`, `ip_range = "10.0.0.0/16"`; `hcloud_network_subnet` `type = "cloud"`, `network_zone = "eu-central"`, `ip_range = "10.0.1.0/24"`. Labels per HETZ-015 §16 mapping with `lifecycle = "persistent"`. Writes SSM `/${project}/persistent-hetzner/network/network_id` and `/…/subnet_ip_range` as plain String.
- `persistent-hetzner/ssh-key`: `hcloud_ssh_key` named `${project}` from `file("secrets/${project}/hetzner-ssh-key.pub")`. Writes `/${project}/persistent-hetzner/ssh-key/ssh_key_id`.
- Key material: `make ssh-key-init` (new, `scripts/ssh-key-init.sh`) generates an ed25519 pair in a `mktemp -d` with `umask 077`, writes the public key to `secrets/${project}/hetzner-ssh-key.pub` (committed; public), pipes the private key through `secret-encrypt.sh` as `hetzner-ssh-key`, shreds the temp dir, and refuses to overwrite unless `ROTATE=1`. `.gitignore` gets `!secrets/*/hetzner-ssh-key.pub`. A separate script, not `ca-init`: the two secrets have different lifetimes and rotation runbooks. `generate-secrets.sh` gains the same generate-if-missing treatment for throwaway projects.
- Make: for hetzner, `persistent-up` runs `run --all --filter '!./vpc'` in `persistent`, then `scripts/persistent-up-hetzner.sh` runs `run --all` in `persistent-hetzner`. `persistent-down` reverses. `bootstrap-up` uses `--filter '!./acm'`. The civo and aws recipes are untouched.
- Guards: every prefix list gains `persistent-hetzner/` and `cluster-hetzner/` unconditionally (the CIVO-025 pattern; empty prefixes count zero). `require-persistent.sh` resolves the unit as `${PERSISTENT_EXTRA_DIR}/network/` instead of the civo literal.
- `lab-role`: add SSM ARNs `*/persistent-hetzner/*` and `*/cluster-hetzner/*`; apply with `make account-up` after diffing the rendered policy (CIVO-025 §14 warning: the policy is one document and reverts anything not on the applied branch).
- Ordering rule: run `PROVIDER=hetzner make ca-init` (HETZ-080) before the first `bootstrap-up`, or `generate-secrets.sh` mints a throwaway CA under the real project name and the Roles Anywhere unit anchors trust to it.

## 5. Files/components affected

- `terraform/live/root.hcl` (edit); `terraform/live/persistent-hetzner/{network,ssh-key}/terragrunt.hcl` (new); `terraform/modules/hcloud-network`, `terraform/modules/hcloud-ssh-key` (new, `versions.tf` pins `hetznercloud/hcloud` 1.69.x, lock files).
- `Makefile`, `scripts/persistent-up-hetzner.sh` (new), `scripts/ssh-key-init.sh` (new), `scripts/lib/region.sh`, `scripts/generate-secrets.sh`, `scripts/{persistent-down,bootstrap-down,state-down,status,require-persistent}.sh`, `.gitignore`, `secrets/README.md`.
- `terraform/modules/lab-role/main.tf`.
- State: new keys in `vk-hetzner-lab-tf-state`; AWS and Civo state untouched.

## 6. Implementation steps

1. `PROVIDER=hetzner make ca-init` and `make ssh-key-init`; commit the `.pem`, `.pub`, and `.enc` files.
2. Write the modules; `terraform init` for lock files; edit `root.hcl`; `terragrunt hclfmt`, `validate`.
3. Wire Make, the new script, `region.sh`, the guards; rerun the HETZ-010 goldens for aws and civo.
4. Diff and apply the `lab-role` change with `make account-up`.
5. `PROVIDER=hetzner make state-up`, `bootstrap-up`, `persistent-up`. Check SSM and `hcloud network list`, `hcloud ssh-key list`.
6. `PROVIDER=hetzner make persistent-down`; confirm empty states; keep bootstrap up.

## 7. Dependencies and blockers

HETZ-010 supplies the dispatch and token helper. HETZ-015 declares the stack. HETZ-080 supplies the CA that `bootstrap-up` anchors. HETZ-030 waits for the network id and SSH key id.

## 8. Acceptance criteria

- `bootstrap-up` creates `vk-hetzner-lab-tf-state`, zone `hetzner.<root-domain>` with the NS delegation, and the Roles Anywhere resources; no ACM certificate.
- `persistent-up` creates the network, subnet, and SSH key with the four labels; the three SSM parameters exist; no VPC in the project.
- `hcloud ssh-key describe vk-hetzner-lab` shows the committed public key fingerprint.
- `persistent-down` refuses while `cluster-hetzner/` state has resources (seed a fake object). After destroy, the two units are empty.
- The state files contain no token and no private key (`terraform state pull | grep -c PRIVATE` is 0).

## 9. Validation

Offline: `terraform fmt -check`, `terragrunt validate`, goldens, `shellcheck`. Real cloud: one apply/destroy; expected cost 0 (network, subnet, and key are free).

## 10. AWS regression protection

AWS: `make -n` golden; `terragrunt run --all plan` in `terraform/live/persistent` for the AWS project shows no changes. Civo: `make -n` golden for `PROVIDER=civo`; `terragrunt run --all plan` in `terraform/live/persistent-civo` shows no changes; the generated `provider.tf` for a civo unit is byte-identical (the hcloud block appears only on hetzner paths).

## 11. Rollout and rollback/recovery

Revert Make and `root.hcl`; `persistent-down` removes the units. Deleting the SSH key from Hetzner does not delete the committed material; rotation is `ROTATE=1 make ssh-key-init` followed by `persistent-up` and a `cluster-up` (servers take keys only at creation).

## 12. Risks and unresolved questions

- `hcloud_ssh_key` names are unique per project; a leftover key from HETZ-020 in the same project would collide. The spike uses its own project.
- The `lab-role` policy revert hazard from CIVO-025 §14 applies unchanged.
- Whether `10.0.0.0/16` collides with anything: k3s uses `10.42.0.0/16` (pods) and `10.43.0.0/16` (services); no overlap.

## 13. Definition of done

- [ ] Acceptance criteria met with evidence
- [ ] AWS and Civo no-op plans recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
