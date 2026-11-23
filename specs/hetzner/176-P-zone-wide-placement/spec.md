---
id: "HETZ-176"
title: "REGION is a network zone; servers and autoscaled workers fall back across its locations"
status: "READY"
priority: "P1"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Renames the state bucket namespace, rewrites the region guard and adds a retrying apply; the judgement is in the teardown order and in what a retry must not change"
effort_estimate: "Two sessions (part A 2–3 h, part B 4–6 h), plus a live full-down → full-up of about 1 h"
estimate_confidence: "medium"
depends_on: ["HETZ-170", "HETZ-178", "HETZ-200", "SHARED-044"]
blocked_by: []
supersedes: []
created: "2026-11-23"
updated: "2026-11-23"
completed: ""
---

# HETZ-176 — Zone-wide placement

## 1. Outcome and rationale

On Hetzner, `REGION` names a network zone (`eu-central`), not one location.
The operator sets only `REGION`. The platform places the control plane, the
fixed workers and the autoscaled workers in any location of that zone
(`fsn1`, `nbg1`, `hel1`). When one location is out of stock, the next one is
tried. Every name that was keyed by the location is keyed by the zone.

Why: on 2026-11-23 a create of `cx33` and of `cx43` in fsn1 both returned
`resource_unavailable`, while the lab's only worker (a `cx33`, fsn1) sat at
88% memory. The autoscaler's one group is `0:1:CX33:FSN1:workers`, so it
cannot add capacity until fsn1 restocks. nbg1 and hel1 are in the same
private network zone and a node there can join the cluster today; only the
configuration prevents it.

Hetzner terms, because the platform's name for them is misleading:

| Hetzner | Example | Today's platform name | After this spec |
|---|---|---|---|
| Network zone | `eu-central` | `HCLOUD_NETWORK_ZONE` (`region.sh:42`, unread), `network_zone` (Terraform default) | `REGION` |
| Location | `fsn1`, `nbg1`, `hel1` | `REGION` | chosen by the platform; `HCLOUD_LOCATION` is the location of one apply attempt |
| Datacenter | `fsn1-dc14` | — | not selectable since 2025-12-16 |

## 2. Scope and non-goals

In scope, Hetzner only:

- Part A (PR 1, stands alone): one autoscaler node group per location that
  sells the worker type, `REGION` location first, with a total node cap.
- Part B (PR 2): `REGION` becomes the network zone. The state bucket, the
  backup bucket and the rolesanywhere bucket ARN are keyed by the zone. The
  load balancer is placed by network zone. The control plane and the fixed
  workers fall back across locations through a new apply wrapper.
- ADR 0047 recording the changed meaning of `REGION` on Hetzner.

Not in scope:

- Civo and AWS. Their `REGION` keeps its meaning and code path.
- A `HOME_LOCATION` input. The operator never names a location (decided
  2026-11-23).
- Migrating the live lab's state. The live lab is moved by `make full-down`
  on the old code and `make full-up` on the new code (§11). Its Postgres
  data, barman backups and Cognito users are not kept (accepted 2026-11-23).
- Server-type fallback (`cx33` → `cpx32`). HETZ-175 keeps it; it can extend
  the wrapper from §4.6.
