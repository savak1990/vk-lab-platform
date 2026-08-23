# 007 — Postgres manual test plan

CLI walkthrough proving the destroy/recreate persistence guarantee (spec
007, Requirement 2) and the storage-growth path (Requirement 7). ~45–60
min, needs `aws`/`kubectl`/`psql`/`terragrunt` CLIs.

## 1. Bring up persistent + disposable stacks

```bash
make persistent-up
make cluster-up
make eks-kubeconfig
```

## 2. Verify Argo is healthy

```bash
kubectl -n argocd get applications
# Expect: root, cnpg-operator all Synced/Healthy
kubectl -n cnpg-system get cluster lab-postgres
# Expect: STATUS "Cluster in healthy state"
kubectl -n cnpg-system get pods
```

## 3. Confirm which snapshot (if any) CNPG recovered from

Since ADR 0013, Postgres storage is no longer Terraform-owned — the volume
is disposable, recreated fresh every cycle. On a first-ever run there's no
snapshot yet, so skip this step the first time through.

```bash
kubectl -n cnpg-system get pvc
kubectl get volumesnapshotcontent lab-postgres-recovered-content \
  -o jsonpath='{.spec.source.snapshotHandle}{"\n"}'
# Compare against AWS's record of the latest tagged snapshot:
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:Project,Values=vk-lab-platform" "Name=tag:Component,Values=postgres" "Name=status,Values=completed" \
  --query 'sort_by(Snapshots,&StartTime)[-1].SnapshotId' --output text
```

These two IDs must match — that's `argo-up.sh`'s discovery step actually
finding the right snapshot, not just any snapshot.

## 4. Get the app-user credentials

```bash
kubectl -n cnpg-system get secret lab-postgres-app -o jsonpath='{.data.password}' | base64 -d
```

## 5. Port-forward and connect

```bash
kubectl -n cnpg-system port-forward svc/lab-postgres-rw 5432:5432 &
psql "host=localhost port=5432 dbname=vkdb user=vkdb sslmode=disable"
# paste the password from step 4 when prompted
```

## 6. Write real test data + check replication prerequisites

```sql
CREATE TABLE proof (id serial primary key, note text, written_at timestamptz default now());
INSERT INTO proof (note) VALUES ('pre-destroy check');
SELECT * FROM proof;

SHOW wal_level;              -- expect: logical
SHOW max_wal_senders;        -- expect: 10
SHOW max_replication_slots;  -- expect: 10
\q
```

Kill the port-forward (`fg` then Ctrl-C, or `kill %1`).

## 7. Tear down — the actual proof point

```bash
make argo-down    # forces the pre-teardown VolumeSnapshot backup (ADR 0013)
make cluster-down
```

## 8. Verify the snapshot survived, and the volume did not (ADR 0013)

```bash
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:Project,Values=vk-lab-platform" "Name=tag:Component,Values=postgres" "Name=status,Values=completed" \
  --query 'Snapshots[].{Id:SnapshotId,StartTime:StartTime}'

aws ec2 describe-volumes --filters "Name=tag:Project,Values=vk-lab-platform" \
  --query 'Volumes[].{Id:VolumeId,State:State,Tags:Tags}'
```

Expect at least one completed snapshot (no more than 2 — older ones get
pruned by `argo-down.sh`), and zero Postgres volumes — the volume is
disposable now, not the snapshot.

## 9. Recreate — no manual values edit anywhere

```bash
make cluster-up
make eks-kubeconfig
kubectl -n argocd get applications
kubectl -n cnpg-system get cluster lab-postgres
```

Wait for `Healthy` again.

## 10. Confirm the data actually came back

```bash
kubectl -n cnpg-system port-forward svc/lab-postgres-rw 5432:5432 &
psql "host=localhost port=5432 dbname=vkdb user=vkdb sslmode=disable" -c "SELECT * FROM proof;"
```

Must show the row from step 6 — this is the acceptance criterion, not
just "cluster is healthy."

## 11. Storage-growth proof (do this last — AWS rate-limits EBS modify to ~1/6h)

```bash
# edit gitops/templates/platform/aws/postgres/cluster.yaml: storage.size 10Gi -> 20Gi
git add -A && git commit -m "test: grow postgres storage 10Gi -> 20Gi" && git push
kubectl -n argocd get application root  # wait for Synced

kubectl -n cnpg-system get pvc -o jsonpath='{.items[0].status.capacity.storage}{"\n"}'
kubectl -n cnpg-system exec -it lab-postgres-1 -- df -h /var/lib/postgresql/data
psql "host=localhost port=5432 dbname=vkdb user=vkdb sslmode=disable" -c "SELECT * FROM proof;"  # no data loss
```

No Terraform check here anymore (ADR 0013) — nothing tracks this volume's
size at all now; `spec.storage.size` on the `Cluster` CR is the only
source of truth, with no second owner to drift against.

## 12. Repeat steps 6–10 at least twice more

Per ADR 0013, run the full write → `argo-down` → `cluster-down` →
`cluster-up` → `argo-up` → read-back cycle a third time (not just a
second) before trusting this with real data — a wrong snapshot-handle
discovery or retention-count bug tends to surface on the third cycle, not
the first or second. Each pass: write a new, distinguishable row and
confirm every prior row is still present, and confirm the snapshot count
never exceeds 2.

## 13. Clean up

```bash
kill %1  # port-forward, if still running
make argo-down
make cluster-down
make persistent-down   # only if you're fully done — deletes all retained
                        # volumes AND all Postgres snapshots for real (ADR 0013)
```
