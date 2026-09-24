---
id: "HETZ-015"
title: "Governance for a third target: ADR 0036, amendments to ADR 0029/0030/0024/0002/0022, per-provider constitution §20, architecture §10a, HLD Hetzner column"
status: "DONE"
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
updated: "2026-09-20"
completed: "2026-09-20"
---

# HETZ-015 — Governance and documentation base

## 1. Outcome and rationale

An accepted decision exists for every rule that the Hetzner target bends. The
architecture document, the constitution, and the Civo high-level design all
describe three execution targets. As a result, HETZ-030 (cloud-init
prepares the nodes), HETZ-040 (the cluster scripts), HETZ-045
(`argo-up` helm-installs the CCM), and HETZ-080 (per-project Roles
Anywhere under a per-provider name) do not silently bypass ADR 0029,
ADR 0030, constitution §3/§5/§8/§14/§16/§20, or the ownership rule in
`CLAUDE.md`.

## 2. Scope and non-goals

The scope includes these items:

- ADR 0036 — the next free number. Records 0032 to 0035 all landed between this spec's baseline date and implementation, and `specs/local/` turned out to claim no number at all, so the "0032" this spec was written around is gone. Every reference in this package is renumbered;
- amendment notes in ADR 0029, 0030, 0024, 0002, 0022;
- constitution §20 rewritten as a per-provider variant table;
- `docs/architecture.md` §10a fourth column;
- `docs/civo-high-level-design.md` §3, §5, §6 Hetzner entries;
- `CLAUDE.md` repository layout and ADR references;
- `terraform/live/persistent/README.md` line for `persistent-hetzner`.

The scope does not include code, the identity refactor (HETZ-018), or the
bootstrap script design, since retired.

## 3. Current state / evidence

- **Corrected 2026-09-20.** This bullet originally made four claims about the ADRs; three were wrong, and one of the three changes what an amendment has to argue. ADR 0027's title is "Civo as a second execution target under a separate project" — it does not say "disposable" there; disposability is a separate decision paragraph. ADR 0029 has no `Rationale` section; the federation claim sits in rejected alternative (b), which over-generalises to "non-EKS compute". ADR 0024 never mentions Civo or `LON1` at all; those live in ADR 0027 and ADR 0030. ADR 0030 does **not** say the Civo token stays out of the cluster — it says the Civo autoscaler gets its *own* in-cluster key, separate from the operator's, because an in-cluster credential and an operator credential are different trust boundaries. So the Hetzner amendment extends that separation rather than breaking a rule, provided the in-cluster token is dedicated and not the operator's.
- Constitution §20 is titled "Civo execution target" and lists one variant per section for Civo only.
- `docs/architecture.md` §10a describes three targets (`aws`, `civo`, `local`). **Corrected 2026-09-20:** it has no table. The divergences are seven prose bullets, each naming all three targets inline, so "add a Hetzner column" had no target. This spec converts §10a to a table first.
- `docs/civo-high-level-design.md` §3 (stage model), §5 (provider contract), §6 (decision log) have AWS and Civo columns only. **Corrected 2026-09-20:** the Hetzner README's reading order now names `docs/hetzner-high-level-design.md` as item 1 and the Civo document as item 2, and the Hetzner document already exists. The Civo document still gains the Hetzner columns, because it remains the shared non-EKS design; the reason recorded in §12 is what was stale, not the work itself.
- `CLAUDE.md` "Repository layout" lists `persistent-civo/` and `cluster-civo/` with "See ADR 0027" and no Hetzner entries.
- `CLAUDE.md` "Core ownership model" says Terraform and Argo CD must not manage the same Kubernetes resource, and that Argo CD is bootstrapped by a script, not Terraform.

## 4. Design and contracts

Each ADR is written with the status Accepted. No record in `docs/adr/` has ever
carried `Proposed`, and merging the PR is the acceptance.

