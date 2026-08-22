# 006-1 — Karpenter node lifecycle manual test plan

Verifies the empirical assumption spec 006-1's no-sweep design depends on:
that deleting Argo CD's `root` Application actually drains and terminates
Karpenter-provisioned nodes (via the `resources-finalizer.argocd.argoproj.io`
finalizer and wave-reversed pruning) before removing Karpenter's own
controller — not just issuing the delete calls in order.

## 0. Preconditions

```bash
make persistent-up   # if not already up
make disposable-up
```

## 1. Bring up Argo CD

```bash
make argo-up
kubectl -n argocd get applications
# Expect: root, karpenter, cnpg-operator, ebs-csi-driver all Synced/Healthy
kubectl -n argocd get application root -o jsonpath='{.metadata.finalizers}{"\n"}'
# Expect: ["resources-finalizer.argocd.argoproj.io"]
```

## 2. Force a Karpenter node to exist

```bash
kubectl get nodes -l karpenter.sh/nodepool
```

If nothing shows, apply a throwaway pod with a resource request the system
node can't satisfy (per spec 006's own test pattern), then wait for it to
schedule.

## 3. The core empirical test — does prune actually block?

Open three terminals.

**Terminal A** — watch the node object disappear:

```bash
kubectl get nodepool -w
```

**Terminal B** — watch when Karpenter's own Application starts going away:

```bash
kubectl get application karpenter -n argocd -w
```

**Terminal C** — watch the real EC2 instance:

```bash
watch -n5 'aws ec2 describe-instances --region eu-west-1 \
  --filters "Name=tag:Project,Values=vk-lab-platform" "Name=tag:ManagedBy,Values=karpenter" \
  --query "Reservations[].Instances[].{Id:InstanceId,State:State.Name}"'
```

**Terminal D** — trigger it:

```bash
kubectl delete application root -n argocd --cascade=foreground --wait --timeout=300s
```

**What confirms the design holds:**

- Terminal A: `NodePool` shows `deletionTimestamp` set, then fully
  disappears (not just marked terminating).
- Terminal C: the EC2 instance transitions `running` → `shutting-down` →
  `terminated` **before** Terminal B shows `karpenter` Application starting
  to disappear.
- Terminal D returns cleanly (no timeout error) once both are done.

**What tells you it's broken:** if `karpenter` Application in Terminal B
starts disappearing while Terminal C still shows the instance `running`.
If that happens, stop — the no-sweep design doesn't hold, and
`argo-down.sh`/spec 006-1 need an explicit wait loop, not this bare cascade
delete.

## 4. Same test, through the actual script

Reset (`make argo-up` again) if needed, then:

```bash
make argo-down
```

Confirm the same ordering, and that it prints `ARGO-DOWN: cascade complete.`

## 5. Confirm zero orphans

```bash
aws ec2 describe-instances --region eu-west-1 \
  --filters "Name=tag:Project,Values=vk-lab-platform" "Name=tag:ManagedBy,Values=karpenter" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name}'
# Expect: empty or all terminated
```

## 6. Guard test — disposable-down without argo-down

Bring Argo back up (`make argo-up`), then try skipping the drain:

```bash
make disposable-down
```

Expect it to refuse immediately with `Argo CD's root Application still
exists - run 'make argo-down' first.` and exit non-zero, **without**
touching Terraform.

## 7. The real teardown

```bash
make argo-down
make disposable-down
```

Expect `terragrunt destroy` to complete with no `DependencyViolation` retry
loop on `aws_security_group.node`.

## 8. Resume test (optional, only if you want to force it)

Hard to simulate deliberately without risk — skip unless you want to
intentionally interrupt a destroy mid-way. If you do: confirm a second
`make disposable-down` run proceeds (doesn't hang on the guard) once the
cluster's already unreachable.

## 9. Idempotency

```bash
make argo-up
make argo-up   # again, back-to-back
kubectl -n argocd get applications   # should be unchanged, no duplicate resources
```
