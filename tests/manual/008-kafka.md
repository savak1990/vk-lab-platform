# 008 — Kafka manual test plan

CLI walkthrough proving the destroy/recreate persistence guarantee (spec
008, Requirement 1) and the deletion-ordering guarantee (Requirement 2).
~45–60 min, needs `aws`/`kubectl`/`terragrunt` CLIs. **Run Task B0 (a
throwaway-volume verification, see `docs/adr/0015-kafka-terraform-owned-volumes.md`
and `specs/008-kafka/spec.md`) before trusting this against real data** —
the PVC naming pattern (`data-lab-kafka-broker-<i>`) baked into
`gitops/templates/platform/aws/kafka/volumes.yaml` is Strimzi's documented
convention, not yet confirmed against a live cluster in this repo.

## 1. Bring up persistent + disposable stacks

```bash
make persistent-up
make cluster-up
make eks-kubeconfig
make argo-up
```

## 2. Verify Argo, Strimzi, and Kafka are healthy

```bash
kubectl -n argocd get applications
# Expect: root, strimzi-operator all Synced/Healthy
kubectl -n kafka get kafka lab-kafka
# Expect: STATUS "Ready"
kubectl -n kafka get kafkanodepool broker
kubectl -n kafka get pods
```

## 3. Confirm the bound volume matches Terraform's record

```bash
kubectl -n kafka get pvc data-lab-kafka-broker-0 \
  -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl get pv lab-kafka-broker-0 \
  -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'

cd terraform/live/persistent/kafka-volumes
terragrunt output -json volume_ids
cd -
```

The volume ID from the PV must match the first entry in Terraform's
`volume_ids` output — this is `argo-up.sh`'s discovery step actually
wiring the right volume, not a coincidence.

## 4. Confirm the cluster ID was pinned

```bash
kubectl -n kafka get job kafka-cluster-id-patch
kubectl -n kafka get kafka lab-kafka -o jsonpath='{.status.clusterId}{"\n"}'
cat secrets/vk-lab-platform/kafka-cluster-id.txt
```

The two IDs must match.

## 5. Write real test data

```bash
kubectl -n kafka run kafka-client --rm -it --restart=Never \
  --image=quay.io/strimzi/kafka:latest-kafka-4.3.1 -- bash

# inside the pod:
bin/kafka-topics.sh --bootstrap-server lab-kafka-kafka-bootstrap:9092 \
  --create --topic proof --partitions 1 --replication-factor 1
echo -e "pre-destroy-1\npre-destroy-2" | \
  bin/kafka-console-producer.sh --bootstrap-server lab-kafka-kafka-bootstrap:9092 --topic proof
bin/kafka-console-consumer.sh --bootstrap-server lab-kafka-kafka-bootstrap:9092 \
  --topic proof --from-beginning --max-messages 2
exit
```

## 6. Deletion-ordering check (spec 008 Requirement 2)

```bash
kubectl delete kafka lab-kafka -n kafka
kubectl -n kafka get pods -w   # broker/controller pods should terminate cleanly
kubectl -n argocd get application strimzi-operator   # must stay Healthy throughout
```

Re-sync afterward (`kubectl -n argocd get application root` should show
`OutOfSync` then self-heal `lab-kafka` back) before continuing — this step
is a point-in-time check, not a teardown.

## 7. Tear down — the actual proof point

```bash
make argo-down
make cluster-down
```

No Kafka-specific behavior runs in `argo-down.sh` — this is the whole
point of the rebind mechanism (ADR 0015): `Retain` reclaim persists the
volume automatically through the normal cascade delete.

## 8. Verify the volume survived

```bash
aws ec2 describe-volumes --filters "Name=tag:Component,Values=kafka" \
  --query 'Volumes[].{Id:VolumeId,State:State}'
```

Expect exactly one volume, `available` — not deleted, not still attached.

## 9. Recreate — no manual values edit anywhere

```bash
make cluster-up
make eks-kubeconfig
make argo-up
kubectl -n argocd get applications
kubectl -n kafka get kafka lab-kafka
```

Wait for `Ready` again.

## 10. Confirm the data actually came back

```bash
kubectl -n kafka logs -l strimzi.io/pool-name=broker | grep -i "InconsistentClusterId"
# Expect: no output

kubectl -n kafka run kafka-client --rm -it --restart=Never \
  --image=quay.io/strimzi/kafka:latest-kafka-4.3.1 -- \
  bin/kafka-console-consumer.sh --bootstrap-server lab-kafka-kafka-bootstrap:9092 \
  --topic proof --from-beginning --max-messages 2
```

Must show both messages from step 5 — this is the acceptance criterion,
not just "cluster is Ready" (a broker can report `Ready` against an empty
`__cluster_metadata` log and show zero topics; this step is what actually
rules that out).

## 11. Repeat steps 5–10 a second time

Write a new, distinguishable message and confirm every prior message is
still present after a second full `argo-down` → `cluster-down` →
`cluster-up` → `argo-up` cycle (spec 014 idempotency).

## 12. Clean up

```bash
make argo-down
make cluster-down
make persistent-down   # only if you're fully done — deletes the retained
                        # Kafka volume(s) for real (Terraform-tracked,
                        # terraform/live/persistent/kafka-volumes, ADR 0015)
```