- **0036 Hetzner as a third execution target with a kubeadm-bootstrapped control plane.** Hetzner sells no Kubernetes. Terraform creates servers whose cloud-init installs kubeadm, kubelet and containerd with fixed versions, and on the control plane runs `kubeadm init` and the CNI install at first boot. The ADR must argue why Terraform rendering `user_data` that runs `kubeadm init` at first boot does not breach the ownership rule: Terraform creates no Kubernetes object, holds no kubeconfig and configures no Kubernetes or Helm provider — it writes a server's boot script, and the cluster is created by the node's own first boot, which is the node's work and not Terraform's (the Bootstrap driver decision, 2026-09-20). The control plane is Disposable. `argo-up` helm-installs the hcloud CCM before Argo CD; this release joins Argo CD in the existing untracked-bootstrap class (`CLAUDE.md` already exempts the Argo CD install). **Corrected 2026-09-20:** the ordering argument was stated wrongly here. The *kubelet* applies the uninitialized taint at registration and the CCM removes it, and the taint does not stop everything — kube-proxy tolerates every taint and the CCM tolerates this one so it can bootstrap. What it stops is CoreDNS, whose kubeadm-generated tolerations do not cover it. Argo CD needs cluster DNS to reach its own repo server, so the argument runs through DNS, not through "nothing schedules". The CSI driver and every other controller are Argo Applications. The project is `vk-hetzner-lab`, subdomain `hz` (**corrected** from `hetzner`; `hz` is what HETZ-010 shipped), stacks `persistent-hetzner`/`cluster-hetzner`, own state bucket, shared account layer. Rejected: `kube-hetzner` (Terraform installs charts), the standalone Hetzner installer (no Terraform state), IPv6-only nodes (SSM has no IPv6 endpoint), federation instead of Roles Anywhere, k3s instead of kubeadm.
- **0030 amendment "Provider API tokens".** Generalise the title from Civo to provider tokens. Hetzner tokens are per project with Read or Read&Write only, and both the CCM and the CSI driver need Read&Write, so an in-cluster token carries full control of the project. **Corrected 2026-09-20:** the in-cluster token is a *second, dedicated* token, never the operator's. ADR 0030 already separates an in-cluster credential from an operator credential for the Civo autoscaler, and reusing the operator's token would collapse that separation rather than extend it. Its Secret is `kube-system/cloud-operator-secret`, one provider-neutral name across non-EKS targets, not the chart default `kube-system/hcloud`; both Hetzner charts hardcode their default name inside the container environment block, so the shared name means overriding that block in the Helm values. HETZ-045 creates the Secret and HETZ-018 owns provider-parametrized naming, including the Civo rename. Mitigation: a dedicated Hetzner project holds nothing but this lab, so a Secret reader gains the lab project and nothing else; `argo-up` creates the Secret untracked; rotation is delete-token, re-encrypt, commit, `argo-up`. The Civo text stays as written.
- **0029 note.** On a self-managed control plane the API server accepts `service-account-issuer=<public URL>` and `service-account-jwks-uri`, so IAM OIDC federation is possible on Hetzner. Roles Anywhere is kept because it reuses CIVO-080 to CIVO-110 unchanged and keeps one identity mechanism across non-EKS targets. The note records federation as the alternative and names the cost of switching (six DONE specs).
- **0024 note.** Hetzner location `nbg1`, network zone `eu-central`, declared in `root.hcl` (`hcloud_location`) and `scripts/lib/region.sh` (`HCLOUD_LOCATION`). AWS region unchanged. **Corrected 2026-09-20:** neither declaration exists yet — HETZ-025 adds both — so the note is written as a forward declaration, and it anchors on ADR 0024's real property, "no derived declaration", rather than on a Civo/`LON1` sentence that record does not contain.
- **0002 note.** Zone `hz.<root-domain>`, `txtOwnerId=vk-hetzner-lab`. It is also the first provider note on ADR 0002, so it names Civo's zone too and scopes the ACM bullet to AWS.
- **0022 note.** Admin kubeconfig fetched over SSH with a KMS-encrypted key. **Corrected 2026-09-20:** the test-identity half is dropped. ADR 0022 never mentions a test identity, so a note amending one would amend a claim that record does not make. The note is scoped to cluster access.

Constitution §20 becomes "Non-EKS execution targets" with one table: rows are
sections §3, §5, §8, §14, §16, §17, §19; columns are Civo and Hetzner. The
Civo column reproduces today's text. The Hetzner column states: §3 servers
and firewall are Disposable, network and SSH key Persistent, Roles Anywhere
Bootstrap; §5 Roles Anywhere, the provider token also in-cluster; §8 hcloud
LB (TCP, no firewall on LBs) → Envoy TLS; §14 zone `hz.<root-domain>`,
no ACM; §16 full compliance through hcloud `labels`; §17 same command pairs;
§19 fork steps add the Hetzner project, token, SSH key, and CA ceremony.

§16 on Hetzner: every `hcloud_*` resource carries `labels = { project =
"<project>", scope = "platform", lifecycle = "<class>", managed_by =
"terraform" }`.

