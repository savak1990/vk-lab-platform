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
real `disposable-down` / `disposable-up` cycle. The old PV object is now
gone entirely (not just `Released`), so steps 6–9 above are the only rebind
path — this is the exact procedure 007-postgres and 008-kafka must follow
for real data, since a full cluster destroy is the actual EKS-recreation
scenario the constitution's persistence-safety requirement is checking, not
a same-cluster PVC delete/recreate.

## Cleanup

After the proof is documented, delete the retained EBS volume by ID
(`aws ec2 delete-volume --volume-id <volume-id>`). It survives cluster and
PVC deletion by design and will otherwise keep costing money with nothing
left in Kubernetes pointing at it.
