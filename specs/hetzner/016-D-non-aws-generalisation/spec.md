---
id: "HETZ-016"
title: "Non-AWS generalisation: civo-only script branches and Helm gates become non-AWS, with Civo and AWS behaviour unchanged"
status: "DONE"
priority: "P0"
milestone: "M0"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Touches DONE Civo code in two scripts and eleven templates; the semantics of each branch must be classified correctly or Civo regresses silently"
effort_estimate: "One session (4–6 h) including one real Civo up/down"
estimate_confidence: "medium"
depends_on: ["HETZ-010"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-20"
completed: "2026-09-20"
---

# HETZ-016 — Non-AWS generalisation of scripts and GitOps gates

## 1. Outcome and rationale

Every branch that today says "civo" but means "not EKS" says so. After this
spec, a Hetzner branch is needed only where Hetzner really differs (LB
annotations, CCM, CSI, kubeconfig, sweep). The Civo and AWS renders and
`make -n` output do not change by one byte. Without this refactor every
Hetzner spec would duplicate the Civo branches, and the review of CIVO-045
already found that "nearly all civo branches are non-AWS branches".

## 2. Scope and non-goals

In scope: `scripts/argo-up.sh`, `scripts/argo-down.sh`,
`scripts/lib/provider.sh`, `gitops/templates/_helpers.tpl`, the eleven
`eq .Values.target "civo"` sites, `scripts/gitops-render-check.sh`,
`.github/workflows/lifecycle-test.yml` render steps, and the move of
`platform/civo/{cert-manager,identity,tls}` to `platform/shared/`.
Not in scope: identity object names (HETZ-018), any Hetzner-specific value
or file (HETZ-045/050/060), and the `civo` CLI helpers (they stay civo).

## 3. Current state / evidence

Script sites (from the review of CIVO-010 to 060):
`argo-up.sh:131,137,262,279,330,338,427,511`; `argo-down.sh:45,72,149,167,310`;
`provider.sh:62,76` and the `civo_*` functions at `:97-165`;
`generate-secrets.sh:77`; `lib/argo-state.sh:30`. Their semantics:

| Site | Semantics | Class |
|---|---|---|
| `argo-up.sh` `ensure_ca_secret` gate | CA issuer Secret for Roles Anywhere | non-AWS |
| `argo-up.sh` TLS Secret import, `argo-down.sh` export (`provider.sh` `civo_import/export_tls_secret`, SSM `/…/persistent/civo/tls/platform-public`) | Envoy-terminated TLS persistence | non-AWS |
| `argo-up.sh` no EBS snapshot discovery; `argo-down.sh` no snapshot | EBS is AWS-only | non-AWS |
| `argo-down.sh` `TERMINATING_KINDS` filter, PVC wait | already generic, gated on civo | non-AWS |
| `provider.sh` `civo_backup` best-effort teardown backup | barman-cloud plugin, ADR 0032 | non-AWS |
| `argo-up.sh` `civo_resolve_inputs`, `civo_install_root_application`, `civo_wait_for_lb_ip`, `civo_wait_for_dns` | reserved IP, firewall id, `--set` list | civo |
| `provider.sh` `cluster_exists`, `configure_kubeconfig`, `civo_cli` | Civo API | civo |
| `generate-secrets.sh:77` throwaway CA | any non-EKS project | non-AWS |

GitOps: `_helpers.tpl:7-8` allows `aws|civo|local`; `:18-19` maps civo to
`civo-volume`. `eq .Values.target "civo"` appears in `_helpers.tpl`,
`civo/identity/{certificates,issuer}.yaml`, `civo/cert-manager/application.yaml`,
`civo/tls/{issuers,redirect,certificate}.yaml`,
`shared/{external-dns,external-secrets}/application.yaml`,
`shared/envoy-gateway/gateway.yaml:100-118`, `shared/postgres/cluster.yaml:15`.
`gitops-render-check.sh:89-103` has `REQUIRED_OBJECTS_CIVO` and
`FORBIDDEN_KINDS_CIVO` (forbids `StorageClass`). `lifecycle-test.yml:113-114,161-194`
renders `aws` and `civo`.

## 4. Design and contracts

Scripts:

- Every non-AWS site becomes `[ "$PROVIDER" != aws ]`. Civo-class sites keep `= civo`.
- Functions are renamed; the old name is removed, not aliased:

| Old | New |
|---|---|
| `civo_import_tls_secret` / `civo_export_tls_secret` | `import_tls_secret` / `export_tls_secret` |
| `civo_backup` | `teardown_backup` |
| `civo_recovery_handle` | removed with the AWS snapshot path once CIVO-185 lands; until then `recovery_handle` |
| `civo_resolve_inputs`, `civo_install_root_application`, `civo_wait_for_lb_ip`, `civo_wait_for_dns` | unchanged (civo-class) |

- The TLS SSM path becomes `/${PROJECT_NAME}/persistent/${PROVIDER}/tls/platform-public`. For civo it expands to the existing path, so no parameter moves.
- `generate-secrets.sh` mints the throwaway CA for every non-AWS project.

GitOps:

- `_helpers.tpl` gains `platform.selfManaged`: true when `.Values.target` is `civo` or `hetzner`. `validateTarget` allows `aws|civo|hetzner|local`. `platform.storageClassName`: `civo` → `civo-volume`, `hetzner` → `hcloud-volumes`, else `.Values.storage.className`.
- The eleven `eq "civo"` sites become `include "platform.selfManaged" .` where the object is non-AWS (all except the LB annotation block in `gateway.yaml:100-118`, which stays a literal civo branch until HETZ-060 adds a hetzner branch beside it).
- `platform/civo/{cert-manager,identity,tls}` move to `platform/shared/{cert-manager,identity,tls}` with the helper gate. Rationale: on every non-EKS target these three are mandatory and identical; `platform/civo/` then holds nothing, and is removed. A `git mv` keeps history.
- `gitops-render-check.sh`: per-target arrays `REQUIRED_OBJECTS_<TARGET>` and `FORBIDDEN_KINDS_<TARGET>` selected by the target argument. `HETZNER` sets: required `Application/hcloud-csi` (added by HETZ-050, listed here as the contract), forbidden `EC2NodeClass`, `NodePool`, `VolumeSnapshotClass`, every `aws-load-balancer-controller` object, `Application/karpenter`. `StorageClass` is allowed on hetzner because the CSI chart ships one. The civo sets are unchanged.
- `lifecycle-test.yml` renders and checks all three targets.

Regression contract: golden renders for `aws` and `civo` (`helm template` of the root chart with the same `--set` values `argo-up` uses) are byte-identical before and after. The `git mv` changes file paths, not rendered output.

## 4a. Deviations from §3 and §4

The spec was written on 2026-09-11 against a tree that has since moved. Each
deviation below was measured on the branch, not assumed.

- **D1 — two renames dropped.** `civo_backup` and `civo_recovery_handle` no
  longer exist; `backup_teardown` and `backup_recovery_handle` are already
  provider-neutral. Nothing to rename.
- **D2 — fourteen gate sites, not eleven.** `eq .Values.target "civo"` appears
  at fourteen template sites plus four in `_helpers.tpl`. The extra sites are
  `shared/rbac/e2e-test-readonly.yaml`, `shared/postgres/cluster.yaml` (two
  blocks) and `platform.e2eTestSubject`.
- **D3 — a fourth directory moves.** `platform/civo/postgres/aws-config.yaml`
  arrived with CIVO-120/185. It is non-AWS class and moves to
  `platform/shared/postgres/`. `platform/civo/` is then empty and removed.
- **D4 — two helpers stay literal `civo`.** `platform.kubeletInsecureTls` and
  `platform.metricsServerEnabled` carry values measured on a live Civo
  cluster, not derived from the target class. Hetzner falls through to
  `.Values.observability.*`; HETZ-160 measures and sets them.
- **D5 — one `= aws` site is created, against §10.** `install_argocd`'s
  anti-affinity block tested `!= civo` but selects on
  `karpenter.sh/capacity-type`, which exists on aws alone. Left as it was, a
  Hetzner bring-up would give Argo CD a node affinity nothing can satisfy. It
  now tests `= aws`. The aws proof is the `lifecycle-aws` CI job, since no
  offline gate covers script bodies.
- **D6 — two sites split rather than flipped.** `cluster_exists` and
  `argo_state` mix a generic kubeconfig path with `civo_token`. A bare
  `!= aws` would send Hetzner into the Civo API. Both became a `case` with an
  explicit hetzner arm that fails pointing at HETZ-040.
- **D7 — two more files carry the TLS SSM path.** `verify-no-leaks.sh` and
  `force-clean-ci.sh` hardcode it as `KEPT_TLS`. Both take `PROVIDER` as a
  required positional argument and export it, so `${PROVIDER}` is safe there;
  the exact path was kept rather than a glob.
- **D8 — §8's two grep criteria are amended.**
  `grep -rn 'eq .Values.target "civo"' gitops/templates` returns four sites,
  not one: the gateway LB block plus the three helpers of D4 and
  `platform.storageClassName`. `gitops-render-check.sh` takes `check|update`
  as `$1`, never a target, so `gitops-render-check.sh hetzner` is not a
  command; the hetzner object sets are defined and selected by
  `verify_object_set`, and HETZ-050 adds `hetzner` to the render loop.
- **D9 — a rejected simplification.** `verify-no-leaks.sh` defines its own
  `civo_names` beside `provider.sh`'s `civo_list_names`. They differ: the
  local one also reads `.label`, which `civo_network` uses. Merging them would
  change Civo behaviour, so both stay.
- **D10 — four provider `if`/`else` chains became `case`.** In `argo-up.sh`
  (input resolution, both DNS waits, the root Application install) an
  unhandled provider now fails loudly instead of silently taking the AWS arm.
  The rendered `helm` command lines for aws and civo are unchanged.

## 5. Files/components affected

- `scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/provider.sh`, `scripts/generate-secrets.sh`, `scripts/lib/argo-state.sh` (edit).
- `gitops/templates/_helpers.tpl` (edit); the eleven template files (edit); `gitops/templates/platform/civo/**` → `gitops/templates/platform/shared/**` (move).
- `scripts/gitops-render-check.sh`, `.github/workflows/lifecycle-test.yml` (edit).
- `specs/civo/045`, `050`, `065`, `070`, `085`, `100`, `110`, `115` §14: one line each noting the rename (no status change).

## 6. Implementation steps

1. Capture goldens: `make -n` for 16 targets × {unset, aws, civo}; `helm template` for `aws` and `civo`.
2. Classify each script site with the table in §3; change non-AWS sites; rename functions; update every caller.
3. Add the helper; replace the gates; move the three directories; update the render check and the workflow.
4. Diff goldens: all empty.
5. Run `PROVIDER=civo make full-up`, the e2e suite if CIVO-130 has landed, `make full-down`. Confirm the TLS Secret round-trip still finds the existing SSM parameter.

## 7. Dependencies and blockers

HETZ-010 supplies the third `PROVIDER` value that `validateTarget` and the guard accept. HETZ-018 follows this spec. HETZ-050 and HETZ-045 build on the helper.

## 8. Acceptance criteria

- Golden renders for `aws` and `civo` are byte-identical (`diff` exit 0). `make -n` goldens are empty for all three provider values.
- `helm template … --set target=hetzner` fails only on missing hetzner files, never on `validateTarget`.
- `grep -rn 'eq .Values.target "civo"' gitops/templates` returns exactly one site (`gateway.yaml` LB block).
- `grep -n '= civo' scripts/argo-up.sh scripts/argo-down.sh` returns only the civo-class sites listed in §3.
- `gitops-render-check.sh civo` and `… aws` pass unchanged; `… hetzner` runs the hetzner sets and fails on the missing CSI Application (expected until HETZ-050).
- One real Civo `full-up`/`full-down` passes with the TLS Secret reused (no new Let's Encrypt order).

## 9. Validation

Offline: goldens, `shellcheck`, `helm lint`, `gitops-render-check.sh` for three targets, `lifecycle-test.yml` on the branch. Real cloud: one Civo cycle, under 2 USD.

## 10. AWS regression protection

AWS: the golden render and `make -n` diffs; no `= aws` site changes. Civo: the golden render and `make -n` diffs, the real cycle, and `terragrunt run --all plan` in `terraform/live/cluster-civo` (no Terraform changes expected, run to prove it). Both diffs are attached to the PR.

## 11. Rollout and rollback/recovery

One PR (PR 3 in `roadmap.md`, together with HETZ-018). Revert restores the branches; the SSM path for civo is unchanged, so no data moves either way.

## 12. Risks and unresolved questions

- A site classified as non-AWS that is really civo-only would run on Hetzner and fail there, not on Civo; HETZ-045 catches it. The reverse misclassification would break Civo and is caught by the goldens.
- `generate-secrets.sh` minting a CA for a Hetzner project before HETZ-080's ceremony: this is the CIVO-080 §12 trap and is why HETZ-025 §6 runs `ca-init` first.
- `argo-up`'s fast path skips the Helm upgrade on a healthy cluster; the renamed functions must be exercised on a fresh cluster, hence the real cycle.

## 13. Definition of done

- [x] Goldens empty for `aws` and `civo`; attached to the PR
- [x] Real Civo cycle recorded
- [x] Civo spec §14 notes added; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-20 — implementation started on branch `hetzner-016-non-aws-generalisation`; promoted to IN_PROGRESS.
- 2026-09-20 — implemented on branch `hetzner-016-non-aws-generalisation`,
  off `main` at `0520256`. Deviations D1 to D10 in §4a. Offline evidence:

  | Gate | Result |
  |---|---|
  | `helm template` of `gitops/` and `gitops/bootstrap/` for aws and for civo, with the full `--set` list `argo-up` uses, normalized one file per object | `diff -ru` before/after empty (49 aws objects, 45 civo objects) |
  | `make gitops-check` | aws render matches the golden baseline; civo and local object sets unchanged |
  | `make -n`, 25 targets x {unset, aws, civo, hetzner} | `diff -ru` before/after empty |
  | `helm lint gitops/`, `helm lint gitops/bootstrap` | 0 charts failed |
  | `bash -n` on all seven edited scripts | clean |
  | `helm template --set target=hetzner` | renders 39 objects: cert-manager, the identity Certificates, the TLS issuers, `storageClass: hcloud-volumes`; no Karpenter or `ebs-delete` object |
  | `make specs-check` | valid |

  `shellcheck`, `yamllint` and `actionlint` are not installed locally; CI runs
  them. The workflow YAML was parsed with `python3 -c 'yaml.safe_load(...)'`
  as a stand-in.
- 2026-09-20 — live proof routed through CI rather than a local cycle. The
  Civo project was torn down to zero (no state bucket), so a local `full-up`
  would have rebuilt every layer. The pull request carries `ci:lifecycle`,
  which runs both `lifecycle-aws` and `lifecycle-civo` against the CI
  projects; that also covers the aws script path, which no offline gate
  reaches (deviation D5).
- 2026-09-20 — merged as pull request #39, `223da37`. Both lifecycle jobs
  passed against the CI projects, which is the "real Civo cycle" §13 asks
  for — the local cycle was impossible with the Civo project at zero.
  Closed `DONE`.
