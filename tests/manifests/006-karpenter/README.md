# Karpenter bound-scaling proof

Plain `kubectl` manifests, not Argo-managed, re-runnable on demand.

Prerequisite: the `karpenter` Argo Application is `Healthy`, and the
`default` EC2NodeClass/NodePool exist
(`gitops/templates/platform/aws/karpenter/`).

## Scale-up / consolidation proof

1. `kubectl apply -f 01-scale-up-deployment.yaml`
2. Confirm a new spot node joins, within the allowed instance types:
   `kubectl get nodes -l karpenter.sh/nodepool=default -o wide`
3. Confirm the pod scheduled onto it:
   `kubectl get pod -l app=karpenter-scale-test -o wide`
4. Confirm the built-in labels the pod can be scheduled against:
   `kubectl get node <node-name> --show-labels | tr ',' '\n' | grep karpenter`
   — expect `karpenter.sh/capacity-type=spot` and `karpenter.sh/nodepool=default`.
5. `kubectl delete -f 01-scale-up-deployment.yaml`
6. Confirm the node is consolidated away within a couple of minutes
   (`consolidateAfter: 1m`, policy `WhenEmpty`):
   `kubectl get nodes -l karpenter.sh/nodepool=default`

## Bound-enforcement proof

1. `kubectl apply -f 01-scale-up-deployment.yaml`
2. `kubectl scale deployment/karpenter-scale-test --replicas=3`
   — each pod requests 1.5 vCPU, so three pods need three 2-vCPU nodes
   (6 vCPU), above the NodePool's `limits.cpu: "4"` (~2 nodes).
3. Confirm exactly 2 nodes exist and the third pod stays `Pending`
   (`kubectl get nodes -l karpenter.sh/nodepool=default` /
   `kubectl get pods -l app=karpenter-scale-test`) — the cap is enforced,
   not just configured.
4. `kubectl delete -f 01-scale-up-deployment.yaml` to scale back to zero
   and let consolidation remove the nodes.

## Teardown-with-nodes-running proof

1. `kubectl apply -f 01-scale-up-deployment.yaml` and wait for the spot
   node to join.
2. Run the disposable teardown (`make disposable-down` or equivalent)
   while the node is still up.
3. In AWS (not `kubectl`, the cluster is gone), confirm zero leftover EC2
   instances: `aws ec2 describe-instances --filters "Name=tag:karpenter.sh/nodepool,Values=default" "Name=instance-state-name,Values=running,pending"`.
   Karpenter nodes are standalone `CreateFleet` instances, not EKS-managed
   node group members, so they are not guaranteed to be cleaned up by EKS
   cluster deletion alone.
