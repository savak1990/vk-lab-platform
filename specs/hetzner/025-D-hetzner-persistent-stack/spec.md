---
id: "HETZ-025"
title: "persistent-hetzner stack: private network, subnet, and SSH key, with additive persistent-up dispatch"
status: "DONE"
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
updated: "2026-09-21"
completed: ""
---

# HETZ-025 — Persistent Hetzner stack

## 1. Outcome and rationale

`PROVIDER=hetzner make persistent-up` creates the private network, its
subnet, and the SSH key for the `vk-hetzner-lab` project. It also applies the
AWS `persistent/secrets` unit and the backup bucket, and skips the VPC.
`PROVIDER=hetzner make bootstrap-up` creates the state bucket, the
`hz.<root-domain>` zone, and the Roles Anywhere unit, and skips ACM.
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
- `scripts/lib/region.sh`: `HCLOUD_LOCATION=nbg1`, `HCLOUD_NETWORK_ZONE=eu-central`. **Note added 2026-09-21:** HETZ-020 measured `cx33` as orderable in `hel1` as well as `nbg1`, with `fsn1` at zero for every server type. Both are `eu-central`, so a second *location* is a cheaper stock fallback than a second SKU, and the network built here would not have to change. The constant stays `nbg1` for M1; HETZ-175 is where that acts.
- `persistent-hetzner/network`: `hcloud_network` named `${project}`, `ip_range = "10.0.0.0/16"`; `hcloud_network_subnet` `type = "cloud"`, `network_zone = "eu-central"`, `ip_range = "10.0.1.0/24"`. Labels per HETZ-015 §16 mapping with `lifecycle = "persistent"`. Writes SSM `/${project}/persistent-hetzner/network/network_id` and `/…/subnet_ip_range` as plain String.
- `persistent-hetzner/ssh-key`: `hcloud_ssh_key` named `${project}` from `file("secrets/${project}/hetzner-ssh-key.pub")`. Writes `/${project}/persistent-hetzner/ssh-key/ssh_key_id`.
- Key material: `make ssh-key-init` (new, `scripts/ssh-key-init.sh`) generates an ed25519 pair in a `mktemp -d` with `umask 077`, writes the public key to `secrets/${project}/hetzner-ssh-key.pub` (committed; public), pipes the private key through `secret-encrypt.sh` as `hetzner-ssh-key`, shreds the temp dir, and refuses to overwrite unless `ROTATE=1`. `.gitignore` gets `!secrets/*/hetzner-ssh-key.pub`. A separate script, not `ca-init`: the two secrets have different lifetimes and rotation runbooks. `generate-secrets.sh` gains the same generate-if-missing treatment for throwaway projects.
- Make: for hetzner, `persistent-up` runs `run --all --filter '!./vpc'` in `persistent`, then `scripts/persistent-up-hetzner.sh` runs `run --all` in `persistent-hetzner`. `persistent-down` reverses. `bootstrap-up` uses `--filter '!./acm'`. The civo and aws recipes are untouched.
- Guards: every prefix list gains `persistent-hetzner/` and `cluster-hetzner/` unconditionally (the CIVO-025 pattern; empty prefixes count zero). `require-persistent.sh` resolves the unit as `${PERSISTENT_EXTRA_DIR}/network/` instead of the civo literal.
- `lab-role`: add SSM ARNs `*/persistent-hetzner/*` and `*/cluster-hetzner/*`; apply with `make account-up` after diffing the rendered policy (CIVO-025 §14 warning: the policy is one document and reverts anything not on the applied branch).
- Ordering rule: run `PROVIDER=hetzner make ca-init` (HETZ-080) before the first `bootstrap-up`, or `generate-secrets.sh` mints a throwaway CA under the real project name and the Roles Anywhere unit anchors trust to it.

## 4a. Deviations from §4, §5 and §10

- **D1 — the SSH key is read in the unit, not in the module.** §4 says
  `hcloud_ssh_key` takes `file("secrets/${project}/hetzner-ssh-key.pub")`.
  A relative path inside a module resolves against the `.terragrunt-cache`
  copy of that module, where the repository's `secrets/` directory does not
  exist, so the call cannot work. The module takes `public_key` as a plain
  string and the unit reads it with `get_repo_root()`, guarded by
  `fileexists(...) ? file(...) : ""` — the exact shape
  `bootstrap/rolesanywhere` uses for the CA certificate. The guard matters:
  without it `terragrunt validate` fails for any project that has never run
  `ssh-key-init`, which is every throwaway CI project.
