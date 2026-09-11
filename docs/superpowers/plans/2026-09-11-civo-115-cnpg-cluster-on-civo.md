# CIVO-115: CNPG Cluster on Civo (no persistence) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a working CloudNativePG database on the Civo target, with data explicitly disposable, so CIVO-180's backup jobs have something to dump.

**Architecture:** The CNPG operator, the app-password `ExternalSecret`, and a `platform.storageClassName` helper that already resolves `civo-volume` are all in place on Civo today; only the `Cluster` CR is missing, because it lives under `aws/` behind a target gate. This plan hoists that one file to `shared/`, gating the four AWS-only parts inline, then replaces the Civo teardown tripwire that currently refuses to delete any cluster holding a database.

**Tech Stack:** Helm (the `gitops/` chart), Argo CD, CloudNativePG chart `0.29.0`, Bash (`scripts/`), Civo CSI (`csi.civo.com`).

**Spec:** `specs/civo/115-cnpg-cluster-on-civo/spec.md` — **does not exist yet; Task 4 creates it.** Until then the authority is the approved approach plan at `/Users/savak/.claude/plans/let-s-review-civo-tasks-sleepy-pizza.md`, plus `specs/civo/120-cnpg-on-civo-persistence/spec.md` §4 (design contracts this spec borrows) and `docs/adr/0031-logical-backups-to-s3.md` (the governing decision).

## Global Constraints

- **The AWS golden diff must stay byte-identical.** `scripts/gitops-render-check.sh` must pass with no `MODE=update`. That empty diff is this spec's only AWS regression proof — no AWS cloud cycle is planned.
- **`yq -P 'sort_keys(..)'` preserves YAML comments**, so the golden baseline contains them (see `tests/golden/gitops-aws/platform/Cluster__cnpg-system__lab-postgres.yaml`). Any comment edit inside AWS-rendered output changes the golden. Carry existing comments **byte-for-byte**; add new comments only inside `target == civo` gates.
- Code comments: at most 3 lines, prefer 1. Never reference specs, ADRs, or tickets in a code comment. **Exception, deliberate:** the comments carried verbatim in Task 1 already violate this (one 5-line block, one `See ADR 0013`). They are pre-existing and must not be "fixed" here — see Task 1 Step 4.
- Never write a real root domain into code, values, or docs. Use `<root-domain>` / `civo.<root-domain>`.
- Argo sync-waves stay **uniform across targets** — no `{{ if civo }}` wave expressions.
- `PROVIDER=civo` goes on the same command line as `make`; never `source scripts/lib/provider.sh` first.
- `AWS_PROFILE=viacheslav-dev` for every AWS CLI call (static IAM user, not SSO).
- Work in place on branch `civo-115-cnpg-cluster-on-civo`. No git worktrees.
- The teardown override variable is spelled `CI_TEARDOWN_ALLOW_DATA_LOSS` exactly — fixed by CIVO-120 §4 and CIVO-180 §4.

**Already done, do not repeat:** the Civo Postgres app password was re-encrypted to an operator-supplied value and pushed to SSM (`/vk-civo-lab/persistent/postgres/app_password`, Version 2). `secrets/vk-civo-lab/postgres-app-password.enc` is already committed on this branch. Never write the plaintext into any file.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `gitops/templates/platform/shared/postgres/cluster.yaml` | **Create** (git mv from `aws/postgres/`) | The single `Cluster` CR for both targets, target-gated inline |
| `gitops/templates/platform/aws/postgres/cluster.yaml` | **Delete** (moved) | — |
| `gitops/values.yaml` | Modify (~line 44-52) | Fix the now-false `postgres.nodeSelector` comment |
| `scripts/gitops-render-check.sh` | Modify (lines 63-74) | Require the Cluster on civo; stop forbidding the kind |
| `scripts/lib/provider.sh` | Modify (lines 104-116) | `civo_backup()` becomes a fail-closed gate with an override |
| `scripts/argo-down.sh` | Modify (after line 304) | Wait for `cnpg-system` PVCs to actually disappear on civo |
| `specs/civo/115-cnpg-cluster-on-civo/spec.md` | **Create** | The spec of record, 14-section format |
| `specs/civo/120-cnpg-on-civo-persistence/spec.md` | Modify | Gains `depends_on: CIVO-115`; step 2 removed |
| `specs/civo/README.md` | Modify (index table) | New row; 120's depends-on cell |
| `specs/civo/roadmap.md` | Modify (graph + critical path) | New edges |
| `docs/architecture.md` | Modify (~line 544-546) | Interim qualifier on the civo persistence claim |