**Corrected 2026-09-20.** The original justification was factually wrong.
Hetzner label keys are *not* restricted to lowercase: the published character
class is `[a-z0-9A-Z]` with `-`, `_` and `.` between, so the capitalised AWS
`Project=` form would be accepted by the API. Lowercase snake case is still
the mapping this spec decides, because HETZ-010 already shipped it in
`hcloud_list_names`, but the constitution states it as a house convention
rather than as a provider constraint. Stating it as a constraint would be
disproved by any reviewer who tries the capitalised form. The 63-character
value limit and the reserved `hetzner.cloud/` key prefix are real; no
documented cap on the number of labels per resource exists, so none is
claimed. HETZ-025/030 apply the mapping. Resources the CCM and CSI create
carry the labels those controllers set, which are hyphen-cased, not snake
case — the CSI driver labels volumes with `managed-by=csi-driver` — so
HETZ-040's sweep must match both spellings.

`docs/architecture.md` §10a: convert the seven divergence bullets to a table
with one row per divergence and one column per target, then fill the Hetzner
column (control plane: k3s; ingress: hcloud LB + Envoy TLS; storage:
`hcloud-volumes`; identity: Roles Anywhere; capacity: fixed `cx33` nodes).
The conversion comes first because the section has no table today.

`docs/civo-high-level-design.md`: §3 stage table gains a Hetzner column; §5
contract gains a "Hetzner source" column derived from this package's
`architecture.md` §4; §6 gains dated rows for the eight dated decisions in
this package's `decisions.md` §3. §1 gets one sentence stating that Hetzner
extends the same model. **Corrected 2026-09-20:** §5 is keyed by capability
while `architecture.md` §4 is keyed by variable, so the column is a mapping,
not a copy. §6 has no status column, so "marked Decided" is encoded in the
Decision cell rather than by adding one.

`CLAUDE.md`: add `terraform/live/persistent-hetzner/` and
`terraform/live/cluster-hetzner/` to the layout with "See ADR 0036"; extend
the Civo mentions in "Project purpose" and "Secrets and authentication" to
"Civo and Hetzner targets"; add the CCM helm release to the `make argo-up`
sentence. No exception is added to the "never a static AWS credential at rest
in the cluster" rule: a provider token is not an AWS credential, and ADR 0030
already says so.

## 5. Files/components affected

- `docs/adr/0036-hetzner-kubeadm-third-execution-target.md` (new).
- `docs/adr/0029-…`, `0030-…`, `0024-…`, `0002-…`, `0022-…` (edit, dated notes).
- `specs/shared/000-D-constitution/spec.md` §20 (rewrite as a table), §3 and §18 (destale), front matter `updated`.
- `docs/architecture.md` §10a (convert to a table, then edit).
- `docs/civo-high-level-design.md` §1, §3, §5, §6 (edit).
- `CLAUDE.md`, `terraform/live/persistent/README.md` (edit).
- This spec, this package's `architecture.md`, `decisions.md` §2 (add the status column it assumes, then set it) and `README.md` (edit).

## 6. Implementation steps

1. Write ADR 0036 with the blast-radius paragraph and the rejected list.
2. Add the five amendment notes as dated blockquotes between the H1 and `## Status`, the convention ADR 0011 already sets.
3. Rewrite §20 as the per-provider table; diff the Civo column against the old prose to prove no Civo rule moved, keeping the preamble sentence about §3/§4/§7/§17 verbatim so the table does not silently reclassify them.
4. Convert architecture §10a to a table, then edit the HLD, `CLAUDE.md` and the persistent README.
5. Cross-check every "Civo" sentence in `CLAUDE.md` and the constitution for a missing "and Hetzner".
6. Correct this package's own stale statements, listed inline above as corrections.

## 7. Dependencies and blockers

None. HETZ-010 and HETZ-020 run in parallel. HETZ-025 and HETZ-140 wait for this spec.

## 8. Acceptance criteria

- ADR 0036 states who installs the CCM, why Argo cannot, and why a Terraform-rendered `user_data` that runs `kubeadm init` at the node's first boot does not breach the ownership rule. The CCM ordering argument runs through CoreDNS and cluster DNS, and attributes the uninitialized taint to the kubelet, not to the CCM.
- ADR 0030's amendment names the in-cluster Secret, says the token is dedicated and not the operator's, and names the project-scoping mitigation and the rotation steps.
- §20's Civo column is semantically identical to the previous §20 text. **Strengthened 2026-09-20:** this is proven mechanically rather than by eye. The pre-image is captured before any edit and a script extracts each old bullet and each new Civo cell and compares them; the recorded result is byte-identical for all seven.
- `docs/civo-high-level-design.md` §3 and §5 have a Hetzner column consistent with this package's `architecture.md` §2 and §4. It is a mapping, not a copy: §5 is keyed by capability and `architecture.md` §4 by variable.
- The drift grep returns only expected text. **Corrected 2026-09-20:** the original command was defective. It returned a false positive in ADR 0034, where "the only two targets" means Make targets; it returned nothing at all from `docs/architecture.md`, so it could not detect drift in the section it was meant to guard; and it omitted `CLAUDE.md` and `docs/civo-high-level-design.md`, which hold the sentences most in need of change. Use instead:

