# Storage contract proof

Plain `kubectl` manifests, not Argo-managed, so this proof can be re-run on
demand (e.g. after a driver chart bump, or before 007-postgres/008-kafka
build on the same contract) without Argo tracking or pruning throwaway test
resources.

Prerequisite: the `ebs-csi-driver` Argo Application is `Healthy` and the
`ebs-retain` StorageClass exists (`gitops/templates/platform/aws/ebs-csi/`).

## Same-cluster proof

1. `kubectl apply -f 01-pvc.yaml -f 02-statefulset.yaml`
2. Confirm the pod is `Running` and wrote the marker file:
   `kubectl exec storage-contract-test-0 -- cat /data/marker.txt`
3. Note the bound volume's AWS EBS volume ID and AZ:
   `kubectl get pv -o jsonpath='{range .items[?(@.spec.claimRef.name=="storage-contract-test")]}{.spec.csi.volumeHandle}{"\n"}{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}{end}'`
4. `kubectl delete -f 02-statefulset.yaml -f 01-pvc.yaml`
5. Confirm in AWS, not kubectl, that the volume still exists:
   `aws ec2 describe-volumes --volume-ids <volume-id>`
   The old PV object (if still present) now shows `Released` with a stale
   `claimRef` — it will not rebind as-is, even within the same cluster.
6. Edit `03-rebind-pv.yaml`, replacing `REPLACE_WITH_VOLUME_ID` and
   `REPLACE_WITH_AVAILABILITY_ZONE` with the values from step 3.
7. `kubectl apply -f 03-rebind-pv.yaml -f 04-rebind-pvc.yaml -f 05-statefulset-rebind.yaml`
8. Confirm the marker file reads back through the new pod:
   `kubectl exec storage-contract-test-rebind-0 -- cat /data/marker.txt`
9. `kubectl delete -f 05-statefulset-rebind.yaml -f 04-rebind-pvc.yaml -f 03-rebind-pv.yaml`

## Full destroy/recreate proof

Repeat steps 1–3 of the same-cluster proof, then instead of step 4, run a
real `cluster-down` / `cluster-up` cycle. The old PV object is now
gone entirely (not just `Released`), so steps 6–9 above are the only rebind
path — a full cluster destroy is the actual EKS-recreation scenario the
constitution's persistence-safety requirement is checking, not a
same-cluster PVC delete/recreate.

Postgres no longer follows this procedure: spec 007-1/ADR 0013 found that
CNPG doesn't adopt existing PGDATA on a rebound PV (it quarantines it and
runs `initdb` fresh), and replaced it with CNPG's native VolumeSnapshot
recovery instead. This rebind procedure remains the model for 008-kafka
(not yet implemented, still planned per its spec as of this writing) —
revisit whether that's still the right choice for Kafka/Strimzi when that
spec is implemented, rather than assuming it transfers unchanged.

## Cleanup

After the proof is documented, delete the retained volume with
`make persistent-down` (see ADR 0008) — it survives cluster and PVC
deletion by design and will otherwise keep costing money with nothing
left in Kubernetes pointing at it. Note that target now also destroys
DNS/ACM/Secrets Manager; it lists every retained volume it's about to
delete before the destroy proceeds. For a
one-off volume outside that flow, `aws ec2 delete-volume --volume-id
<volume-id>` still works directly.
