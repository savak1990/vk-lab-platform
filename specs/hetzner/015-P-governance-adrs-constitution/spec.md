---
id: "HETZ-015"
title: "Governance for a third target: ADR 0032, amendments to ADR 0029/0030/0024/0002/0022, per-provider constitution §20, architecture §10a, HLD Hetzner column"
status: "READY"
priority: "P0"
milestone: "M0"
type: "documentation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "A platform-owned control plane bends the Terraform/Argo ownership rule and the token-handling ADR; the reasoning must stay consistent across five documents"
effort_estimate: "One session (3–5 h) of writing and cross-checking"
estimate_confidence: "medium"
depends_on: []
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-015 — Governance and documentation base

## 1. Outcome and rationale

An accepted decision exists for every rule that the Hetzner target bends. The
architecture document, the constitution, and the Civo high-level design all
describe three execution targets. As a result, HETZ-030 (cloud-init installs
k3s), HETZ-045 (`argo-up` helm-installs the CCM), and HETZ-080 (per-project
Roles Anywhere under a per-provider name) do not silently bypass ADR 0029,
ADR 0030, constitution §3/§5/§8/§14/§16/§20, or the ownership rule in
`CLAUDE.md`.

## 2. Scope and non-goals

The scope includes these items:

- ADR 0032 — the next free number at the baseline date. `specs/local/` (a parallel package) also claims 0032; whichever lands first keeps it and this spec takes the next number. Rename the file and every reference in this package before merging;
- amendment notes in ADR 0029, 0030, 0024, 0002, 0022;
- constitution §20 rewritten as a per-provider variant table;
- `docs/architecture.md` §10a fourth column;
- `docs/civo-high-level-design.md` §3, §5, §6 Hetzner entries;
- `CLAUDE.md` repository layout and ADR references;
- `terraform/live/persistent/README.md` line for `persistent-hetzner`.

The scope does not include code, the identity refactor (HETZ-018), or the
cloud-init design (HETZ-030).

## 3. Current state / evidence

- ADR 0027 names Civo as "a second disposable execution target". ADR 0029 §Rationale states that federation is impossible because Civo's OIDC issuer is unreachable. ADR 0030 states that the Civo token never enters the cluster. ADR 0024 declares `LON1` for Civo.
- Constitution §20 is titled "Civo execution target" and lists one variant per section for Civo only.
- `docs/architecture.md` §10a describes three targets (`aws`, `civo`, `local`).
- `docs/civo-high-level-design.md` §3 (stage model), §5 (provider contract), §6 (decision log) have AWS and Civo columns only. `specs/hetzner/README.md` names that document as reading-order item 1, so it must mention Hetzner.
- `CLAUDE.md` "Repository layout" lists `persistent-civo/` and `cluster-civo/` with "See ADR 0027" and no Hetzner entries.
- `CLAUDE.md` "Core ownership model" says Terraform and Argo CD must not manage the same Kubernetes resource, and that Argo CD is bootstrapped by a script, not Terraform.

## 4. Design and contracts

Each ADR has the status Proposed until the PR merges.

- **0032 Hetzner as a third disposable target with a self-bootstrapped k3s control plane.** Hetzner sells no Kubernetes. Terraform creates servers whose cloud-init installs the k3s binary with fixed flags and nothing else; no Kubernetes object is created by Terraform or cloud-init. The control plane is Disposable. Because a node the CCM has not initialised schedules nothing, not even CoreDNS, `argo-up` helm-installs the hcloud CCM before Argo CD; this release joins Argo CD in the existing untracked-bootstrap class (`CLAUDE.md` already exempts the Argo CD install). The CSI driver and every other controller are Argo Applications. The project is `vk-hetzner-lab`, subdomain `hetzner`, stacks `persistent-hetzner`/`cluster-hetzner`, own state bucket, shared account layer. Rejected: `kube-hetzner` (Terraform installs charts), `hetzner-k3s` (no Terraform state), IPv6-only nodes (SSM has no IPv6 endpoint).
- **0030 amendment "Provider API tokens".** Generalise the title from Civo to provider tokens. Hetzner tokens are per project with Read or Read&Write only. The Hetzner token must live in-cluster as `kube-system/hcloud` because the CCM and CSI read it. Mitigation: a dedicated Hetzner project holds nothing but this lab, so a Secret reader gains the lab project and nothing else; `argo-up` creates the Secret untracked; rotation is delete-token, re-encrypt, commit, `argo-up`. The Civo text stays as written.
- **0029 note.** On self-managed k3s the API server accepts `--kube-apiserver-arg=service-account-issuer=<public URL>` and `service-account-jwks-uri`, so IAM OIDC federation is possible on Hetzner. Roles Anywhere is kept because it reuses CIVO-080 to CIVO-110 unchanged and keeps one identity mechanism across non-EKS targets. The note records federation as the alternative and names the cost of switching (six DONE specs).
- **0024 note.** Hetzner location `nbg1`, network zone `eu-central`, declared in `root.hcl` (`hcloud_location`) and `scripts/lib/region.sh` (`HCLOUD_LOCATION`). AWS region unchanged.
- **0002 note.** Zone `hetzner.<root-domain>`, `txtOwnerId=vk-hetzner-lab`.
- **0022 note.** Admin kubeconfig fetched over SSH with a KMS-encrypted key; test identity via ServiceAccount token, as on Civo.