```
grep -rn "two targets\|second target\|three targets" \
  docs/ CLAUDE.md specs/shared/000-D-constitution/spec.md
```

  Two hits are expected and correct: ADR 0034's Make-target sentence, and the Hetzner high-level design's "the other two targets", which is accurate prose.

## 9. Validation

Documentation only. There is no markdown lint, link checker or docs job in this
repository; a documentation-only PR skips every heavy gate. `make specs-check`
is the one command that can fail on this change, and it also greps the whole
repository for lettered spec paths, so no document may reference a spec by
path — identifiers only, or the reference breaks when this folder renames on
merge. Run `make specs-check` plus the drift grep above. Cost: 0.

## 10. AWS regression protection

No code. The AWS and Civo columns are copied, not rewritten. Reviewers diff the old §20 against the Civo column.

## 11. Rollout and rollback/recovery

One PR. A revert removes the documents. Nothing depends on them at run time.

## 12. Risks and unresolved questions

- ~~Label key case on Hetzner is decided here; if HETZ-020 finds a charset restriction that rejects `managed_by`, this spec's table is amended, not the resources.~~ **Resolved 2026-09-20.** Verified against the Hetzner API reference and the official Go client's validator: keys accept `[a-z0-9A-Z]` with `-`, `_` and `.` between, so `managed_by` is valid and so is the capitalised form. The risk was the wrong way round. Lowercase snake case is a house convention, recorded as one.
- ~~Whether ADR 0030 should be superseded by a new ADR rather than amended.~~ **Resolved 2026-09-20 by the user: amend in place.** The reasoning changed, though. ADR 0030 does not forbid an in-cluster token; it separates an in-cluster credential from an operator credential. The amendment therefore extends that separation with a dedicated token, which is why amendment rather than supersession is right.
- ~~The HLD is a Civo document by title. Adding a Hetzner column is preferred over a third design document.~~ **Stale.** `docs/hetzner-high-level-design.md` already exists and is reading-order item 1. The Civo document still gains the columns because it remains the shared non-EKS design, not because no Hetzner document exists.
- Open: `docs/architecture.md` says the Civo target uses Let's Encrypt DNS-01 while the constitution and the Civo high-level design say HTTP-01. One is wrong about shipped behaviour. Ruled out of scope for this PR by the user; it needs checking against the running code.

## 13. Definition of done

- [x] ADR 0036 and the five notes written
- [x] §20 table, §10a table, HLD, `CLAUDE.md` updated
- [x] Index row in this package's `README.md` updated (`docs/adr/` has no index file); `decisions.md` §2 status column added and set; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — kubeadm wording.
- 2026-09-20 — review fix: the ADR must argue the ownership rule against
  the boot-time `kubeadm init` Terraform renders into `user_data`, not
  against a bootstrap script; §8 matches.
- 2026-09-20 — `IN_PROGRESS`. Exploration before implementation found eight
  factual errors in this spec, corrected inline above and summarised here so
  the record of what changed is not buried.
  1. **ADR number.** `0032` was taken by the Civo barman-cloud record, and
     `0033` to `0035` landed too. `specs/local/` claims no number at all, so
     the race this spec worried about does not exist. The record is `0036`.
  2. **Three of four evidence claims in §3 were wrong** about the records they
     cite: ADR 0027's title, ADR 0029's non-existent `Rationale` section, and
     ADR 0024's non-existent Civo/`LON1` sentence.
  3. **ADR 0030 says the opposite of what §3 claimed.** It does not keep the
     token out of the cluster; it gives the Civo autoscaler its own in-cluster
     key on trust-boundary grounds. This changed the amendment's argument and
     the design: the Hetzner in-cluster token is dedicated, not the operator's,
     and its Secret is `kube-system/cloud-operator-secret`, one name across
     non-EKS targets, decided by the user on 2026-09-20.
  4. **`SUBDOMAIN` is `hz`, not `hetzner`.** HETZ-010 shipped `hz`.
  5. **`docs/architecture.md` §10a has no table**, so "add a Hetzner column"
     had no target. Converted to a table first, per the user's decision.
  6. **`decisions.md` §2 has no status column**, though §5 and §13 assume one.
     Added.
  7. **The Hetzner high-level design already exists**, so §3 and §12 were
     stale about it.
  8. **The label charset claim was false.** Hetzner permits uppercase keys.
     Recorded as a house convention instead, with the CSI driver's hyphen-case
     labels noted for HETZ-040's sweep.

  Two further corrections came from verification rather than from the spec:
  the uninitialized taint is applied by the kubelet and removed by the CCM,
  and it blocks CoreDNS rather than everything, so the ordering argument runs
  through cluster DNS. The acceptance grep in §8 was defective and is replaced.