- Zones other than `eu-central`. They are refused until create probes prove
  what they sell (the platform's rule: only a real create is proof).
- Moving a volume between locations. Hetzner volumes cannot move.
- The control plane's type: it stays one `cx23`, tainted (HETZ-178).

## 3. Current state / evidence

Live lab, 2026-11-23:

- `vk-hetzner-lab-cp-1`: `cx23`, `fsn1-dc14`. `vk-hetzner-lab-worker-1`:
  `cx33`, `fsn1-dc14` (set by a command-line `WORKER_NODE_TYPE`; the fsn1
  default is `cx43`).
- Worker memory: 4712 Mi of 5915 Mi allocatable requested (79%), 5232 Mi used
  (88%). Argo's seven workloads declare no requests (SHARED-048).
- Autoscaler args: `--nodes=0:1:CX33:FSN1:workers`; log "No unschedulable
  pods".
- `hcloud location list`: `fsn1`, `nbg1`, `hel1` are network zone
  `eu-central`; `ash` is `us-east`, `hil` is `us-west`, `sin` is
  `ap-southeast`.
- State bucket `vk-hetzner-lab-fsn1-tf-state` holds `bootstrap/route53`,
  `bootstrap/rolesanywhere`, `persistent/{secrets,backups,ahorro-cognito}`,
  `persistent-hetzner/{network,ssh-key}`, `cluster-hetzner/{firewall,k8s}`
  and `state/`. Backup bucket `vk-hetzner-lab-fsn1-postgres-backups`.

Create probes, fsn1, 2026-11-23 (server created stopped, IPv6 only, deleted
at once):

| Type | Result |
|---|---|
| `cx43` | `resource_unavailable` |
| `cx33` | `resource_unavailable` |
| `cx23` | created |

`server_types[].locations[].available` read `false` for `cx23`, `cx33`,
`cx43` and `cx53` in all three locations the same day, and `cx23` created.
The flag stays unusable as a pre-flight (HETZ-175 §3). `GET /v1/datacenters`
now returns `deprecated_api_endpoint`.

Error texts (HETZ-175 §3): `resource_unavailable` is a temporary shortage
(cx43 in nbg1 became orderable 20 minutes later on 2026-09-22).
`unsupported location for server type` (code `invalid_input`) means the type
is withdrawn from that location. `invalid_input` alone is generic (a bad
image or IP gives it too) and is not a location signal.

Code facts verified for this spec (worktree at `121840e`):

- Cluster autoscaler: chart `9.59.0`, image `v1.36.1`. The chart renders each
  `autoscalingGroups` entry as `--nodes=min:max:TYPE:LOCATION:name`; the
  hcloud provider creates the server in that group's location.
- `HCLOUD_CLUSTER_CONFIG` reaches the pod by `envFrom` of Secret
  `hcloud-autoscaler-config`, written by `argo-up.sh` `ensure_autoscaler_config`.
  The provider calls `klog.Fatalf` when a `--nodes` group has no
  `nodeConfigs` key, or when `nodeConfigs` is empty.
- `--max-nodes-total` counts every node in the cluster, including the control
  plane and the fixed workers (`static_autoscaler.go` builds the count from
  all nodes; nothing excludes the control plane).
- Chart 9.59.0 renders ConfigMap `cluster-autoscaler-priority-expander` and
  its RBAC only when `extraArgs.expander` contains `priority` and
  `expanderPriorities` is set.
- The provider's node template already sets `csi.hetzner.cloud/location` to
  the group's location. A pod bound to a volume therefore only triggers the
  group in that volume's location. No repo change is needed for this.
- hcloud provider `1.69.0`: `hcloud_server.location` is ForceNew;
  `server_type` is updated in place (power-off resize);
  `hcloud_network_subnet.network_zone` is ForceNew.
- The Hetzner apply is one inline command at `Makefile:244`; `park.sh:75-80`
  `terragrunt_apply` is a second path. Nothing parses `resource_unavailable`.
- `region.sh:52` does not lowercase the Hetzner name, while `root.hcl`
  does, so `REGION=FSN1` gives a script one bucket name and Terraform another.
- The TLS certificate survives teardown in SSM
  (`/<project>/persistent/hetzner/tls/platform-public`, written by
  `argo-down`, not deleted by `persistent-down`), so a `full-up` imports it
  and orders no new certificate.

## 4. Design and contracts

### 4.1 Zone and locations

`catalog.sh`:

- `catalog_regions hetzner` → `eu-central`.
- New `catalog_zone_locations eu-central` → `fsn1 nbg1 hel1`. This order is
  the placement order everywhere: the apply wrapper, the autoscaler groups and
  the expander priorities. fsn1 stays first because every real cycle has run
  there.
- The per-location type lists stay (hel1 does not sell `cx43`), renamed
  `catalog_location_node_types`. `catalog_node_types hetzner eu-central` is
  the union of its locations' lists, so a type is valid for a zone when at
  least one location sells it.
- `catalog_default_region hetzner` → `eu-central`. The default worker type
  for `eu-central` stays `cx43`.
- New `catalog_locations_selling <zone> <type>`: the zone's locations, in
  order, whose list contains the type. Both the wrapper and the autoscaler
  read it.

`REGION=fsn1` (or any location) is refused by `require-valid-node-config.sh`
with: `REGION is a network zone on hetzner; fsn1 is a location in
eu-central - use REGION=eu-central`. Zones other than `eu-central` are
refused with the existing "not valid" message.

### 4.2 Names keyed by the zone

- `root.hcl`: `provider_region` on Hetzner is `lower(REGION)` with default
  `eu-central`. The state bucket becomes `<project>-eu-central-tf-state`,
  the backup bucket `<project>-eu-central-postgres-backups`, and the
  rolesanywhere bucket ARN follows (`persistent/backups/terragrunt.hcl:13`,
  `bootstrap/rolesanywhere/terragrunt.hcl:40` read the same local).
- `region.sh`: on Hetzner `LAB_PROVIDER_REGION` is the lowercased zone. The
  lowercase fix applies to every script that rebuilds a bucket name
  (`state-up`, `state-down`, `status`, `require-persistent`,
  `require-unique-subdomain`, `bootstrap-down`, `account-down`,
  `persistent-down`, `verify-no-leaks`); they need no other change.
  `HCLOUD_NETWORK_ZONE` is the zone. `HCLOUD_LOCATION` is no longer derived
  from `REGION`.
- `persistent-hetzner/network/terragrunt.hcl` passes `network_zone =
  lower(REGION)`. The value is `eu-central`, as today.

### 4.3 Load balancer

`gitops/templates/_helpers.tpl:133` changes from
`load-balancer.hetzner.cloud/location` to
`load-balancer.hetzner.cloud/network-zone`, fed by `envoyGateway.networkZone`
(renamed from `envoyGateway.location` in `gitops/values.yaml`,
`gitops/bootstrap/values.yaml`, `root-application.yaml` and `argo-up.sh:902`).
The two annotations are mutually exclusive and immutable; the switch is safe
only because the live lab is recreated (§11).

### 4.4 Control plane and fixed workers

- `hcloud-nodes` keeps one `location` variable. It is the location for a
  *new* server only.
- Both server resources add `location` to `lifecycle.ignore_changes`
  (`main.tf:72-73` control plane, `:110-111` worker). An existing server never
  moves and is never replaced because the variable changed.
- `cluster-hetzner/k8s/terragrunt.hcl:42` reads `get_env("HCLOUD_LOCATION",
  "fsn1")`, not `REGION`. `REGION` names the state bucket, so a retry that
  changed it would apply against a different, empty bucket. The default only
  serves plan and destroy, where `ignore_changes` makes it irrelevant.
- The worker template joins over the control plane's private IP and reads its
  own IPs from metadata, so it renders the same in any location.

### 4.5 Autoscaler

- One `autoscalingGroups` entry per location from `catalog_locations_selling
  <zone> <WORKER_NODE_TYPE>`, named `workers-<location>`, `minSize: 0`,
  `maxSize: MAX_WORKER_NODES - MIN_WORKER_NODES`.
- `argo-up.sh` builds the location list once. It passes it to Argo as one
  space-separated string, `capacity.autoscaler.locations` (renamed from
  `capacity.autoscaler.location`; Argo `parameters` carry only scalar
  strings, and `helm --set` splits on commas), and writes one `nodeConfigs`
  key per group from the same list. The template fails to render when the
  value is empty (`required`).
  Two lists built separately could disagree, and a missing key crashes the
  autoscaler.
- `extraArgs.expander: priority`; `expanderPriorities` gives the first
  location the highest number, with anchored patterns (`^workers-fsn1$`). A
  failed create puts that group in backoff and the next group is tried.
- `extraArgs.max-nodes-total: 1 + MAX_WORKER_NODES` (the control plane, the
  fixed workers and the autoscaled workers), passed as
  `capacity.autoscaler.maxNodesTotal`. This keeps the 5-server account cap
  shared with CI.
- Part A ships before Part B, while `REGION` is still a location. In Part A
  the list is `REGION` first, then the other catalog locations that sell the
  type. Part B replaces it with `catalog_locations_selling`.

### 4.6 Apply wrapper

A new function, `hetzner_apply`, in `scripts/lib/provider.sh` replaces the
inline apply at `Makefile:244` and `park.sh` `terragrunt_apply` on Hetzner.

- For each location of `catalog_locations_selling <zone> <WORKER_NODE_TYPE>`
  that also sells `CONTROL_PLANE_NODE_TYPE`, in order: export
  `HCLOUD_LOCATION`, run `terragrunt run --all --non-interactive -- apply
  -auto-approve` under `cluster-hetzner`, and keep a copy of the output.
- Success: stop.
- Output contains `resource_unavailable` or `unsupported location for server
  type`: try the next location. Servers created by an earlier attempt stay
  where they are (`ignore_changes`), so the control plane can be in fsn1 and
  a worker in nbg1.
- Any other failure: stop at once with the apply's exit code.
- Every location failed: stop, print each location with its error text, and
  suggest another `WORKER_NODE_TYPE`.
- To verify at implementation: whether a failed create leaves a tainted
  server in state. If it does, the next attempt replaces it, which is
  correct.

### 4.7 The region-change guard

`state-up.sh:41-64` keeps refusing when another bucket of this project holds
objects. Its candidates are each zone from `catalog_regions` and, for Hetzner,
each legacy location name from `catalog_zone_locations` (`<project>-fsn1-tf-state`
and the rest). The legacy check keeps today's rule (more than 0 objects), not
"bucket exists". Its message names the fix: `make full-down` from a checkout
before HETZ-176 (the new code cannot name a `-fsn1-` bucket).

### 4.8 Volumes

A volume stays in the location where it was created. A fresh cluster creates
the Postgres, Loki and Prometheus volumes where their pods first land
(`WaitForFirstConsumer`, set by the hcloud-csi chart). `make down` deletes
them (`reclaimPolicy: Delete`); only park keeps them. On unpark the worker can
land in fsn1 while the volumes are in nbg1; those pods then wait for an
autoscaled nbg1 node. Accepted risk (§12).

## 5. Files/components affected

Paths relative to the repository root, lines at `121840e`.

Part A:

- `gitops/templates/platform/hetzner/autoscaler/application.yaml:32-37`
  (one group → a range over the split list), `:58-64` (extraArgs: expander,
  `max-nodes-total`), new `expanderPriorities`.
- `scripts/argo-up.sh:432-461` (`ensure_autoscaler_config`, `nodeConfigs`
  per location), `:903-907` (`capacity.autoscaler.*`).
- `gitops/values.yaml:28-34`, `gitops/bootstrap/values.yaml:31-38`,
  `gitops/bootstrap/templates/root-application.yaml:34-45`
  (`location` → `locations`, new `maxNodesTotal`).
- `tests/golden/gitops-aws/bootstrap/Application__argocd__root.yaml:34-45`
  (parameter names only; regenerate with `scripts/gitops-render-check.sh update`).
- `scripts/gitops-render-check.sh`: a Hetzner `assert_helm_values` on
  `cluster-autoscaler` (groups, expander, cap), on the pattern used for
  `local` at `:242-255`.
- `tests/scripts/autoscaler-config-test.sh`: `workers` is hard-coded at
  `:69, 71, 73, 75, 77, 79, 85`; keys must equal the location list.
- `.github/workflows/lifecycle-test.yml:295-299`: the hetzner `helm template`
  sets the new required values.

Part B:

- `Makefile:55` (`REGION ?= eu-central` on Hetzner), comments `:56-59`, help
  `:404`, `:475`; `:244` (cluster-up calls the wrapper).
- `scripts/lib/catalog.sh:70-93` (comments), `:104`, `:115-117`, `:126`,
  `:138-139`, new functions (§4.1).
- `scripts/lib/region.sh:31-35`, `:42`, `:52`.
- `scripts/lib/provider.sh:56-75` (derivations from `REGION`), new
  `hetzner_apply`.
- `scripts/lib/require-valid-node-config.sh:19-24`, `:41-69`, `:73-81`.
- `terraform/live/root.hcl:16-21`, `:49-51`, `:80-82`.
- `terraform/live/cluster-hetzner/k8s/terragrunt.hcl:42`.
- `terraform/modules/hcloud-nodes/main.tf:72-73`, `:110-111`;
  `variables.tf:43-47` (description).
- `terraform/live/persistent-hetzner/network/terragrunt.hcl` (`network_zone`).
- `scripts/state-up.sh:41-64` (guard, message at `:62`).
- `scripts/argo-up.sh:902` (`envoyGateway.networkZone`), `:259-260`,
  `:890-891` (comments); `gitops/templates/_helpers.tpl:131-133`;
  `gitops/values.yaml:166`, `gitops/bootstrap/values.yaml:46`,
  `root-application.yaml:56-57`; the aws golden again.
- `scripts/park.sh:75-80`; `scripts/clusters.sh:179` (unchanged; shows the
  first server's location).
- CI: `.github/workflows/lab.yml:67-73` (region input comment);
  `lifecycle-test.yml:298` (`envoyGateway.networkZone=eu-central`).
- Tests: `tests/scripts/node-config-test.sh:65-68`, `:104-109`, `:150-157`,
  `:199-225` (the lab.yml dropdown is built from zones × types);
  `park-test.sh:157`; `clusters-test.sh:46-55`, `:133`;
  `recover-from-test.sh:14`, `:39-69`; new `hetzner-apply-test.sh` with a
  stubbed `terragrunt`.
- Docs: `CLAUDE.md:154`; `README.md:167`, `:198-203`, `:233`, `:321`,
  `:513-525`; `specs/hetzner/architecture.md:58-59`, `:97`;
  `specs/shared/044-D-node-and-region-inputs/spec.md` (amendment);
  `docs/adr/0039-project-region-as-operator-input.md` (pointer);
  `scripts/require-valid-recover-from.sh:64` (help text).
- New: `docs/adr/0047-hetzner-region-is-a-network-zone.md`.

## 6. Implementation steps

Part A (PR 1):

1. Autoscaler template: groups from `capacity.autoscaler.locations`,
   priority expander, `max-nodes-total`. Check: the new Hetzner
   `assert_helm_values` in `make gitops-check`.
2. Values plumbing: `location` → `locations`, `maxNodesTotal`; regenerate the
   aws golden. Check: `make gitops-check` shows only the parameter lines.
3. `argo-up.sh`: one list, `REGION` first; one `nodeConfigs` key per
   location. Check: `autoscaler-config-test.sh`.
4. Spec to `IN_PROGRESS` in this PR. Live (§11 PR 1) after the merge.

Part B (PR 2):

5. ADR 0047 and the SHARED-044 amendment.
6. `catalog.sh`, `region.sh`, `provider.sh`, `require-valid-node-config.sh`:
   zone input, location functions, refusal message, lowercase fix. Check:
   `node-config-test.sh`.
7. `root.hcl`, `persistent-hetzner/network`: names from the zone. Check: the
   computed bucket name is `<project>-eu-central-tf-state`.
8. `state-up.sh` guard: zones plus legacy locations. Check: a test with
   stubbed `aws` (AC4).
9. `hcloud-nodes` `ignore_changes`, k8s unit reads `HCLOUD_LOCATION`. Check:
   `terraform validate`.
10. `hetzner_apply`, called from `Makefile:244` and `park.sh`. Check:
    `hetzner-apply-test.sh` (fails once with `resource_unavailable`, then
    succeeds in the second location; skips on `unsupported location`; stops
    on another error).
11. Autoscaler list from `catalog_locations_selling`; load balancer
    annotation; CI, docs. Spec to `DONE` in this PR.
12. Live (§11 PR 2).

## 7. Dependencies and blockers

- HETZ-170 (autoscaler), HETZ-178 (control plane), HETZ-200 (park),
  SHARED-044 (region inputs) are DONE.
- HETZ-175 is READY and independent. Its §4 pre-flight on the `available`
  flag is disproven and MUST NOT be reused here. If it lands later, it adds
  type fallback to `hetzner_apply`.
- SHARED-045 (one project, two regions) is unaffected: a project still has one
  zone.

## 8. Acceptance criteria

- AC1. `make full-up` with the default `REGION` creates
  `<project>-eu-central-tf-state` and `<project>-eu-central-postgres-backups`;
  the rolesanywhere policy names the new backup bucket.
- AC2. The Envoy Gateway Service carries
  `load-balancer.hetzner.cloud/network-zone: eu-central` and no `location`
  annotation; the lab hosts answer over TLS.
- AC3. The autoscaler runs one `--nodes` per location that sells the worker
  type, the priority ConfigMap orders them `fsn1`, `nbg1`, `hel1`, and
  `--max-nodes-total` is `1 + MAX_WORKER_NODES`.
- AC4. With `<project>-fsn1-tf-state` holding objects, `make state-up` (and so
  `make full-up`) is refused by the guard with the §4.7 message.
- AC5. With fsn1 out of stock for the worker type, a Pending pod
  with no volume gets a node in another location within
  `max-node-provision-time`. Recorded as outstanding if no stock-out occurs
  during the live run; the expander config from AC3 is the evidence then.
- AC6. `hetzner-apply-test.sh` proves the fallback, skip and stop rules. On the
  live run, the wrapper's log shows which location each attempt used.
- AC7. `REGION=fsn1` is refused with the §4.1 message; `REGION=us-east` is
  refused as not valid.
- AC8. After AC1–AC3, `make down` then `make up` succeeds and
  `make verify-no-leaks` passes.
- AC9. Civo and AWS: `make gitops-check` (the aws golden differs only in the
  renamed parameters), `node-config-test.sh` and lifecycle CI unchanged.

## 9. Validation

`make specs-check`, `make gitops-check`, `tests/scripts/*-test.sh`,
`terraform fmt`/`validate`, the Hetzner lifecycle CI job on PR 2
(`ci:lifecycle-hetzner`), and the live checks in §11.

## 10. AWS regression protection

AWS refuses `REGION` today (`require-valid-node-config.sh:49-53`); that stays.
AWS behavior MUST NOT change. The aws golden changes only in the bootstrap
`root` Application's parameter names (`capacity.autoscaler.locations`,
`capacity.autoscaler.maxNodesTotal`, `envoyGateway.networkZone`); any other
golden diff is a regression.

## 11. Rollout and rollback/recovery

PR 1 (Part A), on the live lab, which keeps running:

1. Label `ci:lifecycle-hetzner`: CI runs a fresh cycle with the new
   autoscaler config.
2. Check that no autoscaled server exists:
   `hcloud server list -l managed_by=autoscaler`. A server in the old
   `workers` group would be outside every new group.
3. Merge PR 1. The live root Application tracks main; it now fails to render
   (`capacity.autoscaler.locations` is required and the live root does not
   pass it), so it leaves `Synced/Healthy`. Nothing is deleted.
4. `PROJECT_NAME=vk-hetzner-lab WORKER_NODE_TYPE=cx33 make argo-up`. The root
   is not `Synced/Healthy`, so argo-up skips its fast path and installs the
   root with the new parameters. Before the merge a re-run takes the fast
   path and changes nothing, so the live check follows the merge.
5. Check the autoscaler args and the priority ConfigMap (AC3).

A full `make down` → `make up` is not run for PR 1: it has no server
fallback, and on 2026-11-23 fsn1 refused `cx33` and `cx43`.

PR 2 (Part B):

1. Label `ci:lifecycle-hetzner`: CI runs a fresh `full-up` → `full-down` with
   the new code and its own project.
2. From main, before the merge (old code, `REGION` default `fsn1`):
   `PROJECT_NAME=vk-hetzner-lab CONFIRM_DESTROY=vk-hetzner-lab make full-down`.
3. Check that nothing of the project remains: `hcloud server list`,
   `hcloud load-balancer list`, `hcloud volume list`, `hcloud network list`,
   `aws s3 ls | grep vk-hetzner-lab`.
4. Merge PR 2.
5. From main: `PROJECT_NAME=vk-hetzner-lab make full-up`. If every location
   refuses the worker type, run again with `WORKER_NODE_TYPE=cx33` or
   `cpx32`.
6. AC1–AC3, then AC8.

The lab is down between steps 2 and 5, about 1 hour. Nothing exists then, so
old and new code never see each other's buckets.

Effects of the full-down accepted on 2026-11-23:

- The `lab.<root-domain>` zone gets new name servers. A resolver that cached
  the old ones (delegation TTL `172800`) can fail to resolve the lab names for
  up to 48 h. The TLS certificate is imported from SSM, so no ACME order
  depends on the new zone.
- Postgres data, barman backups and Cognito users are lost. The Cognito pool
  gets a new ID; vk-ahorro reads it from SSM, and a mobile build needs
  `make ui-config` again.
- Passwords, LLM secrets, the SSH key and the rolesanywhere CA come back with
  the same values from their `.enc` files.

Rollback: PR 1 — revert, then `make argo-up` (the root fails to render
until then, as in PR 1 step 3). PR 2 — after step 2 the
old code can `make full-up` again from a revert; before step 2 nothing outside
Git has changed.

## 12. Risks and decisions

Decided 2026-11-23:

| Question | Decision |
|---|---|
| `REGION=fsn1` after Part B | refuse, naming `REGION=eu-central` |
| A `HOME_LOCATION` input | none; the operator sets only `REGION` |
| Bucket names | keyed by the zone (`-eu-central-`); the live lab is recreated, not migrated |
| Load balancer placement | `network-zone` annotation |
| Zones other than `eu-central` | refused until probed |
| Does `--max-nodes-total` count the control plane? | yes, every node; cap is `1 + MAX_WORKER_NODES` |
| Priority expander key in chart 9.59.0 | `expanderPriorities`, with `extraArgs.expander: priority` |

Accepted risks:

- On unpark, the worker can land away from the retained volumes; those pods
  wait for an autoscaled node in the volumes' location (§4.8).
- A worker in hel1 is about 25 ms from a control plane or load balancer in
  fsn1.
- Up to 48 h of stale DNS after the full-down (§11).

## 13. Definition of done

- [ ] AC1–AC9 met and recorded (AC5 may be outstanding, §8)
- [ ] ADR 0047 Accepted; SHARED-044 amended
- [ ] Index updated; status `DONE` in PR 2

## 14. Execution evidence and status history

- 2026-11-23 — created as DRAFT from the CORE-230 capacity work in
  `vk-llm-on-demand`. Evidence in §3.
- 2026-11-23 — design reviewed against the code; `HOME_LOCATION` dropped,
  buckets keyed by the zone, live lab recreated by full-down → full-up,
  autoscaler cap corrected. Status READY.
