---
id: "HETZ-170"
title: "Cluster autoscaler with cloudProvider hetzner: one extra cx33 worker booting the fixed workers' cloud-init"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "A Secret-fed cluster config assembled across three scripts, an env-var wiring split between two Secrets, and a teardown-ordering dependency on two other specs need careful reasoning"
effort_estimate: "One session (4–6 h) plus scaling waits"
estimate_confidence: "medium"
depends_on: ["HETZ-030", "HETZ-045"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-23"
completed: "2026-09-23"
---

# HETZ-170 — Cluster autoscaler on Hetzner

## 1. Outcome and rationale

The upstream cluster autoscaler with `cloudProvider: hetzner` adds up to
two `cx33` workers when pods stay pending and removes each one after 10
minutes of sustained underutilisation. The fixed pool from HETZ-030 (one
control plane, one worker) stays; the autoscaler only adds, so the node
ceiling is four. Idle cost is unchanged.

A new node needs no join credential of its own. It boots the same worker
cloud-init that HETZ-030 renders for the fixed worker, which already
carries the join token and reads its own private address from instance
metadata, so it becomes a `k3s agent` against `https://10.0.1.10:6443`
exactly as the fixed worker did. This spec hands the autoscaler that
render; it produces nothing.

## 2. Scope and non-goals

In scope: the Argo Application, the node-group config, the cluster-config
Secret `argo-up` assembles from HETZ-030's `worker_user_data` SSM
parameter, the sweep and cascade teardown interaction, a scale test. Not
in scope: multiple node pools, mixed CPU architectures, scaling the fixed
pool down, and an HA control plane (decisions.md §3, Control-plane
topology — the agents' `K3S_URL` target `10.0.1.10:6443` is fixed).

## 3. Current state / evidence

- HETZ-030 §4 writes the rendered worker cloud-init to SSM
  `/<project>/cluster-hetzner/k8s/worker_user_data` as a `SecureString`,
  because it carries the k3s join token. It is the same render the fixed
  worker booted, with no substituted private address, so it is directly
  usable as a node template. The Hetzner API token this spec also needs
  lives separately in-cluster (HETZ-045), unchanged blast radius from
  decisions.md §3, "Autoscaler credential".
- research.md, "Cluster autoscaler `cloudProvider: hetzner`" row: the
  binary reads `HCLOUD_CLUSTER_CONFIG` as base64 JSON —
  `imagesForArch.amd64: ubuntu-24.04`, `nodeConfigs.workers.cloudInit`
  (itself base64, the joined cloud-init), `serverLabels: {project,
  scope: platform, lifecycle: disposable, managed_by: autoscaler, role:
  worker}` — plus the separate scalars `HCLOUD_NETWORK`, `HCLOUD_FIREWALL`,
  `HCLOUD_SSH_KEY`, `HCLOUD_PUBLIC_IPV4=true`, `HCLOUD_PUBLIC_IPV6=true`,
  and node-group syntax `--nodes=<min>:<max>:<TYPE>:<LOCATION>:<name>`.
  https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/hetzner/README.md
- research.md, "Versions on 2026-09-19" row: cluster-autoscaler must match
  the running cluster's Kubernetes minor, so the chart pin and
  HETZ-030's `K3S_VERSION` move together and neither is bumped alone.
  https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/README.md
- research.md, "Default limits" row: a Hetzner project defaults to 5
  servers. The fixed pool (1 control plane + 1 worker) plus the
  autoscaler ceiling (2) is 4, one under the default — CI running its own
  project-scoped count is HETZ-140's problem, not this spec's.
  https://docs.hetzner.com/cloud/servers/overview/
- HETZ-040's teardown sweep (`cluster-down.sh`, per that spec's §4)
  already deletes, by label, any server "not created by Terraform"
  before `terragrunt destroy` — the rule that now covers this spec's
  autoscaled nodes without a change to HETZ-040 itself.
- `enablePDB: false` on CNPG (HETZ-115); no Karpenter-style
  consolidation exists on this target, so the autoscaler's own
  scale-down window is the only downscale path.

## 4. Design and contracts

- Application `platform/hetzner/autoscaler/application.yaml`, chart
  `cluster-autoscaler` pinned (`CLUSTER_AUTOSCALER_VERSION=1.36.1` in
  `scripts/lib/versions.sh`), `cloudProvider: hetzner`,
  `autoscalingGroups` left empty, extra args
  `--nodes=0:2:CX33:NBG1:workers`,
  `--skip-nodes-with-system-pods=false`,
  `--skip-nodes-with-local-storage=false`, `--scale-down-unneeded-time=10m`.
  The `--nodes` flag is the single source of the node group — the hetzner
  provider reads the server type and location from it — so verify against
  the pinned chart that an empty `autoscalingGroups` renders no second
  `--nodes` flag.
  Sync-wave 0; runs on the fixed pool, no toleration needed, because a
  fixed node carries no taint by the time Argo CD renders this
  Application (HETZ-045).
- Two Secrets feed the pod's env, never a ConfigMap: `HCLOUD_TOKEN` maps
  from the existing `kube-system/hcloud` Secret via
  `valueFrom.secretKeyRef {name: hcloud, key: token}` (that Secret's keys
  are `token`/`network`, not `HCLOUD_TOKEN`, so `envFrom` would produce
  the wrong env-var names); `HCLOUD_NETWORK` maps the same Secret's
  `network` key the same way, reusing the id already in-cluster for the
  CCM. `HCLOUD_CLUSTER_CONFIG` comes from a second Secret,
  `kube-system/hcloud-autoscaler-config`, via `envFrom` (this spec
  controls that key's name). `HCLOUD_FIREWALL` and `HCLOUD_SSH_KEY` are
  plain `extraEnv` values taking the Helm values `autoscaler.firewallId`
  and `autoscaler.sshKeyId`, which the root Application relays from the
  SSM names `cluster-hetzner/firewall/firewall_id` and
  `persistent-hetzner/ssh-key/ssh_key_id` that HETZ-045 §4's batch 1
  reads — ids, not secrets, so a literal value suffices; `HCLOUD_PUBLIC_IPV4=true` and
  `HCLOUD_PUBLIC_IPV6=true` are static `extraEnv` values matching
  HETZ-030's `public_net` config on the fixed nodes.
- Exact mechanism for `kube-system/hcloud-autoscaler-config`: a new
  `ensure_autoscaler_config()` in `scripts/argo-up.sh`, hetzner-only,
  called immediately after `wait_for_nodes_initialized()` (HETZ-045),
  before the fast-path return. It reads SSM
  `/<project>/cluster-hetzner/k8s/worker_user_data` with
  `--with-decryption`, base64-encodes the plaintext once into
  `nodeConfigs.workers.cloudInit`, builds the rest of the JSON
  (`imagesForArch.amd64`, `serverLabels`) with `jq`, base64-encodes the
  whole object, and writes it with `kubectl create secret generic
  hcloud-autoscaler-config -n kube-system
  --from-literal=HCLOUD_CLUSTER_CONFIG="$CONFIG" --dry-run=client -o yaml
  | kubectl apply -f -` — piped, never through a temp file, never
  echoed, masked under `GITHUB_ACTIONS`, same convention as every other
  Hetzner credential write. The decrypted value holds the join token and
  is never logged, and the one encode is what keeps the render
  byte-identical to the fixed worker's.
- Because the node template is the Terraform render rather than something
  this spec composes, an autoscaled node cannot drift from the fixed
  worker: same k3s version, same flags, same reservations, same token. A
  `make up` that re-renders the worker template re-runs `argo-up`, which
  refreshes this Secret, so the two never diverge across a cycle.
- Teardown. `argo-down`'s cascade (HETZ-047, unchanged by this spec)
  deletes the autoscaler Application like every other child; no bespoke
  wait is added for it. What guarantees no autoscaled server survives
  `cluster-down` is `cluster-down`'s pre-destroy sweep (HETZ-040,
  unchanged by this spec), which deletes any `managed_by=autoscaler`
  server still present — one that never had time to scale down, or one
  the autoscaler crashed before removing — before `terragrunt destroy`,
  because the firewall and subnet destroy hangs on an attached server
  otherwise.
- Observability: a ServiceMonitor for the autoscaler pod, gated on
  `hetzner`, added to the same Application (HETZ-160 wires the
  Prometheus/Grafana side).

## 5. Files/components affected

`gitops/templates/platform/hetzner/autoscaler/*.yaml` (new),
`gitops/values.yaml`, `scripts/argo-up.sh` (`ensure_autoscaler_config`),
`scripts/lib/versions.sh` (`CLUSTER_AUTOSCALER_VERSION`). No change to
`scripts/cluster-down.sh` or HETZ-040's spec — the existing label sweep
already covers autoscaler-created servers.

## 6. Implementation steps

1. Pin `CLUSTER_AUTOSCALER_VERSION` to the cluster's Kubernetes minor; add
   `ensure_autoscaler_config()` right after `wait_for_nodes_initialized()`;
   add the Argo Application and its Secret env wiring. `make gitops-check`
   golden diff empty.
2. `PROVIDER=hetzner make up` on the HETZ-045 baseline. Confirm
   `hcloud-autoscaler-config` exists with the `HCLOUD_CLUSTER_CONFIG` key
   and the autoscaler pod is Ready, logging a `workers` node group with 0
   nodes.
3. Burst test: a Deployment sized to overflow the one fixed worker.
   Observe 0→2 scale-up within 5 minutes (timed); both new nodes Ready
   with `providerID` set; `hcloud server list -l managed_by=autoscaler`
   shows two.
4. Delete the Deployment. Observe both nodes deleted within 10 minutes of
   the pods clearing (timed), matching `--scale-down-unneeded-time=10m`.
5. Repeat step 3, then run `make down` with both autoscaled nodes present.
   Confirm `cluster-down`'s sweep deletes both autoscaled servers and
   reports zero leaks, `terragrunt destroy` does not hang, and a
   following `terragrunt plan` shows no drift.

## 7. Dependencies and blockers

HETZ-030 (the `worker_user_data` SSM `SecureString` this spec's Secret
copies, and the node-shape decision) and HETZ-045 (`argo-up` placement,
`wait_for_nodes_initialized`, the in-cluster Hetzner token Secret).
Transitively: HETZ-040 (the Ready, flannel-networked fixed pool and the
label sweep that reaps autoscaled servers at teardown).

## 8. Acceptance criteria

- A burst of pending pods scales the pool 0→2 within 5 minutes, timed;
  both new nodes reach `Ready` with `spec.providerID` set.
- 10 minutes after the pending pods are removed, both nodes are gone,
  timed.
- `make down` with two autoscaled nodes present completes; the sweep
  reports zero leaks.
- No Terraform drift on `cluster-hetzner` at any point in the test.

## 9. Validation

Offline: `make gitops-check`, `shellcheck` on `argo-up.sh`. Real cloud:
the burst-and-teardown test in §6, about 0.20 EUR (up to four `cx33` for
under an hour).

## 10. AWS regression protection

Not applicable: every changed file is hetzner-only. Civo: `make
gitops-check` golden diff empty; no shared file changes.

## 11. Rollout and rollback/recovery

Remove the Application; the autoscaler deletes its own nodes on
scale-down first. If it is removed while nodes still exist, HETZ-040's
sweep reaps them at the next `cluster-down`.

## 12. Risks and unresolved questions

- A scale-up burst can consume a large share of the 3600/h Hetzner API
  rate limit; watch `RateLimit-Remaining` in the autoscaler's own request
  log during the burst test.
- The 5-server default limit: 1 fixed control plane + 1 fixed worker + 2
  autoscaled is exactly 4, one under the default — leaving no room for a
  second concurrent cluster (CI's own count is HETZ-140's problem, not
  this spec's).
- Version drift: the node template comes from the SSM parameter Terraform
  wrote at the last `apply`, not from the checkout, so an autoscaled node
  always matches the fixed pool that is actually running. A `K3S_VERSION`
  change in `scripts/lib/versions.sh` reaches neither until a `make down`
  then `make up` re-renders and re-publishes it, which is the intended
  behaviour for a disposable cluster rather than a drift hazard.
- A node that joins but never gets `providerID` — most likely a render
  missing `--kubelet-arg=cloud-provider=external` — never
  clears the CCM's `uninitialized` taint or becomes schedulable; the
  autoscaler deletes it itself once `--max-node-provision-time` elapses,
  so no manual sweep is needed for that case.
- The cluster-autoscaler chart pin and `K3S_VERSION` must move together
  (§3). A bump of one alone leaves the autoscaler on a different minor than
  the cluster.
- `HCLOUD_CLUSTER_CONFIG` carries the join token inside the node template,
  so the Secret has the same blast radius as the node's own instance
  metadata — the exposure ADR 0037 already records, not a new one.
- The `worker_user_data` SSM read is the only place `argo-up` decrypts a
  `SecureString` on this target; a missing `kms:Decrypt` on the lab role
  fails here and nowhere else.

## 13. Definition of done

- [ ] Scale 0→1 and 1→0 evidence recorded with timings
- [ ] Teardown-with-a-node-present evidence recorded; HETZ-040's sweep
      confirmed to delete every autoscaled server before `terragrunt
      destroy`
- [x] Index updated; status `DONE`

## 13a. Evidence, as measured

| Criterion | Result |
|---|---|
| `make gitops-check` | pass — the hetzner structural set now demands the Application and the ServiceMonitor, and both were watched failing before the templates existed |
| `make scripts-check` (shellcheck `-S warning`, 7 suites) | pass |
| `node-ready-test.sh`, 5 cases | pass — the autoscaled-node case was watched failing against the old equality first |
| `autoscaler-config-test.sh`, 9 cases | pass — a wrong `scope` label and a double-encoded cloud-init were both watched failing first |
| The rendered node group | exactly one `--nodes=0:1:CX33:FSN1:workers`, from `autoscalingGroups`; `image.tag` is `v1.36.1` |
| `HCLOUD_CLUSTER_CONFIG` shape | all five `serverLabels` present; a multi-line fixture with an embedded tab round-trips byte-identical, so it is encoded exactly once. Proved against that fixture, not against the real SSM parameter, which needs a live stack |
| The Application is hetzner-only | absent from the `aws`, `civo` and `local` renders |
| The aws golden | four new root parameters with empty values, eight lines, one file |

**Outstanding, pending a live run.** Every remaining criterion needs a real
bring-up, and none of them can be reached offline.

| Criterion | Status |
|---|---|
| A burst of pending pods scales 0→1 within 5 minutes, timed; the node reaches `Ready` with `spec.providerID` set | outstanding |
| 1→0 within 10 minutes of the pods clearing, timed | outstanding |
| `make down` with the autoscaled node present completes and the sweep reports zero leaks | outstanding |
| No Terraform drift on `cluster-hetzner` at any point | outstanding |

### The five corrections to §4

1. **`scripts/lib/versions.sh` does not exist and never did.** There is no
   `CLUSTER_AUTOSCALER_VERSION` to set and no `K3S_VERSION` shell variable.
   The chart pin is the Application's `targetRevision`, as CIVO-170 already
   does it; the k3s pin is `hcloud-nodes/variables.tf`'s `k3s_version`.
2. **There is no fast-path return after `wait_for_nodes_initialized()`.** The
   fast path exits at `argo-up.sh:435`, and that function is called at `:536`.
   `ensure_autoscaler_config()` placed as §4 asks would never run on a re-run.
   It sits above the guard beside `ensure_ca_secret`, which is there for the
   same reason.
3. **The group is `0:1` at `FSN1`, not `0:2` at `NBG1`.** §3 reasoned the
   ceiling from a fixed pool of two; the shipped default is `NODE_COUNT=3`, so
   `0:2` would put the ceiling at five — exactly the per-project server limit,
   with no headroom for a create that races a delete. `fsn1` is the default
   location at all four layers, and the type and location now come from the
   `NODE_TYPE` and `REGION` operator inputs rather than being literals.
4. **The node group is declared through `autoscalingGroups`, not a raw
   `--nodes` argument.** For this cloud provider the chart renders
   `--nodes={min}:{max}:{instanceType}:{region}:{name}` from that list
   (`templates/deployment.yaml:73-81`), which is also what disposes of §4's
   worry about a second `--nodes` flag.
5. **`image.tag` has to be pinned.** Chart 9.59.0's `appVersion` is `1.35.0`,
   and so is every chart back to 9.54.0, against a 1.36 cluster. `v1.36.1` is
   published and `v1.37.x` is not, which is the same fact the k3s pin cites.

### Two things §4 asks for that are not built, and why

**`HCLOUD_FIREWALL` is deliberately unset.** §4 lists it among the plain
`extraEnv` ids. The provider uses it at server create
(`hetzner_node_group.go:506-509`, `opts.Firewalls`), which adds a *resource*
entry to a firewall whose `apply_to` Terraform owns as a *label selector* —
drift on `cluster-hetzner` at the next plan, against this spec's own fourth
acceptance criterion. It buys nothing either: `hcloud-firewall/main.tf:36-38`
says the selector exists precisely so an autoscaled node is covered, the
node's labels are set in the same create call, and a node given a
`subnetIPRange` is created powered off and attached to the network before it
boots. Its SSM name and its Helm value are not plumbed.

**`defaultSubnetIPRange` is set, which §4 does not mention.** Left unset the
node takes the hcloud default, which is only unambiguous while the network
holds one subnet. Setting it also has the provider create the server powered
off and attach the network first, so an autoscaled node never runs the NIC
race the fixed workers' cloud-init works around.

One smaller amendment: §3 lists `serverLabels` beside `imagesForArch` and
`nodeConfigs`, which reads as a top-level key. The provider's schema puts it
**inside** `nodeConfigs.<pool>`, and that is where it is written.

One implementation note §4 could not have anticipated: the worker cloud-init
is read with its own `get-parameter` call rather than through the batch.
`--output text` writes a value's newlines literally and the batch reads one
tab-separated pair per line, so a multi-line cloud-init would arrive truncated
at its first line and every pair after it would be misread. Verified by
running that loop against a multi-line value.

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT at P3/M2, mirroring CIVO-170's placement.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — moved to P1/M1 and re-shaped to 0–1 `cx33`: the third node of the chosen shape (decisions.md §3) is autoscaled, so M1 needs this spec.
- 2026-09-19 — rewritten for kubeadm join via HETZ-165; 0–2 workers, ceiling 4 nodes.
- 2026-09-23 — implemented. Offline evidence below; the four live criteria in
  §8 stay outstanding, which the status protocol allows.
- 2026-09-23 — **five corrections to §4, found by checking it against the
  repository and the chart rather than against itself.**
- 2026-09-20 — k3s (HETZ-017, ADR 0037). HETZ-165 is retired, so the node
  template is no longer composed in-cluster from a minted token and a CA
  hash: `ensure_autoscaler_config()` reads HETZ-030's `worker_user_data`
  SSM `SecureString` and uses that render as it stands, which makes an
  autoscaled node identical to the fixed worker by construction.
  `depends_on` moves from HETZ-165 to HETZ-030 and HETZ-045. The
  Application, the `--nodes=0:2:CX33:NBG1:workers` group, the two-Secret env
  wiring, the ceiling of four and the teardown ordering are unchanged. The
  1.37-tag note goes with HETZ-185.
