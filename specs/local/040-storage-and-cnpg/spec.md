---
id: "LOCAL-040"
title: "Platform-owned local-path provisioner, local-retain StorageClass; CNPG Cluster survives down/up"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "One Application, one StorageClass, one template branch; the down/up proof must be run and read carefully"
effort_estimate: "One session (3–5 h) including two down/up cycles"
estimate_confidence: "medium"
depends_on: ["LOCAL-020", "LOCAL-030"]
blocked_by: []
supersedes: ["spec 022 Req 6, Req 14"]
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-040 — Platform-owned local-path provisioner, `local-retain` StorageClass; CNPG Cluster survives `down`/`up`

## 1. Outcome and rationale

The platform installs its own `local-path-provisioner` on local (an Argo
Application, pinned), with a `local-retain` StorageClass whose volumes are
directories under `/var/lib/vk-local-lab/<namespace>/<pvc>` on the node.
Because the directory name is derived from namespace and PVC name and the
class reclaims `Retain`, `make down` → `make up` re-provisions the same
directory and Postgres starts with its previous data. Owning the
provisioner makes this identical on minikube, kind, k3d, and Docker
Desktop, whatever each bundles. There are no backups; the node directory
is the persistence mechanism (constitution §18 as amended by LOCAL-015).
Deleting the cluster deletes the data — that is the developer's action,
not the platform's.

## 2. Scope and non-goals

In scope:
- `gitops/templates/platform/local/storage/application.yaml`:
  `local-path-provisioner` in namespace `local-path-storage`, sync-wave
  `-1` (before CNPG's `Cluster`), gated `eq .Values.target "local"`. Pin
  the upstream manifest/chart version; set `nodePathMap` to
  `/var/lib/vk-local-lab`.
- `gitops/templates/platform/local/storage/storageclass.yaml`:
  `local-retain`, `provisioner: rancher.io/local-path`,
  `reclaimPolicy: Retain`, `volumeBindingMode: WaitForFirstConsumer`,
  `parameters.nodePath: /var/lib/vk-local-lab`,
  `parameters.pathPattern: "{{ .PVC.Namespace }}/{{ .PVC.Name }}"`. Not
  the default class (the cluster keeps its own).
- `shared/postgres/cluster.yaml` local branch: `instances: 1`,
  `storageSize` 2Gi (values), `enablePDB: false` (extend the civo gate to
  `civo|local`), no `nodeSelector`, no `backup`, `initdb` only, modest
  `resources` (requests 256Mi/100m).
- `argo-down` local: after the cascade, delete `Released` PVs of class
  `local-retain` if LOCAL-020 Q1 shows they block re-binding (the
  directory stays; only the PV object goes).
- Render-check: `Application/local-path-provisioner`,
  `StorageClass/local-retain`, `Cluster/lab-postgres` required for local.
- The `down`/`up` proof.

Not in scope:
- Mounting the node path from the repository (optional developer step,
  LOCAL-110).
- Backups, snapshots, WAL archiving.
- Other consumers (observability PVCs use `local-retain` through
  `storage.className` with no change here).

## 3. Current state / evidence

- `shared/postgres/cluster.yaml:1` is `ne target "local"`; `:15-24`
  aws-only nodeSelector; `:30` civo `enablePDB: false`; `:47-52`
  `storageClass` via `platform.storageClassName`; `:53-63` aws-only
  `volumeSnapshot` backup. No `walStorage` on any target.
- `gitops/values.yaml:46` `postgres.storageSize: 20Gi`.
- No provisioner is installed by the platform on any target today (EBS CSI
  on aws is a driver, not a hostPath provisioner).
- LOCAL-020 answers adoption, the node path on minikube, and whether
  `Released` PVs need cleanup.

## 4. Design and contracts

Node directory layout after first `up`:

```
/var/lib/vk-local-lab/
├── cnpg-system/lab-postgres-1/     # PGDATA, uid 26, 0700
└── observability/…                 # after LOCAL-070
```

Adoption path: `make down` deletes the `Cluster`, its PVC, and (with
`Retain`) leaves the PV `Released` and the directory intact. `make up`
creates a new PVC; the provisioner resolves the same path; CNPG's init job
sees `PG_VERSION` and skips `initdb`; the KMS-decrypted password matches
the stored role.

Failure path if the password ciphertext changes between cycles: the
instance starts but the app role's password no longer matches the Secret.
LOCAL-110 documents the reset (`kubectl delete pv` + remove the node
directory, or delete the cluster).

## 5. Files/components affected

`gitops/templates/platform/local/storage/application.yaml` (new);
`gitops/templates/platform/local/storage/storageclass.yaml` (new);
`gitops/templates/platform/shared/postgres/cluster.yaml`;
`gitops/values.yaml` (local `storageSize` via `argo-up` `--set`);
`scripts/argo-down.sh` (optional `Released` PV cleanup);
`scripts/gitops-render-check.sh`.

## 6. Implementation steps

1. Provisioner Application and StorageClass; sync-wave ordering checked
   against the CNPG operator (`-1`) and `Cluster` (`3`).
2. Cluster template gates; `argo-up` passes `postgres.storageSize=2Gi`.
3. Render-check lists.
4. `make gitops-check`; golden diff empty.
5. `PROVIDER=local make up`; wait for `Cluster` `Healthy`; create a table
   and a row through the `-rw` Service (port-forward).
6. `PROVIDER=local make down`; `kubectl get pv` shows the `Released`
   volume (or nothing, if cleanup landed); the node directory is present.
7. `PROVIDER=local make up`; the row is present; the operator log shows
   the adoption message.
8. Record the cycle; leave the cluster running.

## 7. Dependencies and blockers

LOCAL-020, LOCAL-030.

## 8. Acceptance criteria

- `Cluster/lab-postgres` renders for local with `local-retain`, 2Gi,
  `enablePDB: false`, no `backup`, no `nodeSelector`.
- Step 7 finds the row written in step 5.
- `make down` leaves the node directory in place; nothing in the platform
  deletes it.
- AWS golden diff byte-identical; civo render diff empty.

## 9. Validation

Offline: `make gitops-check`. Workstation: steps 5–7 (~20 min).

## 10. AWS regression protection

Golden diff; the aws branches of `cluster.yaml` are untouched; the new
templates are `eq target "local"`.

## 11. Rollout and rollback/recovery

Revert; developer removes `/var/lib/vk-local-lab` on the node if wanted.

## 12. Risks and unresolved questions

- If LOCAL-020 Q1 is "no", replace the adoption path with a pre-created PV
  bound by `claimRef`, or accept throwaway data and re-amend constitution
  §18 (LOCAL-015 §12).
- A second local project (`vk-local-ci` in CI) uses its own node path
  derived from `PROJECT_NAME`; the path is templated, not hard-coded.

## 13. Definition of done

- [ ] Provisioner, StorageClass, Cluster branch landed; render-check updated
- [ ] `down`/`up` proof (steps 5–7) recorded
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `DRAFT` (blocked on LOCAL-020, LOCAL-030).
- 2026-09-11 — replanned: platform-owned provisioner on a node path; no kind mount.