- **D2 — `hetzner_stack` keys off `local.raw_class`.** §4 writes
  `path_parts[0]`. `raw_class` is derived from exactly that and is the idiom
  `civo_stack` already uses on the line above. Behaviour is identical.
- **D3 — §10's live no-op plans could not be run.** They ask for
  `terragrunt run --all plan` showing no changes in `terraform/live/persistent`
  for the AWS project and in `persistent-civo` for the Civo project. **Neither
  state bucket exists.** `aws s3api list-buckets` returns only
  `vk-hetzner-lab-tf-state` and the account layer's own bucket; both personal
  projects are torn down to zero. This is the same condition HETZ-018 recorded
  as D6 and HETZ-080 as D2. What was run instead is stronger on the property
  that matters and is recorded in §14: the `make -n` goldens, and a real
  re-render of both `provider.tf` files against `main`'s own `root.hcl`.
- **D4 — the subnet carries no labels.** §4 asks for the §16 label mapping on
  the network unit. The hcloud API exposes no labels on `hcloud_network_subnet`,
  so the four labels stop at the network that owns it. `hcloud_network` and
  `hcloud_ssh_key` both carry all four.
- **D5 — four defects fixed that §4 and §5 do not name.** Three are live bugs
  and one is the §4 error above; all four are described in §14. §5 does not
  list `.github/workflows/lifecycle-test.yml`, which had to change or the two
  new units would never be validated by CI.
- **D6 — `persistent-up` also applied nine AWS resources.** `PERSISTENT_EXCLUDE`
  is `vpc` alone for this target, so the `persistent/secrets` and
  `persistent/backups` units apply too. §1 says so; §8 does not count them.
  They are three SSM parameters and an empty backup bucket with its five
  configuration resources.
- **D7 — the layer was re-applied after the destroy test.** §6 step 6 ends at
  the destroy. The stack was recreated afterwards so HETZ-030 has a network and
  a key to attach to; it is free, and it also proved recreate. The resource IDs
  in §14 are from the second apply.

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

- `bootstrap-up` creates `vk-hetzner-lab-tf-state`, zone `hz.<root-domain>` with the NS delegation, and the Roles Anywhere resources; no ACM certificate.
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

- `hcloud_ssh_key` names are unique per project; a leftover key from HETZ-020 in the same project would collide. **Corrected 2026-09-21:** the spike did *not* use its own project — HETZ-020 deviation D1 records that it ran in the platform's own Hetzner project, which was empty. Every spike resource was named `hz020-*`, and the unfiltered sweep afterwards returned zero SSH keys, so no collision exists. The pre-apply sweep in §14 confirmed zero again.
- The `lab-role` policy revert hazard from CIVO-025 §14 applies unchanged.
- Whether `10.0.0.0/16` collides with anything: pods `10.42.0.0/16` and services `10.43.0.0/16` (k3s defaults, kept) must not overlap `10.0.0.0/16`; confirmed no overlap.

## 13. Definition of done

- [x] Acceptance criteria met with evidence
- [ ] **AWS and Civo no-op plans** — could not be run; see D3 and the
      substitution in §14
- [x] Index updated; status `DONE`
- [ ] **Account limits read from the Console** — carried from HETZ-020 §14,
      an operator action with no API; see §14
- [ ] **Invoice read** — carried from HETZ-020 §14; not published until the
      next billing day; see §14

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-20 — k3s (HETZ-017): the CIDRs checked for overlap are k3s's
  defaults, `10.42.0.0/16` and `10.43.0.0/16`. The network, subnet and SSH key
  design is unaffected.