Constitution §20 becomes "Non-EKS execution targets" with one table: rows are
sections §3, §5, §8, §14, §16, §17, §19; columns are Civo and Hetzner. The
Civo column reproduces today's text. The Hetzner column states: §3 servers
and firewall are Disposable, network and SSH key Persistent, Roles Anywhere
Bootstrap; §5 Roles Anywhere, the provider token also in-cluster; §8 hcloud
LB (TCP, no firewall on LBs) → Envoy TLS; §14 zone `hetzner.<root-domain>`,
no ACM; §16 full compliance through hcloud `labels`; §17 same command pairs;
§19 fork steps add the Hetzner project, token, SSH key, and CA ceremony.

§16 on Hetzner: every `hcloud_*` resource carries `labels = { project =
"<project>", scope = "platform", lifecycle = "<class>", managed_by =
"terraform" }`. Hetzner label keys are lowercase with `.`, `-`, `_` allowed
and values up to 63 characters, so the keys are lowercase snake case here,
not the AWS `Project=` capitalised form. This spec decides that mapping;
HETZ-025/030 apply it. Resources the CCM and CSI create carry the labels the
controllers set; HETZ-040's sweep must also match those.

`docs/architecture.md` §10a: add a Hetzner column (control plane: platform
k3s; ingress: hcloud LB + Envoy TLS; storage: `hcloud-volumes`; identity:
Roles Anywhere; capacity: fixed three CAX21).

`docs/civo-high-level-design.md`: §3 stage table gains a Hetzner column; §5
contract gains a "Hetzner source" column copied from
`specs/hetzner/architecture.md` §4; §6 gains dated rows for every decision in
`specs/hetzner/decisions.md` §1 and §3 marked Decided. §1 gets one sentence
stating that Hetzner extends the same model.

`CLAUDE.md`: add `terraform/live/persistent-hetzner/` and
`terraform/live/cluster-hetzner/` to the layout with "See ADR 0032"; extend
the Civo mentions in "Project purpose" and "Secrets and authentication" to
"Civo and Hetzner targets"; add the CCM helm release to the `make argo-up`
sentence.

## 5. Files/components affected

- `docs/adr/0032-hetzner-self-bootstrapped-k3s-target.md` (new).
- `docs/adr/0029-…`, `0030-…`, `0024-…`, `0002-…`, `0022-…` (edit, dated notes).
- `specs/000-constitution/spec.md` §20 (rewrite as a table).
- `docs/architecture.md` §10a (edit).
- `docs/civo-high-level-design.md` §1, §3, §5, §6 (edit).
- `CLAUDE.md`, `terraform/live/persistent/README.md` (edit).
- `specs/hetzner/decisions.md` §2 (status column to Accepted on merge).

## 6. Implementation steps

1. Write ADR 0032 with the blast-radius paragraph and the rejected list.
2. Add the five amendment notes.
3. Rewrite §20 as the two-column table; diff the Civo column against the old prose to prove no Civo rule moved.
4. Edit architecture §10a, the HLD, `CLAUDE.md`, the persistent README.
5. Cross-check every "Civo" sentence in `CLAUDE.md` and the constitution for a missing "and Hetzner".

## 7. Dependencies and blockers

None. HETZ-010 and HETZ-020 run in parallel. HETZ-025 and HETZ-140 wait for this spec.

## 8. Acceptance criteria

- ADR 0032 states who installs the CCM, why Argo cannot, and why cloud-init creating a k3s process does not breach the ownership rule.
- ADR 0030's amendment names the in-cluster Secret, the project-scoping mitigation, and the rotation steps.
- §20's Civo column is semantically identical to the previous §20 text; a reviewer confirms it row by row.
- `docs/civo-high-level-design.md` §3 and §5 have a Hetzner column that matches `specs/hetzner/architecture.md` §2 and §4.
- `grep -n "two targets\|second target" docs/architecture.md docs/adr/*.md` returns only historical ADR text.

## 9. Validation

Documentation only: markdown lint if configured, internal link check, the grep above. Cost: 0.

## 10. AWS regression protection

No code. The AWS and Civo columns are copied, not rewritten. Reviewers diff the old §20 against the Civo column.

## 11. Rollout and rollback/recovery

One PR. A revert removes the documents. Nothing depends on them at run time.

## 12. Risks and unresolved questions

- Label key case on Hetzner is decided here; if HETZ-020 finds a charset restriction that rejects `managed_by`, this spec's table is amended, not the resources.
- Whether ADR 0030 should be superseded by a new ADR rather than amended. Amendment is chosen because the Civo mechanism is unchanged; a reviewer may overrule.
- The HLD is a Civo document by title. Adding a Hetzner column is preferred over a third design document (README decision); revisit if a fourth provider ever appears.

## 13. Definition of done

- [ ] ADR 0032 and the five notes merged
- [ ] §20 table, §10a, HLD, `CLAUDE.md` updated
- [ ] Index updated; `decisions.md` §2 statuses set; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
