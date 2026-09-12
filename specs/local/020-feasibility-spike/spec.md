---
id: "LOCAL-020"
title: "Throwaway spike: CNPG data adoption on local-path, minikube node path, port-forward authority"
status: "READY"
priority: "P0"
milestone: "M0"
type: "spike"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Empirical questions with yes/no answers; needs a real laptop, not reasoning"
effort_estimate: "One session (2–3 h)"
estimate_confidence: "medium"
depends_on: ["LOCAL-010"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---

# LOCAL-020 — Throwaway spike: CNPG data adoption on local-path, minikube node path, port-forward authority

## 1. Outcome and rationale

Three facts that LOCAL-040 and LOCAL-050 depend on are answered on the
user's minikube and written into `research.md`. Nothing built during the
spike is kept. Each question has a fallback already named, so the spike
chooses between known designs rather than inventing one.

## 2. Scope and non-goals

In scope — answer with evidence (commands and output, no secrets):

1. **CNPG adoption.** Install `local-path-provisioner` by hand (pinned
   manifest) with a `local-retain` StorageClass
   (`nodePath: /var/lib/vk-local-lab`, `pathPattern: "{{ .PVC.Namespace }}/{{ .PVC.Name }}"`,
   `reclaimPolicy: Retain`). Create a CNPG `Cluster` (1 instance, 1Gi,
   `initdb`, the real KMS-decrypted password), write a table, delete the
   `Cluster` (PVC goes with it), re-apply the same `Cluster`. Does the
   instance start with the table present and the operator log "PGData
   already exists" instead of running `initdb`? Does `psql` with the same
   password work? Is a stale `Released` PV left behind that must be
   cleaned, and does the provisioner still reuse the directory?
2. **Node path on minikube.** Where does `/var/lib/vk-local-lab` live on
   the minikube node for the user's driver (docker/qemu/vfkit), does it
   survive `minikube stop`/`start`, and does `minikube mount
   <repo>/.local/vk-local-lab:/var/lib/vk-local-lab` work as an optional
   way to put it in the repository? Record uid/mode behaviour for PGDATA
   under the mount.
3. **Port-forward authority.** With Envoy's Service as `ClusterIP`,
   `kubectl -n envoy-gateway-system port-forward svc/<envoy> 8080:80`, a
   Gateway HTTP listener on 80, and an HTTPRoute with hostname
   `argo.localhost`: does `curl --resolve argo.localhost:8080:127.0.0.1
   http://argo.localhost:8080/` route (port must be stripped from
   `:authority` before hostname match on Envoy Gateway v1.2.1)? Does
   `curl -H 'Host: argo.localhost' http://127.0.0.1:8080/` also work?

Not in scope: any change under `gitops/` or `scripts/`; kind (the CI
runner's behaviour is covered by LOCAL-090's first run).

## 3. Current state / evidence

- `research.md` records what reading shows: `pathPattern` exists in
  local-path-provisioner ≥ v0.0.24; CNPG's init job checks `PG_VERSION`
  and skips `initdb` when PGDATA is populated; Gateway API hostname
  matching ignores the port. None of it has been observed here.
- minikube's bundled `storage-provisioner` uses
  `/tmp/hostpath-provisioner/<ns>/<pvc>` — deterministic but under `/tmp`
  and a different provisioner than kind's; installing our own removes the
  difference.

## 4. Design and contracts

Report format (appended to `research.md` under "Spike results (LOCAL-020)"):
one table with question, observed result, evidence line, decision taken.

| Q | Yes → | No → |
|---|---|---|
| 1 | LOCAL-040 keeps `initdb` and Retain; `argo-down` adds a `Released`-PV cleanup if needed | LOCAL-040 pre-creates the PV/PVC pair by name, or drops persistence and LOCAL-015 re-amends §18 |
| 2 | `/var/lib/vk-local-lab` is the documented node path; repo mount is an optional LOCAL-110 one-liner | pick a path that survives on the user's driver; document per driver |
| 3 | LOCAL-050 and LOCAL-080 as designed | e2e sends `Host: argo.localhost` without the port; developers use `--resolve` |

## 5. Files/components affected

`specs/local/research.md` (results section). Nothing else.

## 6. Implementation steps

1. `PROVIDER=local make up` on minikube (LOCAL-010 end state).
2. Q1 sequence; inspect `kubectl get pv`, the node directory
   (`minikube ssh -- ls -ln /var/lib/vk-local-lab/cnpg-system`), and the
   operator log.
3. Q2: `minikube stop && minikube start`; check the directory; try
   `minikube mount`.
4. Q3: patch the Gateway/EnvoyProxy by hand; run the two `curl`s.
5. Write the results table; `PROVIDER=local make down`; delete the spike
   provisioner and PVs by hand.

## 7. Dependencies and blockers

LOCAL-010 (Argo CD and the Secrets it creates).

## 8. Acceptance criteria

- Three rows in the results table, each with a yes/no and a command output
  excerpt.
- Each dependent spec's §12 updated with the decision.
- No spike manifest committed.

## 9. Validation

Manual only.

## 10. AWS regression protection

None needed; nothing under `gitops/` or `scripts/` changes.

## 11. Rollout and rollback/recovery

Manual cleanup at the end of step 5.

## 12. Risks and unresolved questions

- The spike runs on one macOS minikube; kind on Linux (CI) uses a plain
  bind mount inside the node container and is less likely to differ on Q1.

## 13. Definition of done

- [ ] Results table in `research.md`
- [ ] LOCAL-040 and LOCAL-050 §12 updated; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as `READY`.
- 2026-09-11 — replanned: no kind config; provisioner is ours; port-forward instead of NodePort.