- 2026-09-21 — executed on branch `hetzner-025-persistent-stack`, off `main`
  at `7832049`. Deviations D1 to D7 in §4a.

  **The apply.** Planned first: `persistent-hetzner/network` 4 to add,
  `persistent-hetzner/ssh-key` 2 to add, `persistent/secrets` 3,
  `persistent/backups` 6 — **15 to add, 0 to change and 0 to destroy**, with
  no `vk-civo-lab` or `vk-lab-platform` string anywhere. Applied at exactly
  those counts.

  | Object | Evidence |
  |---|---|
  | Network | `vk-hetzner-lab`, `10.0.0.0/16`, one `cloud` subnet `10.0.1.0/24` in `eu-central` |
  | SSH key | `vk-hetzner-lab`, MD5 `2a:d7:2f:ad:99:60:75:df:fd:86:cd:41:13:40:13:52` — identical to `ssh-keygen -lf -E md5` on the committed `.pub` |
  | Labels | `project`, `scope=platform`, `lifecycle=persistent`, `managed_by=terraform` on the network and the key; the subnet takes none (D4) |
  | SSM | all three parameters present, plain `String`: `network_id` 12671042, `subnet_ip_range` 10.0.1.0/24, `ssh_key_id` 130285570 |
  | No VPC | `describe-vpcs` filtered on `Project=vk-hetzner-lab` returns 0 |
  | Secrets | `terraform state pull` on both units: 0 occurrences of `PRIVATE`, 0 of the token |

  **The token never reaches the generated file.** Planning with a deliberately
  wrong `HCLOUD_TOKEN` failed with *"entered token is invalid"* from
  `provider "hcloud" {}` at `provider.tf` line 14 — the provider reads the
  environment, exactly as the no-argument block intends.

  **Destroy, then recreate.** A fake `fake_server` object was seeded at
  `cluster-hetzner/servers/terraform.tfstate`; `persistent-down` refused with
  *"Refusing: cluster-hetzner state still has 1 resource(s)"*. With the probe
  removed, the destroy took all 15 resources and the script's own post-destroy
  verification — which now covers both new unit prefixes — reported clean. The
  unfiltered Hetzner sweep then returned **zero across all ten resource
  kinds**, matching the HETZ-020 baseline, and zero SSM parameters under
  `persistent-hetzner`. The stack was then re-applied at the same counts.

  **The four defects.** None is named by §4 or §5. Three predate this work:

  1. `persistent-down.sh` called `civo_token` unconditionally inside the
     `PERSISTENT_EXTRA_DIR` block. Both non-AWS targets set that variable, so a
     Hetzner destroy would have authenticated against the wrong cloud, failed
     on an unauthenticated provider, and left the network and key behind while
     reporting nothing wrong. The clean destroy above is this fix proving
     itself. HETZ-016 did not cover this file.
  2. `require-persistent.sh` branched on `PROVIDER = civo` with an `else` arm
     demanding `eks-access-identity`, so a Hetzner `cluster-up` failed on a
     missing EKS role. The branch now keys off `PERSISTENT_EXTRA_DIR`, which is
     the thing being checked. §4 asked only for the path literal; swapping that
     alone would have left the defect in place.
  3. `lifecycle-test.yml`'s validate list did not cover the new units, so the
     first Hetzner Terraform in the repository would have shipped with no CI
     validation at all.
  4. §4's `file("secrets/...")` inside the module cannot work — D1.

  **Regression evidence, in place of D3's unrunnable plans.** `make -n` was
  captured for **three providers across nine lifecycle targets** and diffed
  against the same capture from `main`'s own Makefile: **byte-identical**. Both
  `provider.tf` files were then re-rendered against `main`'s own `root.hcl` and
  diffed: the AWS render (`persistent/vpc`) and the Civo render
  (`persistent-civo/network`) are **byte-identical**, and neither carries an
  `hcloud` block. The Hetzner render carries `provider "hcloud" {}` and
  `Lifecycle = "persistent"`, which is the new lookup entry working — without
  it the tag would read `persistent-hetzner`. A `generate-secrets.sh` run under
  `PROVIDER=aws` and `PROVIDER=civo` printed *"Skipping the node SSH key"* and
  left both projects' `secrets/` directories unchanged.

  **`make account-up` was deliberately not run.** The `lab-role` SSM additions
  matter only to CI: that role trusts GitHub OIDC alone, the local operator is
  an IAM user writing SSM directly, and no `lifecycle-hetzner` job exists until
  HETZ-140. Applying from an unmerged branch would mutate account-global state
  for no gain, against the CIVO-025 §14 revert hazard. It runs after merge.

  **Cost.** Zero. The network, subnet and SSH key are free, the SSM parameters
  are `String` on the Standard tier, and the backup bucket is empty. No server
  was created.

  **Two acceptance items stay open**, both carried from HETZ-020 §14 and now
  boxes in §13 rather than prose that could evaporate:

  - **Account limits.** No API exposes them; this needs Console → Limits by
    hand. If the default 5-server limit applies, the increase must be filed at
    once — granted only after one month as a customer and a paid first invoice,
    then 1–3 business days. M1 needs 4 lab nodes plus CI's own, which makes
    this the longest lead time in the Hetzner track and the only thing that can
    delay M1 on calendar time rather than on work.
  - **The invoice.** Hetzner does not publish it until the next billing day.
    It should confirm 0 for the network and SSH key, and give the real volume
    and load-balancer rates the cost model still carries unverified.
