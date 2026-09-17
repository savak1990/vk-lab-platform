# 007 — Postgres manual test plan

CLI walkthrough proving the destroy/recreate persistence guarantee (spec
007, Requirement 2) and the storage-growth path (Requirement 7). ~45–60
min, needs `aws`/`kubectl`/`psql`/`terragrunt` CLIs.

## 1. Bring up persistent + disposable stacks

```bash
make persistent-up
make cluster-up
make kubeconfig
```

## 2. Verify Argo is healthy

```bash
kubectl -n argocd get applications
# Expect: root, cnpg-operator all Synced/Healthy
kubectl -n cnpg-system get cluster lab-postgres
# Expect: STATUS "Cluster in healthy state"
kubectl -n cnpg-system get pods
```

## 3. Confirm which backup generation (if any) CNPG recovered from

Since ADR 0033, Postgres persists through the CNPG barman-cloud plugin:
WAL and base backups go to `s3://vk-lab-platform-postgres-backups/`, one
prefix per bring-up. On a first-ever run there is no previous generation,
so the Cluster bootstraps with `initdb` and you can skip the comparison.

```bash
# The generation this bring-up recovered from (empty on a first run):
kubectl -n cnpg-system get cluster lab-postgres \
  -o jsonpath='{.spec.externalClusters[0].plugin.parameters.serverName}{"\n"}'
# The generation it now archives into:
kubectl -n cnpg-system get cluster lab-postgres \
  -o jsonpath='{.spec.plugins[0].parameters.serverName}{"\n"}'
aws ssm get-parameter --name /vk-lab-platform/persistent/postgres-backup/server_name \
  --query Parameter.Value --output text
kubectl -n cnpg-system get cluster lab-postgres \
  -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.status}{end}{"\n"}'
```

After `argo-up` finishes, the SSM value must equal the `plugins` serverName,
and `ContinuousArchiving` must be `True`. On a recovery run, the
`externalClusters` serverName must be the value SSM held before this
bring-up.

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
make argo-down    # WAL switch + best-effort plugin base backup (ADR 0033)
make cluster-down
```

## 8. Verify the backup survived, and the volume did not

```bash
G=$(aws ssm get-parameter --name /vk-lab-platform/persistent/postgres-backup/server_name \
  --query Parameter.Value --output text)
aws s3 ls "s3://vk-lab-platform-postgres-backups/$G/base/"
aws s3 ls "s3://vk-lab-platform-postgres-backups/$G/wals/" --recursive | tail -3

aws ec2 describe-volumes --filters "Name=tag:Project,Values=vk-lab-platform" \
  --query 'Volumes[].{Id:VolumeId,State:State,Tags:Tags}'
```

Expect at least one base backup and recent WAL under the generation SSM
names, no more than two generation prefixes in the bucket (older ones are
pruned by `argo-up.sh`), and zero Postgres volumes — the volume is
disposable, the S3 backup is not.

## 9. Recreate — no manual values edit anywhere

```bash
make cluster-up
make kubeconfig
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

No Terraform check here — nothing tracks this volume's
size at all now; `spec.storage.size` on the `Cluster` CR is the only
source of truth, with no second owner to drift against.

## 12. Repeat steps 6–10 at least twice more

Run the full write → `argo-down` → `cluster-down` →
`cluster-up` → `argo-up` → read-back cycle a third time (not just a
second) before trusting this with real data — a recovered cluster that
archives into the wrong generation, or a pruning bug, tends to surface on
the third cycle, not the first or second. Each pass: write a new,
distinguishable row and confirm every prior row is still present, that a
new `.history` file appears in the new generation's `wals/`, and that the
bucket never holds more than two generation prefixes.

## 13. Clean up

```bash
kill %1  # port-forward, if still running
make argo-down
make cluster-down
make persistent-down   # only if you're fully done — empties the backup
                        # bucket and deletes all retained volumes for real
```
