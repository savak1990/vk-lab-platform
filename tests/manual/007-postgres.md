# 007 — Postgres manual test plan

CLI walkthrough proving the destroy/recreate persistence guarantee (spec
007, Requirement 2) and the storage-growth path (Requirement 7). ~45–60
min, needs `aws`/`kubectl`/`psql`/`terragrunt` CLIs.

## 1. Bring up persistent + disposable stacks

```bash
make persistent-up
make disposable-up
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

## 3. Confirm which volume CNPG bound to

```bash
kubectl -n cnpg-system get pvc
kubectl get pv lab-postgres-recovered -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
# Compare against Terraform's record:
terragrunt output -raw volume_id --terragrunt-working-dir terraform/live/persistent/postgres-volume
```

These two IDs must match — that's the automation from ADR 0010 actually
working, not just configured.

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

## 7. Destroy the disposable stack — the actual proof point

```bash
make disposable-down
```

## 8. Verify the volume survived (this is the whole point of ADR 0010)

```bash
aws ec2 describe-volumes --filters "Name=tag:Component,Values=postgres" \
  --query 'Volumes[].{Id:VolumeId,State:State,AZ:AvailabilityZone,Size:Size}'
```

Expect exactly one volume, `State: available`.

## 9. Recreate — no manual values edit anywhere

```bash
make disposable-up
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

terragrunt plan --terragrunt-working-dir terraform/live/persistent/postgres-volume
# Expect: No changes — confirms ignore_changes[size] is doing its job
```

## 12. Clean up

```bash
kill %1  # port-forward, if still running
make disposable-down
make persistent-down   # only if you're fully done — destroys the volume for real
```
