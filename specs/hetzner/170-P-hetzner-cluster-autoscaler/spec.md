---
id: "HETZ-170"
title: "Cluster autoscaler with cloudProvider hetzner: zero to two extra cx33 workers joined by kubeadm"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "A Secret-fed cluster config assembled across three scripts, an env-var wiring split between two Secrets, and a teardown-ordering dependency on two other specs need careful reasoning"
effort_estimate: "One session (4–6 h) plus scaling waits"
estimate_confidence: "medium"
depends_on: ["HETZ-165"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-19"
completed: ""
---

# HETZ-170 — Cluster autoscaler on Hetzner

## 1. Outcome and rationale

The upstream cluster autoscaler with `cloudProvider: hetzner` adds up to
two `cx33` workers when pods stay pending and removes each one after 10
minutes of sustained underutilisation. The fixed pool from HETZ-030 (one
control plane, one worker) stays; the autoscaler only adds, so the node
ceiling is four. Idle cost is unchanged, and a new node joins the cluster with `kubeadm
join` — HETZ-165 already produced that join credential (a bootstrap
token and CA hash); this spec only consumes it.

## 2. Scope and non-goals

In scope: the Argo Application, the node-group config, the cluster-config
Secret `argo-up` assembles from HETZ-165's Secret, the sweep and cascade
teardown interaction, a scale test. Not in scope: multiple node pools,
mixed CPU architectures, scaling the fixed pool down, an HA control plane
(decisions.md §3, Control-plane topology — the join line's target
`10.0.1.10:6443` is fixed), and the cluster-autoscaler 1.37 upgrade
(HETZ-185), which waits on an upstream tag that does not exist yet.

## 3. Current state / evidence

- HETZ-165 §4 writes `kube-system/hcloud-autoscaler` with keys `token`,
  `ca_hash`, `cloud_init` — the rendered `kubeadm join` cloud-init, whose
  `.data.cloud_init` field is the base64 encoding of that plaintext
  render, same as any Kubernetes Secret value. `cloud_init` already
  contains the token and hash inline; the Hetzner API token this spec
  also needs lives separately in `kube-system/hcloud` (HETZ-045),
  unchanged blast radius from decisions.md §3, "Autoscaler credential".
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
  the running cluster's Kubernetes minor; the newest tag is 1.36.1 and no
  1.37 tag exists yet, a second reason (with HETZ-030's containerd pin)
  that the cluster stays on 1.36 for M1.
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
  called immediately after HETZ-165's `ensure_autoscaler_secret()`,
  before the fast-path return. It reads `kube-system/hcloud-autoscaler`'s
  `cloud_init` key with `kubectl get secret ... -o
  jsonpath='{.data.cloud_init}'` and copies that value verbatim into
  `nodeConfigs.workers.cloudInit` — no decode/re-encode round trip,
  because both fields hold the same base64 encoding of the same
  plaintext render, which also avoids a trailing-newline hazard. It
  builds the rest of the JSON (`imagesForArch`, `serverLabels`) with
  `jq`, base64-encodes the whole object, and writes it with `kubectl
  create secret generic hcloud-autoscaler-config -n kube-system
  --from-literal=HCLOUD_CLUSTER_CONFIG="$CONFIG" --dry-run=client -o yaml
  | kubectl apply -f -` — piped, never through a temp file, never
  echoed, same convention as every other Hetzner credential write.
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

1. Pin `CLUSTER_AUTOSCALER_VERSION=1.36.1`; add `ensure_autoscaler_config()`
   right after `ensure_autoscaler_secret()`; add the Argo Application and
   its Secret env wiring. `make gitops-check` golden diff empty.
2. `PROVIDER=hetzner make up` on the HETZ-165 baseline. Confirm
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

HETZ-165 (the join token, CA hash and rendered cloud-init this spec's
Secret copies from). Transitively, through HETZ-165: HETZ-045 (`argo-up`
placement, `wait_for_nodes_initialized`, the `hcloud` Secret) and
HETZ-037/HETZ-035/HETZ-030 (the Ready, Cilium-networked fixed pool and
its node-shape decision).

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
- Kubelet version drift: if `scripts/lib/versions.sh`'s
  `KUBERNETES_VERSION` changes without a matching `make down`/`make up`
  on the fixed pool, an autoscaled node (built from the same
  `templates/node.yaml.tftpl` render that HETZ-165 §4 performs from the
  checkout) joins at a different minor than the control plane.
- A node that joins but never gets `providerID` — most likely a
  `KUBELET_EXTRA_ARGS` render missing `--cloud-provider=external` — never
  clears the CCM's `uninitialized` taint or becomes schedulable; the
  autoscaler deletes it itself once `--max-node-provision-time` elapses,
  so no manual sweep is needed for that case.
- No cluster-autoscaler 1.37 tag exists yet (§3); the 1.37 upgrade
  (HETZ-185) is blocked on that release, not on this spec.

## 13. Definition of done

- [ ] Scale 0→2 and 2→0 evidence recorded with timings
- [ ] Teardown-with-nodes-present evidence recorded; HETZ-040's sweep
      confirmed to delete every autoscaled server before `terragrunt
      destroy`
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT at P3/M2, mirroring CIVO-170's placement.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — moved to P1/M1 and re-shaped to 0–1 `cx33`: the third node of the chosen shape (decisions.md §3) is autoscaled, so M1 needs this spec.
- 2026-09-19 — rewritten for kubeadm join via HETZ-165; 0–2 workers, ceiling 4 nodes.