`aws/postgres/recovered-snapshot.yaml` is **not** touched — it stays AWS-only and already carries its own double gate.

---

### Task 1: Hoist the Cluster template to `shared/`, target-gated

**Files:**
- Create: `gitops/templates/platform/shared/postgres/cluster.yaml`
- Delete: `gitops/templates/platform/aws/postgres/cluster.yaml`
- Modify: `scripts/gitops-render-check.sh:63-74`
- Modify: `gitops/values.yaml:47-52`
- Test: `scripts/gitops-render-check.sh` (this repo has no unit-test framework for Helm templates; the render check *is* the test)

**Interfaces:**
- Consumes: `platform.storageClassName` from `gitops/templates/_helpers.tpl:17-23` — a named template taking the root context (`.`), returning `civo-volume` when `.Values.target == "civo"`, else `.Values.storage.className`. It is currently defined and used by nothing; this task is its first caller.
- Produces: a `Cluster/lab-postgres` object in namespace `cnpg-system` on **both** targets, sync-wave `"3"`. Task 3 waits on the PVC it creates; Task 2's gate detects it via `kubectl get clusters.postgresql.cnpg.io`.

- [ ] **Step 1: Write the failing test — require the Cluster on civo**

In `scripts/gitops-render-check.sh`, append `Cluster__cnpg-system__lab-postgres` to the `REQUIRED_OBJECTS_CIVO` list (currently lines 63-70, ending `HTTPRoute__envoy__https-redirect"`). The list is a space-separated string continued with backslashes:

```bash
REQUIRED_OBJECTS_CIVO="EnvoyProxy__envoy__envoy-proxy-config Gateway__envoy__platform-gateway \
GatewayClass__cluster__envoy-gateway Application__argocd__cert-manager \
ClusterIssuer__cluster__civo-workload-ca Certificate__external-secrets__eso \
Certificate__kube-system__external-dns Certificate__cert-manager__cert-manager \
ClusterSecretStore__cluster__aws-parameter-store \
ExternalSecret__cnpg-system__lab-postgres-app Application__argocd__external-dns \
ClusterIssuer__cluster__letsencrypt-staging ClusterIssuer__cluster__letsencrypt-prod \
Certificate__envoy__platform-public HTTPRoute__envoy__https-redirect \
Cluster__cnpg-system__lab-postgres"
```

- [ ] **Step 2: Run the check to verify it fails**

Run: `make gitops-check`

Expected: FAIL with `GITOPS-RENDER-CHECK: target=civo is missing required object Cluster__cnpg-system__lab-postgres`

- [ ] **Step 3: Stop forbidding the `Cluster` kind on civo**

In the same file, remove `Cluster` from `FORBIDDEN_KINDS_CIVO` (line 73-74). **Leave `FORBIDDEN_KINDS_LOCAL` exactly as it is** — the `local` target still must not render one.

Before:
```bash
FORBIDDEN_KINDS_CIVO="StorageClass VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot \
Cluster NodePool EC2NodeClass"
```

After:
```bash
FORBIDDEN_KINDS_CIVO="StorageClass VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot \
NodePool EC2NodeClass"
```

- [ ] **Step 4: Move the template and gate it**

```bash
git mv gitops/templates/platform/aws/postgres/cluster.yaml \
       gitops/templates/platform/shared/postgres/cluster.yaml
```