- 2026-09-20 — **ripple from the Secret rename, recorded rather than
  silently applied.** The dedicated-token decision renames the in-cluster
  Secret from `kube-system/hcloud` to `kube-system/cloud-operator-secret`,
  and adds a second ciphertext file. This PR propagates the new name through
  the design layer only: ADR 0036, the ADR 0030 amendment, constitution §20,
  `docs/architecture.md` §10a, `docs/hetzner-high-level-design.md`, the shared
  non-EKS design, and this package's `architecture.md` and `decisions.md`.

  It does **not** rewrite the implementation specs that still name the old
  Secret — HETZ-020, HETZ-045, HETZ-050 and HETZ-170 — because each
  owns its own contract text and rewriting them here would put this spec's
  scope inside theirs. HETZ-045 creates the Secret and HETZ-018 owns naming
  parametrized by provider, including the Civo rename to the shared name;
  each of those specs updates its own body when it runs. Until then the
  implementation specs and the design documents disagree on the name, which
  is a known and deliberate state, not an oversight.

  The cost is worth stating plainly for a reviewer who wants to reverse the
  decision cheaply: keeping the chart default `kube-system/hcloud` would
  remove the Helm environment-block override and five spec edits, at the
  price of a provider-specific Secret name on every target.

- 2026-09-20 — the malformed Persistent row in the shared non-EKS design's
  stage table is left as found, per the user's decision to keep the PR
  narrow. Its `make` targets cell is missing, so its cells sit one column to
  the left. The Hetzner cell is appended in the correct column and an empty
  cell holds the Civo slot, so the row now matches the header's cell count
  and the pre-existing shift is preserved rather than hidden. It renders with
  a visibly empty Civo cell. Fixing it is one cell and belongs to whoever
  next owns that document.

- 2026-09-20 — **validation run, `IN_REVIEW`.** All three repository checks
  pass on the change:

  ```
  make specs-check     → SPECS-CHECK: specs/ layout is valid.
  make gitops-check    → aws render matches the golden baseline;
                         civo and local renders have the expected M1 object set
  make secrets-check   → secret-scope-test: ok
  ```

  The §20 Civo column is proven unchanged mechanically. A script captured the
  pre-image with `git show HEAD:specs/shared/000-D-constitution/spec.md`
  before any edit, then extracted each old bullet and each new Civo cell and
  compared them: all seven report byte-identical, at 281, 510, 252, 212, 267,
  333 and 282 characters. No reviewer has to compare from memory.

  The corrected drift grep returns only historical record text plus the two
  documented expected hits: ADR 0034's "the only two targets", which means
  Make targets, and the Hetzner high-level design's "the other two targets",
  which is accurate prose. `docs/architecture.md` returns nothing, as it
  should now that §10a names four targets.

  No lifecycle run was performed and none is warranted. This change alters no
  runtime behaviour, and a documentation-only PR skips every heavy gate by
  design.

- 2026-09-20 — **`DONE`, set inside PR #36 rather than after the merge, at
  the user's instruction.** This departs from step 7 of the
  implementation-session protocol, which sets `DONE` once the change is on
  `main`. The departure is recorded here rather than left implicit, because
  the protocol is otherwise followed and a reader comparing this spec against
  it would otherwise see an unexplained gap. The PR's own checks passed
  before the flip: `changes`, `pr-gate`, `validate-repo` and
  `validate-secrets` all green, and the six lifecycle and validation jobs
  skipped as a documentation-only change.

  Direct dependents to re-check after the merge: HETZ-025, HETZ-030 and
  HETZ-140 all name 015 in `depends_on`, and none carries a `blocked_by`
  entry pointing at it, so no dependent needs unblocking. HETZ-016 and
  HETZ-018 remain the next work in M0.
- 2026-09-20 — k3s (HETZ-017, ADR 0037). ADR 0036, which this spec wrote,
  keeps its `Accepted` status and gains a dated note: its bootstrap
  mechanism is replaced, everything else stands. The forward references in
  §1, §4 and the §4 architecture-column description are corrected to the
  k3s design; the amendments this spec made to ADRs 0002, 0022, 0024, 0029
  and 0030 and the constitution §20 table are unaffected in substance.
  Status stays `DONE`.
