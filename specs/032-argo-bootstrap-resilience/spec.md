# 032 — Argo Bootstrap Resilience

**Status:** Proposed

**Complexity:** Small
**Risk:** Medium — changes the `root` Application's sync policy and
`argo-up.sh`'s exit conditions, both on the critical path of every `make up`. No
AWS resource is created or destroyed.
**Estimated cost:** ~0.5 day · AWS runtime cost: none. A cold
`argo-down`/`argo-up` acceptance cycle costs one cluster's worth of the usual
disposable-lifecycle spend.
**Recommended model:** Sonnet for the edits; strong reasoning was used for the
diagnosis (ADR 0025).
**Depends on:** ADR 0025 (the decision this implements), ADR 0012 (Argo CD is
bootstrapped by a script, not Terraform), spec 010 (Envoy Gateway), spec 011
(NLB edge).
**Lifecycle class(es) touched:** Disposable only.

## Scope

Make a cross-Application ordering failure during Argo bootstrap self-healing
rather than terminal, and make a genuinely unrecoverable one visible instead of
silent.

In scope:

1. An explicit `syncPolicy.retry` budget on the `root` Application.
2. Retry-safety and a wider budget for the existing webhook readiness probe.
3. Fail-fast reporting in `scripts/argo-up.sh` when a retry budget is exhausted,
   and a raised watch ceiling to contain the new budget.
4. A Gateway API health check so `root` cannot report Healthy while the gateway
   is unprogrammed.

Out of scope:

- Retry on the thirteen child Applications. Every raced resource observed was
  `root`'s own; the children install self-contained upstream charts.
- A readiness gate per dependency. ADR 0025 rejects this explicitly.
- Tuning `ARGOCD_CLUSTER_CACHE_WATCH_RESYNC_DURATION`. It is undocumented, not
  exposed as a controller flag in v3.5.1, and the retry budget is sized to
  tolerate the default instead.
- The underlying convergence delays themselves — the AWS Load Balancer
  Controller's self-signed cert generation and Argo's discovery cache are
  upstream behaviour this platform accommodates, not fixes.

## Requirements

- `root`'s `syncPolicy` MUST declare a `retry` block whose worst-case duration
  exceeds Argo's cluster API-discovery cache refresh (~10 min) and remains inside
  `ARGO_UP_WATCH_SECONDS`.
- Any Argo hook Job MUST carry `hook-delete-policy: BeforeHookCreation` alongside
  its success policy, so a retried sync can re-run it.
- `argo-up.sh` MUST exit non-zero with Argo's own failure message as soon as a
  sync operation reaches a terminal `Failed`/`Error` phase started by this run,
  rather than waiting out its full watch.
- `argo-up.sh` MUST NOT treat a pre-existing failed operation from an earlier run
  as this run's failure.
- `root` MUST NOT report `Healthy` while `platform-gateway` reports
  `Programmed: False`.

## Testing / acceptance criteria

Manifest rendering and linting prove nothing about a race. They are a
precondition, not the test.

Fast checks:

```sh
helm template root-application gitops/bootstrap --set target=aws | sed -n '/syncPolicy/,$p'
helm template lab gitops --set target=aws --set project=x --set vpcId=x \
  --set envoyGateway.acmCertificateArn=x --set envoyGateway.nlbSubnetIds=x \
  --set envoyGateway.fqdn=x | grep -A2 hook-delete-policy
helm template argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version 10.4.0 -f gitops/argocd/values.yaml | grep -A3 'health.gateway'
shellcheck scripts/argo-up.sh
```

**Acceptance test — a cold cycle with zero manual intervention:**

```sh
make argo-down && make argo-up
```

`make argo-up` MUST reach `Synced/Healthy` on its own. Any `kubectl delete job`,
`kubectl patch application`, or `rollout restart` needed to get there means this
spec has failed. A longer run than before is expected: retries are the mechanism.

Then record, per ADR 0025:

```sh
# The number that says whether the budget holds. Near the limit means marginal.
kubectl get application root -n argocd \
  -o jsonpath='{.status.operationState.phase} retryCount={.status.operationState.retryCount}{"\n"}'
kubectl get gateway -n envoy platform-gateway \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
kubectl get servicemonitor,podmonitor -A
aws elbv2 describe-load-balancers --region eu-west-1 --query 'LoadBalancers[].DNSName'
```

A `retryCount` at or near `limit` is a failing result even if the sync succeeded:
raise the limit and re-run.

Negative test (optional, cheap): with the cluster healthy, confirm
`argo-up.sh`'s fail-fast path does not fire on the pre-existing operation by
re-running `make argo-up` — the idempotency guard should short-circuit before the
watch loop.

The wider net remains `tests/manual/016-lab-up-down.md`, but the cold cycle above
is the test that exercises this change.
