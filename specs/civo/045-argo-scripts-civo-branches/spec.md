---
id: "CIVO-045"
title: "argo-up and argo-down Civo branches"
status: "READY"
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
with `target=civo`. The script then waits for health. `argo-down` removes
the installation with the same explicit DNS and LB gates. On Civo, the
scripts skip the AWS-only blocks. The scripts do not fail on these blocks.

## 2. Scope and non-goals

In scope: the provider seams in `scripts/argo-up.sh` and `scripts/argo-down.sh`.
Not in scope:

- the CA Secret step (CIVO-085 adds it here);
- the TLS Secret re-import (CIVO-070 adds it here);
- the Civo snapshot logic (CIVO-120 adds it here).

## 3. Current state / evidence

`argo-up.sh` has these blocks:

- `eks_output` at `:34-36`;
- the SSM batch at `:41-54` (five names, which include the ACM ARN, the VPC id, and the subnet id);
- the kubeconfig at `:75-78`;
- the DNS wait at `:86-140` (it reads the `envoy` Service hostname and then runs `dig`);
- the fast path at `:151-158`;
- the snapshot block at `:167-197`;
- the Argo install with the spot anti-affinity at `:221-222`;
- the root install at `:228-244` with `--set target=aws` and the AWS-only values.

`argo-down.sh` has these blocks:

- the existence proof at `:30-33`;
- the CNPG backup and the EBS prune at `:54-113`;
- the Route 53 wait at `:169-201`;
- the LB wait at `:206-230`;
- the cascade at `:232-246`;
- `TERMINATING_KINDS` at `:122-127`, which includes the Karpenter kinds.

## 4. Design and contracts

- Source `scripts/lib/provider.sh`. Use `configure_kubeconfig` and `cluster_exists`.
- The inputs on civo are the SSM parameters `fqdn`, `argocd/admin_password_bcrypt`, `persistent-civo/reserved-ip/address`, and `cluster-civo/network/firewall_id`. There is no ACM, VPC, or subnet input. `cluster_name` = `$PROJECT_NAME`.
- The DNS wait on civo compares the `dig` result for `argo.$FQDN` with the Service `status.loadBalancer.ingress[0].ip` (or with the reserved IP).
- The snapshot block on civo calls `civo_recovery_handle()`. CIVO-120 implements this function. Until then, the function returns an empty value and logs "no recovery configured".
- The Argo install on civo omits the spot anti-affinity. All other parts are identical.
- The root install sets `--set target=civo`, the project, the repo, the revision, `postgres.storageSize`, `postgres.recoverySnapshotHandle`, `envoyGateway.fqdn`, `envoyGateway.reservedIp`, `envoyGateway.firewallId`, and `externalDns.txtOwnerId=${PROJECT_NAME}`.
- `argo-down.sh` on civo does the existence proof with `cluster_exists`. The CNPG backup step calls `civo_backup()` (CIVO-120). Until CIVO-120 lands, the step fails closed with a clear message if a CNPG cluster exists. The step does not skip. The Route 53 wait is unchanged (the AWS credentials are present). The LB wait is unchanged. The script filters `TERMINATING_KINDS` to the kinds that are present (`kubectl api-resources`).
- All added lines are `if [ "$PROVIDER" = civo ]` branches. The aws path stays literally the same.

**Review amendments (2026-09-06, kubernetes-architect):**
- The Civo branch of the Service address check reads `status.loadBalancer.ingress[0].ip`, not `.hostname` (hostname appears only with proxy protocol).
- The `argo-down` Civo backup step calls `civo_backup()` from CIVO-120: an on-demand CNPG `Backup` with `method: plugin` to the object store, waited to `completed`. No snapshot logic on Civo.
- The LoadBalancer Service wait stays as is: the Civo CCM uses the standard `service.kubernetes.io/load-balancer-cleanup` finalizer, and the CCM runs in `kube-system` outside the Argo cascade.

## 5. Files/components affected

`scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/provider.sh`.

## 6. Implementation steps

1. Extract the AWS-only blocks into functions. Do not change the behavior. Verify the result with a recorded AWS `argo-up` fast-path run.
2. Add the civo branches per §4.
3. Run `PROVIDER=civo make up` with the CIVO-050 baseline (Envoy without TLS, and no ESO consumers yet). The root Application must reach `Synced/Healthy`.
4. Run `PROVIDER=civo make argo-down`. Confirm that the LB gate and the DNS gate behave correctly. No records yet is acceptable. The gate must terminate.

## 7. Dependencies and blockers

CIVO-040 (the kubeconfig and the existence proof). CIVO-050 (`target: civo` renders something).

## 8. Acceptance criteria

- `PROVIDER=civo make argo-up` is idempotent. The second run hits the fast path.
- The root Application is `Synced/Healthy` on civo with the baseline set.
- `argo-down` on civo removes the LoadBalancer Service and the Civo LB before the cascade. Check the Civo LB with `civo loadbalancer ls`.
- The AWS `make argo-up` fast path and full path produce the same Helm command lines as before. Record the lines with a `set -x` diff and redact the secrets.
- The scripts print no token value and no bcrypt value.

## 9. Validation

Offline: `shellcheck` and `bash -n`. Real cloud: one civo up/down (~0.15 USD). AWS: a fast-path run only.

## 10. AWS regression protection

The function extraction preserves the behavior. The gate before merge is a recorded AWS `argo-up` fast path and one full AWS `argo-down` after this change.

## 11. Rollout and rollback/recovery

Revert the scripts. The fail-closed rule on the civo CNPG teardown prevents silent data loss before CIVO-120.

## 12. Risks and unresolved questions

- The Civo Service status may present a hostname instead of an IP with the proxy protocol (off in M1).

## 13. Definition of done

- [ ] Evidence for both providers
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