Then replace the file's contents with exactly this. **Every comment below is copied byte-for-byte from the original** — including the 5-line `backup` comment and its `See ADR 0013` reference, both of which violate the repo's comment rules. Do not shorten, reword, or re-wrap any of them: they are present in `tests/golden/gitops-aws/platform/Cluster__cnpg-system__lab-postgres.yaml`, so editing one breaks the byte-identical golden gate. The only new comment is the two-line one under the civo gate, which never reaches the AWS render.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: lab-postgres
  namespace: cnpg-system
  annotations:
    # After the wave-2 ExternalSecret: CNPG generates its own lab-postgres-app
    # password Secret if none exists yet, and ESO then collides with it.
    argocd.argoproj.io/sync-wave: "3"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  instances: 1
  priorityClassName: postgres-critical
  {{- if eq .Values.target "civo" }}
  # CNPG creates a PodDisruptionBudget even for a single instance, and that
  # budget blocks a node from ever draining.
  enablePDB: false
  {{- end }}
  {{- if and (eq .Values.target "aws") .Values.postgres.nodeSelector }}
  affinity:
    nodeSelector:
      {{- .Values.postgres.nodeSelector | toYaml | nindent 6 }}
  {{- end }}
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
  bootstrap:
    {{- if and (eq .Values.target "aws") .Values.postgres.recoverySnapshotHandle }}
    # No initdb fallback: a loud failure beats silently wiping a recoverable
    # database. database/owner enable CNPG's app-user password reconciler on
    # this path - without them the pinned password is never re-applied.
    recovery:
      database: vkdb
      owner: vkdb
      volumeSnapshots:
        storage:
          apiGroup: snapshot.storage.k8s.io
          kind: VolumeSnapshot
          name: lab-postgres-recovered
    {{- else }}
    initdb:
      database: vkdb
      owner: vkdb
    {{- end }}
  storage:
    # Increase-only: shrinking a PVC is rejected by Kubernetes, and on the
    # snapshot-recovery path (above) the new PVC must be >= the snapshot's
    # restore size or it never binds.
    size: {{ .Values.postgres.storageSize | quote }}
    storageClass: {{ include "platform.storageClassName" . }}
  {{- if eq .Values.target "aws" }}
  # Cold (online: false) volume-snapshot backup - confirmed via CNPG docs
  # to need neither an object store nor WAL archiving, just a CSI driver
  # that supports snapshots. instances: 1 means this briefly fences the
  # primary; acceptable since argo-down.sh triggers it immediately before
  # tearing the cluster down anyway. See ADR 0013.
  backup:
    volumeSnapshot:
      className: ebs-postgres-snapshot
      online: false
  {{- end }}
  postgresql:
    parameters:
      max_wal_senders: "10"
      max_replication_slots: "10"
      # wal_level intentionally not set — CNPG defaults it to "logical" already
      # shared_buffers / max_connections intentionally not set — sized only by
      # the requests above, not by explicit limits
