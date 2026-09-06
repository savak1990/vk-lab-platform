---
id: "CIVO-045"
title: "argo-up and argo-down Civo branches"
status: "DRAFT"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Well-mapped seams in two scripts; the ordering logic already exists and is reused"
effort_estimate: "One session (4–6 h) plus a real up/down"
estimate_confidence: "medium"
depends_on: ["CIVO-040", "CIVO-050"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-06"
completed: null
---

# CIVO-045 — Argo scripts on Civo

## 1. Outcome and rationale

`PROVIDER=civo make argo-up` installs Argo CD and the root Application
with `target=civo` and waits for health; `argo-down` tears down with the
same explicit DNS and LB gates. AWS-only blocks are skipped on Civo rather
than failing.

## 2. Scope and non-goals

In scope: the provider seams in `scripts/argo-up.sh` and `scripts/argo-down.sh`.
Not in scope: the CA Secret step (CIVO-085 adds it here), TLS Secret
re-import (CIVO-070 adds it here), Civo snapshot logic (CIVO-120 adds it here).

## 3. Current state / evidence

`argo-up.sh`: `eks_output` `:34-36`; SSM batch `:41-54` (five names incl. ACM
ARN, VPC id, subnet id); kubeconfig `:75-78`; DNS wait `:86-140` (uses
`envoy` Service hostname → `dig`); fast path `:151-158`; snapshot block
`:167-197`; Argo install with spot anti-affinity `:221-222`; root install
`:228-244` with `--set target=aws` and AWS-only values.
`argo-down.sh`: existence proof `:30-33`; CNPG backup + EBS prune `:54-113`;
Route 53 wait `:169-201`; LB wait `:206-230`; cascade `:232-246`;
`TERMINATING_KINDS` `:122-127` includes Karpenter kinds.

## 4. Design and contracts

- Source `scripts/lib/provider.sh`; use `configure_kubeconfig`, `cluster_exists`.
- Inputs on civo: SSM `fqdn`, `argocd/admin_password_bcrypt`, `persistent-civo/reserved-ip/address`, `cluster-civo/network/firewall_id`; no ACM/VPC/subnet. `cluster_name` = `$PROJECT_NAME`.
- DNS wait on civo: compare `dig` of `argo.$FQDN` with the Service `status.loadBalancer.ingress[0].ip` (or the reserved IP).
- Snapshot block: on civo, call `civo_recovery_handle()` (implemented in CIVO-120; until then returns empty and logs "no recovery configured").
- Argo install: omit the spot anti-affinity on civo; everything else identical.
- Root install: `--set target=civo`, project, repo, revision, `postgres.storageSize`, `postgres.recoverySnapshotHandle`, `envoyGateway.fqdn`, `envoyGateway.reservedIp`, `envoyGateway.firewallId`, `externalDns.txtOwnerId=${PROJECT_NAME}`.
- `argo-down.sh` on civo: existence proof via `cluster_exists`; CNPG backup step calls `civo_backup()` (CIVO-120; until then, if a CNPG cluster exists, fail closed with a clear message rather than skip); Route 53 wait unchanged (AWS creds present); LB wait unchanged; `TERMINATING_KINDS` filtered to kinds present (`kubectl api-resources`).
- All added lines are `if [ "$PROVIDER" = civo ]` branches; aws path stays literally the same.

## 5. Files/components affected

`scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/provider.sh`.

## 6. Implementation steps

1. Extract the AWS-only blocks into functions without changing behavior; verify with a recorded AWS `argo-up` fast-path run.
2. Add civo branches per §4.
3. Run `PROVIDER=civo make up` with the CIVO-050 baseline (Envoy without TLS, no ESO consumers yet): root Application must reach `Synced/Healthy`.
4. Run `PROVIDER=civo make argo-down`; confirm LB and DNS gates behave (no records yet is acceptable; gate must terminate).

## 7. Dependencies and blockers

CIVO-040 (kubeconfig, existence proof), CIVO-050 (`target: civo` renders something).

## 8. Acceptance criteria

- `PROVIDER=civo make argo-up` idempotent: second run hits the fast path.
- Root Application `Synced/Healthy` on civo with the baseline set.
- `argo-down` on civo removes the LoadBalancer Service and the Civo LB (checked with `civo loadbalancer ls`) before the cascade.
- AWS `make argo-up` fast path and full path produce the same Helm command lines as before (recorded via `set -x` diff with secrets redacted).
- No token or bcrypt value printed.

## 9. Validation

Offline: `shellcheck`, `bash -n`. Real cloud: one civo up/down (~0.15 USD); AWS: fast-path run only.

## 10. AWS regression protection

Function extraction is behavior-preserving; a recorded AWS `argo-up` fast path and one full AWS `argo-down` after this change is the gate before merge.

## 11. Rollout and rollback/recovery

Revert scripts. Fail-closed rule on civo CNPG teardown prevents silent data loss before CIVO-120.

## 12. Risks and unresolved questions

- Civo Service status may present hostname instead of IP with proxy protocol (off in M1).

## 13. Definition of done

- [ ] Evidence for both providers
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
