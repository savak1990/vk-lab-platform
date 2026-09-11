---
id: "HETZ-170"
title: "Cluster autoscaler with cloudProvider hetzner: zero to two extra CAX21 workers joined by cloud-init"
status: "READY"
priority: "P3"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Servers created outside Terraform, a join token in-cluster, and a teardown-ordering dependency need careful reasoning"
effort_estimate: "One session (4–6 h) plus scaling waits"
estimate_confidence: "medium"
depends_on: ["HETZ-030", "HETZ-040", "HETZ-045"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-170 — Cluster autoscaler on Hetzner

## 1. Outcome and rationale

The upstream cluster autoscaler with `cloudProvider: hetzner` adds up to
two CAX21 workers when pods stay pending and removes them after sustained
underutilisation. The fixed three-node pool from HETZ-030 stays; the
autoscaler only adds. Idle cost is unchanged.

Read `specs/civo/170-civo-cluster-autoscaler/spec.md` first. The Civo
blocker (one account-wide key) does not exist here: Hetzner tokens are
per project and the token is already in-cluster for CCM and CSI.

## 2. Scope and non-goals

In scope: the Argo Application, the node-group config, the join-token
Secret, the sweep interaction, a scale test. Not in scope: multiple
pools, mixed architectures, scaling the fixed pool down.

## 3. Current state / evidence

- research.md: env `HCLOUD_TOKEN`, `HCLOUD_CLUSTER_CONFIG` (base64 JSON:
  `imagesForArch`, per-pool `cloudInit`, `labels`, `taints`, `serverLabels`,
  `firewalls`), `HCLOUD_NETWORK`, `HCLOUD_FIREWALL`, `HCLOUD_SSH_KEY`,
  `HCLOUD_PUBLIC_IPV4=true`; node groups
  `--nodes=<min>:<max>:<TYPE>:<LOCATION>:<name>`; rate limit 3600/h per
  project.
- HETZ-020 experiment 8 verifies scale-from-zero and that a joined node
  receives its `providerID` from the CCM.
- HETZ-030 writes the k3s join token and the control-plane private IP to
  SSM under `/<project>/cluster-hetzner/k8s/` (join token as
  `SecureString`). HETZ-040's sweep selects servers by label
  `project=<project>` regardless of who created them.
- `enablePDB: false` on CNPG (HETZ-115). Karpenter-style consolidation
  does not exist; the autoscaler's scale-down window applies.

## 4. Design and contracts

- Application `platform/hetzner/autoscaler/application.yaml`, chart
  `cluster-autoscaler` pinned, `cloudProvider: hetzner`,
  `autoscalingGroups: [{name: workers, minSize: 0, maxSize: 2}]`, extra
  args `--nodes=0:2:CAX21:NBG1:workers`,
  `--skip-nodes-with-system-pods=false`,
  `--skip-nodes-with-local-storage=false`, `--scale-down-unneeded-time=10m`.
  Sync-wave 0 (after CSI and ESO). Tolerates nothing; runs on the fixed
  pool.
- Secret `kube-system/hcloud-autoscaler`, created by `argo-up` like the
  `hcloud` Secret: keys `token` (the same project token, or a second
  Read&Write token from `secrets/hcloud-autoscaler-token.enc` if the
  operator chooses), `cluster-config` (base64 JSON), `network`,
  `firewall`, `ssh-key`. The `cloudInit` inside `cluster-config` is the
  HETZ-030 agent template with the join token and the control-plane
  private IP filled from SSM, the same k3s version pinned, and
  `serverLabels: {project: <project>, role: worker, managed-by: autoscaler}`.
- `imagesForArch.arm64` = the `ubuntu-24.04` arm64 image id from HETZ-020.
- Teardown: `argo-down` cascade deletes the autoscaler Application before
  the CCM release goes (CCM is outside Argo and dies with the cluster).
  Autoscaler-created servers are not in Terraform; `cluster-down` runs the
  label sweep for servers with `managed-by=autoscaler` **before**
  `terragrunt destroy`, otherwise the firewall and subnet destroy hangs on
  "resource in use". HETZ-040 must expose that ordering as a pre-destroy
  hook.
- Observability: a ServiceMonitor for the autoscaler, gated on hetzner.
- Credential: the join token lets a reader add a node to the cluster; the
  Hetzner token lets a reader manage the Hetzner project. Both already
  hold the same blast radius as the CCM Secret (decisions.md §3).

## 5. Files/components affected

`gitops/templates/platform/hetzner/autoscaler/*.yaml` (new),
`gitops/values.yaml`, `scripts/argo-up.sh` (Secret creation),
`scripts/cluster-down.sh` (pre-destroy sweep), `scripts/lib/provider.sh`.

## 6. Implementation steps

1. Add the Application and the Secret creation. Golden diffs empty.
2. `PROVIDER=hetzner make up`. Autoscaler pod Ready; log shows the node
   group with 0 nodes.
3. Burst test: a Deployment requesting 6 GiB × 3 replicas. Observe two
   servers created within 5 min, joined, `providerID` set, pods Running.
   `hcloud server list -l managed-by=autoscaler` shows two.
4. Delete the Deployment. Observe scale-down to zero inside 15 min and
   the servers deleted by the autoscaler.
5. Repeat step 3, then run `make down` while the two servers exist.
   Confirm `cluster-down` deletes them before the destroy and the destroy
   does not hang.
6. `terragrunt plan` in `cluster-hetzner` shows no drift at any point.

## 7. Dependencies and blockers

HETZ-030 (join token, agent cloud-init template), HETZ-040 (sweep
ordering), HETZ-045 (Secret creation path).

## 8. Acceptance criteria

- Scale 0→2 and 2→0 observed and timed.
- Teardown with autoscaler nodes present completes without a hung destroy.
- Rate-limit headers never reach zero during the test (log
  `RateLimit-Remaining` samples).
- No Terraform drift.

## 9. Validation

Real cloud: the burst test, about 0.20 EUR.

## 10. AWS regression protection

Not applicable: hetzner-only files. Civo: golden diff empty; no shared
file changes.

## 11. Rollout and rollback/recovery

Remove the Application; the autoscaler deletes its nodes on scale-down;
if it is removed while nodes exist, the sweep reaps them at `cluster-down`.

## 12. Risks and unresolved questions

- The default 5-server limit: three fixed plus two autoscaled is exactly
  the limit. CI and lab cannot coexist (HETZ-140).
- An agent cloud-init that pins a different k3s version than the control
  plane fails to join silently. Pin from one variable.
- The autoscaler has a history of consuming the whole API budget
  (research.md). Keep `--scan-interval` at the default and watch the
  headers.

## 13. Definition of done

- [ ] Evidence; sweep ordering in HETZ-040 confirmed; index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT at P3/M2, mirroring CIVO-170's placement.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