```

Four substantive differences from the original, all deliberate:
1. The outer `{{- if eq .Values.target "aws" }}` / `{{- end }}` wrapper is **gone** — that is what makes the file render on civo.
2. `storageClass` now calls `include "platform.storageClassName" .` instead of reading `.Values.storage.className`. On aws the helper returns `.Values.storage.className` (`ebs-delete`), so the rendered output is identical.
3. `affinity.nodeSelector` and the `backup` block are aws-gated. Helm deep-merges values, so without the first gate Civo's pod would demand a `workload-type: on-demand` node label that does not exist on its fixed pool; without the second, Civo would reference a `VolumeSnapshotClass` its CSI driver cannot provide.
4. The `recovery` bootstrap branch gains `(eq .Values.target "aws")`. `civo_recovery_handle()` in `scripts/lib/provider.sh:99-102` already always returns an empty string, so this changes no behaviour today — it prevents a stray `--set postgres.recoverySnapshotHandle=…` from rendering a `VolumeSnapshot` reference on a target with no snapshot CRDs at all.

- [ ] **Step 5: Run the check — civo passes, AWS golden unchanged**

Run: `make gitops-check`

Expected: PASS, with no diff output for `tests/golden/gitops-aws`. If the golden diff is non-empty, the gating is wrong — **do not run `MODE=update`**, fix the template. The most likely causes are a changed comment, a stray blank line from wrong `{{-` chomping, or `enablePDB` leaking outside the civo gate.

- [ ] **Step 6: Confirm the civo render by eye**

Run:
```bash
helm template gitops ./gitops --set target=civo --set project=vk-civo-lab \
  --set postgres.storageSize=20Gi \
  --show-only templates/platform/shared/postgres/cluster.yaml
```

Expected: `storageClass: civo-volume`, `enablePDB: false`, `bootstrap.initdb`, and **no** `affinity` and **no** `backup` key.

- [ ] **Step 7: Fix the now-false comment in values.yaml**

`gitops/values.yaml` lines 47-52 currently read:

```yaml
postgres:
  recoverySnapshotHandle: ""
  storageSize: 20Gi
  # Pins Postgres off spot (AZ-pinned PVC + interruption risk). Helm deep-
  # merges values, so a target without an on-demand pool needs its own
  # postgres/cluster.yaml (or a nodeSelector: null override), not {}.
  nodeSelector:
    workload-type: on-demand
```

The last two comment lines became false in Step 4. Replace the three-line comment with:

```yaml
  # Pins Postgres off spot (AZ-pinned PVC + interruption risk). aws-only:
  # Helm deep-merges values, so the shared Cluster template gates this on
  # target rather than relying on a per-target override.
```

This comment is in `values.yaml`, not a template, so it does not reach any rendered output or the golden baseline.

- [ ] **Step 8: Re-run the check and commit**

Run: `make gitops-check` — expected PASS, golden diff still empty.

```bash
git add gitops/templates/platform/shared/postgres/cluster.yaml \
        gitops/templates/platform/aws/postgres/cluster.yaml \
        gitops/values.yaml scripts/gitops-render-check.sh
git commit -m "civo-115: render the CNPG Cluster on civo from a shared template"
```

---

### Task 2: Replace the Civo teardown refusal with a fail-closed gate

**Files:**
- Modify: `scripts/lib/provider.sh:104-116`

**Interfaces:**
- Consumes: the `Cluster/lab-postgres` object Task 1 now renders on civo.
- Produces: `civo_backup()` — same name, same call site (`scripts/argo-down.sh:45`), same zero-argument signature. It now exits non-zero **only** when a Cluster exists *and* `CI_TEARDOWN_ALLOW_DATA_LOSS` is not `1`. CIVO-180 later replaces its body with a real dump.

**Context:** `civo_backup()` was written as a tripwire — it refuses to tear down any Civo cluster holding a CNPG database, because no backup path exists. Task 1 makes it fire on every single `make down`. It must become a gate the operator can consciously step through, without becoming a silent no-op.

- [ ] **Step 1: Read the current function**

Run: `sed -n '104,116p' scripts/lib/provider.sh`

Expected output:
```bash
# Fail closed: no backup path exists on civo yet, so refuse to tear down a
# cluster that still holds Postgres data. A missing CNPG CRD means "no
# cluster", not a failed check, hence the two-step probe.
civo_backup() {
  if kubectl get clusters.postgresql.cnpg.io -A >/dev/null 2>&1; then
    if [ -n "$(kubectl get clusters.postgresql.cnpg.io -A -o name 2>/dev/null)" ]; then
      echo "ARGO-DOWN: a CNPG Cluster exists on civo but CIVO-120's backup path isn't implemented yet - refusing to tear down and risk losing Postgres data." >&2
      exit 1
    fi
  fi
  echo "ARGO-DOWN: no CNPG Cluster found on civo - nothing to back up."
}
```

- [ ] **Step 2: Replace it**

Replace those 12 lines with exactly:

```bash
# Fail closed: no backup path exists on civo yet, so tearing down destroys
# the database. The override makes that an explicit operator choice. A
# missing CNPG CRD means "no cluster", not a failed check - hence two probes.
civo_backup() {
  if kubectl get clusters.postgresql.cnpg.io -A >/dev/null 2>&1; then
    if [ -n "$(kubectl get clusters.postgresql.cnpg.io -A -o name 2>/dev/null)" ]; then
      if [ "${CI_TEARDOWN_ALLOW_DATA_LOSS:-}" = "1" ]; then
        echo "ARGO-DOWN: CI_TEARDOWN_ALLOW_DATA_LOSS=1 - tearing down and discarding all Postgres data on civo."
        return 0
      fi
      echo "ARGO-DOWN: a CNPG Cluster exists on civo and no backup path is implemented yet - refusing to tear down and silently lose Postgres data." >&2
      echo "ARGO-DOWN: re-run with CI_TEARDOWN_ALLOW_DATA_LOSS=1 to discard the database deliberately." >&2
      exit 1
    fi
  fi
  echo "ARGO-DOWN: no CNPG Cluster found on civo - nothing to back up."
}
```

The comment is 3 lines and names no spec or ticket, per the repo's rules. The old message referenced `CIVO-120`; the new one does not.

- [ ] **Step 3: Lint the script**

Run: `shellcheck scripts/lib/provider.sh`

Expected: no new findings (the file may have pre-existing ones; compare against `git stash`-ed output only if anything appears at the new lines).

- [ ] **Step 4: Verify the branch logic without a cluster**

Run:
```bash
bash -c '
CI_TEARDOWN_ALLOW_DATA_LOSS=1
kubectl() { return 1; }   # simulate: CNPG CRD absent
source scripts/lib/provider.sh 2>/dev/null || true
' 2>&1 | head -3
```

This is a smoke check only — `provider.sh` is not directly unit-testable here, and the real verification is Task 5 steps 6 and 7 against a live cluster. Do not build test scaffolding for it.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/provider.sh
git commit -m "civo-115: gate civo teardown on CI_TEARDOWN_ALLOW_DATA_LOSS"
```

---

### Task 3: Wait for the Civo PVC to disappear before cluster-down runs

**Files:**
- Modify: `scripts/argo-down.sh` (insert after the cascade block that ends at line 304, before the `helm uninstall` loop)

**Interfaces:**
- Consumes: the cascade completing (`ARGO-DOWN: cascade complete.`), and the PVC CNPG creates for `Cluster/lab-postgres` in `cnpg-system`.
- Produces: nothing other than a bounded wait and a warning. No new function; inline, `PROVIDER = civo` gated.

**Context:** `scripts/cluster-down.sh:73-85` already sweeps dangling Civo volumes with `civo_list_names volume --dangling`, deletes them, **and exits non-zero** — a leak is treated as a cascade bug (ADR 0012/0026), not an acceptable cost. But the PVC → PV → CSI-delete chain is asynchronous relative to the `Cluster` object disappearing, and `csi.civo.com` has never been exercised on this path (ADR 0013 verified only `ebs.csi.aws.com`). Without a wait, `make down` may start failing on a leak that is really just a race.

- [ ] **Step 1: Locate the insertion point**

Run: `sed -n '298,312p' scripts/argo-down.sh`

Expected output:
```bash
  wait "$DELETE_PID"
  echo "ARGO-DOWN: cascade complete."
else
  echo "ARGO-DOWN: root Application already gone - skipping cascade."
fi

# Final step: remove Argo CD itself. By now everything it managed is
# already gone, so this just tears down Argo CD's own Deployments/RBAC -
# no finalizers to wait through.
for release in root-application argocd; do
```

- [ ] **Step 2: Insert the wait**

Immediately after the `fi` that closes the cascade block and before the `# Final step:` comment, insert:

```bash
# The PVC/PV teardown is async relative to the Cluster object going away,
# and a Civo volume that outlives the cluster keeps billing - cluster-down
# treats one as a cascade bug and fails, so confirm it here instead.
if [ "$PROVIDER" = civo ]; then
  if [ -n "$(kubectl get pvc -n cnpg-system -o name 2>/dev/null)" ]; then
    echo "ARGO-DOWN: waiting for cnpg-system PVCs to finish deleting..."
    if ! kubectl wait --for=delete pvc -n cnpg-system --all --timeout="$PVC_WAIT_TIMEOUT"; then
      echo "ARGO-DOWN: WARNING - cnpg-system PVCs still present after ${PVC_WAIT_TIMEOUT}; the Civo volume may" >&2
      echo "ARGO-DOWN: outlive the cluster. cluster-down's dangling-volume sweep will catch and delete it, and" >&2
      echo "ARGO-DOWN: will fail the run so this surfaces rather than being absorbed." >&2
    fi
  else
    echo "ARGO-DOWN: no cnpg-system PVCs present - nothing to wait on."
  fi
fi
```

- [ ] **Step 3: Declare the timeout alongside the other tunables**

`scripts/argo-down.sh` declares its timeouts near the top (lines 18-23: `TIMEOUT`, `POLL_INTERVAL`, `BACKUP_TIMEOUT`). Add one more immediately after `BACKUP_TIMEOUT` (line 23):

```bash
PVC_WAIT_TIMEOUT="${ARGO_DOWN_PVC_WAIT_TIMEOUT:-180s}"
```

180s is chosen because the CIVO-020 spike measured a Civo volume moving `attached` → `available` within seconds of its cluster going away; three minutes is generous headroom without materially lengthening a failed teardown.

- [ ] **Step 4: Lint**

Run: `shellcheck scripts/argo-down.sh`

Expected: no new findings.

- [ ] **Step 5: Commit**

```bash
git add scripts/argo-down.sh
git commit -m "civo-115: wait for cnpg-system PVCs to clear on civo teardown"
```

---

### Task 4: Spec and documentation bookkeeping

**Files:**
- Create: `specs/civo/115-cnpg-cluster-on-civo/spec.md`
- Modify: `specs/civo/120-cnpg-on-civo-persistence/spec.md` (front matter + §3 + §6)
- Modify: `specs/civo/README.md` (index table)
- Modify: `specs/civo/roadmap.md` (Mermaid graph + critical path)
- Modify: `docs/architecture.md:544-546`

**Interfaces:**
- Consumes: nothing from earlier tasks at runtime; it documents what Tasks 1-3 built.
- Produces: `specs/civo/115-cnpg-cluster-on-civo/spec.md` as the spec of record. Task 5 writes its evidence into that file's §14.

**No ADR.** `docs/adr/0031-logical-backups-to-s3.md` already governs the backup mechanism. This spec adds no architectural decision, only an ordering step. Do not create or amend an ADR.

- [ ] **Step 1: Create the new spec**

Create `specs/civo/115-cnpg-cluster-on-civo/spec.md`. Match the folder's fixed 14-section format exactly — copy the section headings from `specs/civo/120-cnpg-on-civo-persistence/spec.md`. Front matter:

```yaml
---
id: "CIVO-115"
title: "CNPG Cluster on Civo with disposable data"
status: "IN_PROGRESS"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "A values-driven template hoist and two script changes; the data-safety reasoning lives in CIVO-120"
effort_estimate: "One session (3–5 h) including one bring-up and one teardown"
estimate_confidence: "high"
depends_on: ["CIVO-050", "CIVO-100"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: null
---
```

Required content, by section:
- **§1 Outcome:** a single-instance CNPG cluster runs on `civo-volume` storage with the app password from External Secrets. State plainly that **data is destroyed by every `make down`** until CIVO-180 and CIVO-120 land, and that `CI_TEARDOWN_ALLOW_DATA_LOSS=1` is required for every Civo teardown in the interim.
- **§2 Scope:** in — the shared `Cluster` template, the teardown gate, the PVC wait, render-check updates. Out — anything needing S3, the backup image, dump/restore jobs, the AWS target's snapshot path, and replicas (`instances: 1` is explicit).
- **§3 Current state:** the CNPG operator Application is shared at wave `-1`; `ExternalSecret/lab-postgres-app` already renders on civo; `/vk-civo-lab/persistent/postgres/app_password` exists in SSM; `platform.storageClassName` exists in `_helpers.tpl` and had no caller.
- **§4 Design:** storage `civo-volume`, 20 Gi, reclaim `Delete` — the volume dies with the cluster by design. No `nodeSelector` on civo. `enablePDB: false` on civo. Bootstrap always `initdb` on civo. Sync-wave `3`, uniform with aws.
- **§8 Acceptance criteria:** the seven checks from Task 5.
- **§10 AWS regression protection:** the golden diff is byte-identical, which is the whole proof; no AWS cloud cycle was run or is needed.
- **§12 Risks / unresolved:** (a) the hoisted template carries two pre-existing comment-rule violations verbatim (a 5-line block and an `ADR 0013` reference) because `yq -P` preserves comments in the golden baseline, so editing them would force a golden regeneration and weaken §10's proof — fixing them belongs to whichever spec next regenerates that golden; (b) whether the Task 3 PVC wait is sufficient is answered empirically by §14's evidence.

- [ ] **Step 2: Update CIVO-120**

In `specs/civo/120-cnpg-on-civo-persistence/spec.md`:
- front matter: `depends_on: ["CIVO-050", "CIVO-100", "CIVO-115", "CIVO-180"]`, and `updated: "2026-09-11"`.
- §3: add a bullet recording that the `Cluster` template now lives at `gitops/templates/platform/shared/postgres/cluster.yaml` and renders on civo, delivered by CIVO-115.
- §6 Implementation steps: delete step 2 ("Template the `Cluster` with values…") and renumber the remaining steps. Everything else — the two-cycle data proof, the teardown dump gate, the failure paths — stays exactly as written.
- §14: append `- 2026-09-11 — CNPG Cluster delivery split out to CIVO-115 (runs on civo with disposable data); this spec keeps the persistence proof.`

- [ ] **Step 3: Update the spec index**

In `specs/civo/README.md`, insert a row between the CIVO-110 and CIVO-120 rows:

```
| CIVO-115 | [115-cnpg-cluster-on-civo](115-cnpg-cluster-on-civo/spec.md) | CNPG Cluster on Civo, data disposable | IN_PROGRESS | P1 | M | standard | 050, 100 | M1 |
```

and change CIVO-120's "Depends on" cell from `050, 100, 180` to `050, 100, 115, 180`.

- [ ] **Step 4: Update the roadmap**

In `specs/civo/roadmap.md`, inside the Mermaid `flowchart TD` block, replace these two lines:

```
  050 --> 120[120 CNPG persistence]
  100 --> 120
```

with:

```
  050 --> 115[115 CNPG Cluster on civo]
  100 --> 115
  115 --> 120[120 CNPG persistence]
  180 --> 120
```

and delete the now-duplicate `180 --> 120` line further down the graph. Then update the "Critical path" line from:

```
015 → 010 → 025 → 030 → 040 → 045 (with 050) → 065 → 080 → 082 → 085 → 090 → 100 → 180 → 120 → 150.
```

to:

```
015 → 010 → 025 → 030 → 040 → 045 (with 050) → 065 → 080 → 082 → 085 → 090 → 100 → 115 → 180 → 120 → 150.
```

- [ ] **Step 5: Qualify the architecture claim**

`docs/architecture.md` around lines 544-546 currently states that on `civo`, Postgres persists via logical dumps. That is the target state, not today's. Add a single sentence noting that until CIVO-180 and CIVO-120 land, Civo's Postgres data is disposable and every teardown requires `CI_TEARDOWN_ALLOW_DATA_LOSS=1`. Keep the existing sentence intact — add to it, do not rewrite it.

- [ ] **Step 6: Verify no real domain leaked**

Run: `git diff --cached; git diff` and grep the new spec for a real domain:

```bash
grep -rniE "$(make -s print-root-domain 2>/dev/null || echo 'NEVER-MATCH')" \
  specs/civo/115-cnpg-cluster-on-civo/spec.md
```

If that helper does not exist, grep for the real root domain interactively and
do not paste it into any file — the literal domain must never be committed,
including inside a grep pattern.

Expected: no hits, or only `<root-domain>`-style placeholders.

- [ ] **Step 7: Commit**

```bash
git add specs/civo/115-cnpg-cluster-on-civo/spec.md \
        specs/civo/120-cnpg-on-civo-persistence/spec.md \
        specs/civo/README.md specs/civo/roadmap.md docs/architecture.md
git commit -m "civo-115: add the spec, reorder 120 behind it, update index and roadmap"
```

---

### Task 5: Real-cloud verification on `vk-civo-lab`

**Files:**
- Modify: `specs/civo/115-cnpg-cluster-on-civo/spec.md` (§14 evidence, then §13 and front-matter status)
- No other files (`secrets/vk-civo-lab/postgres-app-password.enc` was committed before Task 1)

**Interfaces:**
- Consumes: everything from Tasks 1-4, plus the already-updated SSM parameter `/vk-civo-lab/persistent/postgres/app_password` (Version 2).
- Produces: the evidence block in §14 and a `DONE`-ready spec.

**Context:** `scripts/argo-up.sh` deploys from a **remote** git ref. An unpushed branch silently verifies whatever is on `main` — this cost a full wasted verification cycle during CIVO-075. Push first, always.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin civo-115-cnpg-cluster-on-civo
```

`secrets/vk-civo-lab/postgres-app-password.enc` was already committed before Task 1 began — only the KMS ciphertext, never the plaintext. Do not re-commit it.

- [ ] **Step 2: Bring up a fresh cluster**

Run: `AWS_PROFILE=viacheslav-dev PROVIDER=civo make up`

This must be a **fresh** bring-up, not an Argo re-sync of a running cluster — only a fresh `initdb` exercises the new password and the `civo-volume` PVC binding. If a cluster is already running, tear it down first with `CI_TEARDOWN_ALLOW_DATA_LOSS=1 PROVIDER=civo make down`.

Expected: `root` Application reaches `Synced/Healthy`.

- [ ] **Step 3: Confirm the Cluster is healthy**

```bash
kubectl get cluster -n cnpg-system lab-postgres \
  -o jsonpath='{.status.phase}{"\n"}'
kubectl get pods -n cnpg-system -l cnpg.io/cluster=lab-postgres
```

Expected: phase `Cluster in healthy state`; one pod `1/1 Running`.

- [ ] **Step 4: Confirm the storage**

```bash
kubectl get pvc -n cnpg-system -o custom-columns=NAME:.metadata.name,SC:.spec.storageClassName,SIZE:.spec.resources.requests.storage,STATUS:.status.phase
AWS_PROFILE=viacheslav-dev PROVIDER=civo make clusters   # or: civo volume ls
```

Expected: one PVC `Bound` on `civo-volume` at `20Gi`; the matching Civo volume listed as attached.

- [ ] **Step 5: Confirm the aws-only fields are absent and no PDB exists**

```bash
kubectl get cluster -n cnpg-system lab-postgres -o json \
  | jq '{nodeSelector: .spec.affinity.nodeSelector, backup: .spec.backup, enablePDB: .spec.enablePDB}'
kubectl get pdb -n cnpg-system
```

Expected: `nodeSelector` and `backup` both `null`; `enablePDB` `false`; `No resources found` for the PDB.

- [ ] **Step 6: Write and read rows as the app user**

```bash
kubectl exec -n cnpg-system lab-postgres-1 -- \
  psql -U vkdb -d vkdb -c "CREATE TABLE civo115 (id int, note text);" \
                        -c "INSERT INTO civo115 VALUES (1, 'hello');" \
                        -c "SELECT * FROM civo115;"
```

Expected: the row comes back. Then confirm the password path end to end by connecting with the credential ESO synced, rather than via the trusted local socket:

```bash
kubectl get secret -n cnpg-system lab-postgres-app -o jsonpath='{.data.password}' | base64 -d | head -c 4; echo
```

Expected: the first four characters match the operator-supplied password. **Do not print the full value** and do not record it in §14.

- [ ] **Step 7: Confirm the teardown gate refuses by default**

Run: `AWS_PROFILE=viacheslav-dev PROVIDER=civo make down`

Expected: exits non-zero with `refusing to tear down and silently lose Postgres data` and the `CI_TEARDOWN_ALLOW_DATA_LOSS=1` hint. Then confirm nothing was destroyed:

```bash
kubectl get cluster -n cnpg-system lab-postgres
kubectl exec -n cnpg-system lab-postgres-1 -- psql -U vkdb -d vkdb -c "SELECT count(*) FROM civo115;"
```

Expected: cluster still healthy, count still `1`.

- [ ] **Step 8: Tear down deliberately and confirm no volume leaks**

Run: `AWS_PROFILE=viacheslav-dev CI_TEARDOWN_ALLOW_DATA_LOSS=1 PROVIDER=civo make down`

Expected, in order:
- `ARGO-DOWN: CI_TEARDOWN_ALLOW_DATA_LOSS=1 - tearing down and discarding all Postgres data on civo.`
- `ARGO-DOWN: waiting for cnpg-system PVCs to finish deleting...` followed by success, **not** the WARNING.
- `CLUSTER-DOWN: no leaked disposable-lifecycle resources found.` and an exit code of 0.

Then independently: `civo volume ls` shows no dangling volume for this project.

If `cluster-down` reports a leaked volume instead, the Task 3 wait is insufficient — fix it there (raise `ARGO_DOWN_PVC_WAIT_TIMEOUT`, or wait on the PV rather than the PVC), do not weaken the sweep.

- [ ] **Step 9: Record the evidence and close the spec**

Append a dated entry to §14 of `specs/civo/115-cnpg-cluster-on-civo/spec.md` with the commands run and their results — cluster phase, PVC storage class and size, the absent `nodeSelector`/`backup`/PDB, the row round-trip, both teardown outcomes, and the clean leak sweep. Replace any real domain with `<root-domain>`. Record **no** password material.

Then set front matter `status: "DONE"` and `completed: "2026-09-11"`, tick both boxes in §13, and update the CIVO-115 row in `specs/civo/README.md` from `IN_PROGRESS` to `DONE`.

- [ ] **Step 10: Commit**

```bash
git add specs/civo/115-cnpg-cluster-on-civo/spec.md specs/civo/README.md
git commit -m "civo-115: record real-cloud evidence and close the spec"
```

---

## Self-Review

**1. Spec coverage.** The spec does not exist yet, so the approved approach plan is the checklist. Approach Task 0 — done before this plan, excluded as instructed, with its artifact committed in Task 5 Step 1. Approach Tasks 1 and 2 are merged into plan Task 1: they are each other's test (the render-check requirement is the failing test for the template hoist), and no reviewer could sensibly approve one while rejecting the other. Approach Tasks 3, 4, 5, 6 map to plan Tasks 2, 3, 4, 5. Every acceptance criterion in the approach plan's Task 6 appears as a numbered step in plan Task 5.

**2. Placeholder scan.** No `TBD`, no "add error handling", no "similar to Task N". Every code step carries the literal text to write. The one deliberate omission is the password plaintext, which is a security requirement, not a placeholder — Task 5 Step 6 verifies it by prefix instead.

**3. Type consistency.** `platform.storageClassName` is invoked as `include "platform.storageClassName" .` matching its definition at `_helpers.tpl:17-23`, which reads `.Values.target` off the root context. `civo_backup()` keeps its zero-argument signature and its single call site at `argo-down.sh:45`. `PVC_WAIT_TIMEOUT` is declared in Task 3 Step 3 and consumed in Step 2 of the same task — note for the implementer: **write Step 3 before Step 2 if you prefer, the variable must exist before the block that reads it.** Object key `Cluster__cnpg-system__lab-postgres` is spelled identically in Task 1 Step 1 and Task 1 Step 2's expected failure message.
