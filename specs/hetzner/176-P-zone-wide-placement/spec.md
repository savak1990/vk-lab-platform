---
id: "HETZ-176"
title: "REGION is a network zone; servers and autoscaled workers fall back across its locations"
status: "DRAFT"
priority: "P1"
milestone: "M2"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "Touches state bucket naming, the region guard and a live cluster that must not be replaced; the judgement is in what must not change"
effort_estimate: "Two sessions (part A 2–3 h, part B 4–6 h)"
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
The control plane, the fixed workers and the autoscaled workers can each be
created in any location of that zone (`fsn1`, `nbg1`, `hel1`). When the first
location is out of stock, the next one is tried. The live cluster is adopted
with no server, load balancer, volume or bucket replaced.

Why: on 2026-11-23 a create of `cx33` and of `cx43` in fsn1 both returned
`resource_unavailable`, while the lab's only worker (a `cx33`, fsn1) sits at
88% memory. The autoscaler's one group is `0:1:CX33:FSN1:workers`, so it
cannot add capacity until fsn1 restocks. nbg1 and hel1 are in the same
private network zone and a node there can join the cluster today; only the
configuration prevents it.

Hetzner terms, because the platform's name for them is misleading:

| Hetzner | Example | Today's platform name | After this spec |
|---|---|---|---|
| Network zone | `eu-central` | (hardcoded, unnamed) | `REGION` |
| Location | `fsn1`, `nbg1`, `hel1` | `REGION` | `HOME_LOCATION` (one) and the fallback list |
| Datacenter | `fsn1-dc14` | — | not selectable since 2025-12-16 |

## 2. Scope and non-goals

In scope, Hetzner only:

- Part A (ships first, stands alone): one autoscaler node group per location
  of the zone, home location preferred, with a total cap.
- Part B: `REGION` becomes the network zone; a home location anchors the
  load balancer and the state and backup namespace; the control plane and
  fixed workers fall back across locations at create time.
- A new ADR recording the changed meaning of `REGION` on Hetzner.

Not in scope:

- Civo and AWS. Their `REGION` keeps its meaning and code path.
- Server-type fallback (`cx33` → `cpx32`). HETZ-175 keeps it. This spec owns
  location fallback only.
- Zones other than `eu-central`. They are refused until create probes
  prove what they sell (the platform's rule: only a real create is proof).
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

Error codes (HETZ-175 §3): `resource_unavailable` is a temporary shortage
(cx43 in nbg1 became orderable 20 minutes later on 2026-09-22).
`unsupported location for server type` (`invalid_input`) means the type is
withdrawn from that location.

## 4. Design and contracts

### 4.1 Home location

`HOME_LOCATION` is one location inside `REGION`. Default: the first entry of
the zone's location list in `catalog.sh` (`eu-central` → `fsn1`). It anchors
everything that cannot move:

- The state bucket and the Postgres backup bucket keep the pattern
  `<project>-<home>-...`. For the live lab that is the existing
  `-fsn1-tf-state` and `-fsn1-postgres-backups`: zero migration.
  `LAB_PROVIDER_REGION` becomes `HOME_LOCATION` on Hetzner.
- The load balancer keeps `load-balancer.hetzner.cloud/location: <home>`.
  It MUST NOT switch to the `network-zone` annotation: the two are mutually
  exclusive and the location annotation is immutable, so a switch recreates
  the load balancer with a new IP.
- The first location tried for every server, and the highest autoscaler
  priority.

### 4.2 Location list per zone

`catalog.sh` gains `catalog_zone_locations eu-central` → `fsn1 nbg1 hel1`,
home first. `catalog_node_types` stays keyed by location (hel1 does not sell
`cx43`). A type is valid for a zone when at least one location lists it. The
zone's default worker type is the location default of `HOME_LOCATION`.

### 4.3 Control plane and fixed workers

- `hcloud-nodes` takes `location` per server class: `control_plane_location`
  and `worker_location`, each the location to use for a *new* server.
- Both server resources add `location` to `lifecycle.ignore_changes`. An
  existing server never moves and is never replaced because the variable
  changed. Today `location` is not ignored, so a changed value replaces the
  server, and replacing the control plane is cluster loss.
- The apply wrapper tries `HOME_LOCATION` first. On `resource_unavailable` it
  re-runs the apply with the next location of the zone that lists the type.
  On `invalid_input` it skips that location without counting it as a stock
  failure. When every location fails it stops with the HETZ-175 message.
- The worker template already joins over the control plane's private IP and
  reads its own IP from metadata, so it renders the same in any location.

### 4.4 Autoscaler (part A)

- One `autoscalingGroups` entry per location that lists `WORKER_NODE_TYPE`,
  named `workers-<location>`, `minSize: 0`, `maxSize: MAX_WORKER_NODES -
  MIN_WORKER_NODES`.
- `ensure_autoscaler_config` emits one `nodeConfigs` entry per group, each
  with the same cloud-init and server labels.
- Priority expander: home location highest, then the zone order. A failed
  create puts that group in backoff and the next group is tried.
- A total cap keeps the sum of all groups at `MAX_WORKER_NODES -
  MIN_WORKER_NODES`, so the 5-server account cap shared with CI still holds.
  Verify at implementation: whether `--max-nodes-total` in CA v1.36 counts
  the control plane, and the expander-priorities value key in chart 9.59.0.
- The node template carries `csi.hetzner.cloud/location`, so a pod bound to a
  fsn1 volume only triggers `workers-fsn1`. Pods without a volume can land in
  any location.

### 4.5 The region-change guard

`state-up.sh:41-64` finds other platforms by checking a bucket for each value
of `catalog_regions`. Once that returns zones it would check `-eu-central-`
names that never exist and miss a live `-fsn1-` bucket, so a second platform
could be built. The guard MUST keep scanning one bucket per location of every
zone.

### 4.6 Old input

`REGION=fsn1` (a location) is refused with a message that names the new form:
`REGION=eu-central HOME_LOCATION=fsn1`. To be confirmed: refuse or alias
(§12).

### 4.7 Volumes

A volume stays in the location where it was created. A fresh cluster creates
the Postgres volume where its pod first lands (`WaitForFirstConsumer`). A
retained volume (park, unpark) pins Postgres to that location: if no node
exists there, Postgres stays Pending until the autoscaler's group for that
location gets stock. Accepted risk, recorded in §12.

## 5. Files/components affected

Paths relative to the repository root.

Part A:

- `gitops/templates/platform/hetzner/autoscaler/application.yaml:32-37`
  (one group), extraArgs (no expander, no total cap).
- `scripts/argo-up.sh:433-462` (`ensure_autoscaler_config`, `nodeConfigs`),
  `:904-908` (`capacity.autoscaler.*`).
- `gitops/values.yaml:166`, `gitops/bootstrap/values.yaml:46`,
  `gitops/bootstrap/templates/root-application.yaml:56-57`.
- `tests/scripts/autoscaler-config-test.sh:69` asserts `nodeConfigs` keys are
  exactly `["workers"]`.

Part B:

- `Makefile:55` (`REGION ?= fsn1`), comments `:56-59`, help `:404`, `:477`.
- `scripts/lib/region.sh:31-35` (`HCLOUD_LOCATION=$REGION`), `:42`
  (`HCLOUD_NETWORK_ZONE=eu-central`, unread), `:52` (`LAB_PROVIDER_REGION`).
- `scripts/lib/catalog.sh:104` (`catalog_regions`), `:115-117`
  (`catalog_node_types`), `:126` (default region), `:138-139` (default worker
  type), comments `:72-93`.
- `scripts/lib/provider.sh:57-72`; `scripts/lib/require-valid-node-config.sh:19-24`,
  `:29-68`, `:74-79`.
- `terraform/live/root.hcl:16`, `:43` (bucket name), `:49-51`, `:82`.
- `terraform/live/cluster-hetzner/k8s/terragrunt.hcl:42`.
- `terraform/modules/hcloud-nodes/main.tf:46`, `:88`, `:111` (lifecycle),
  `variables.tf:43-47`.
- `terraform/modules/hcloud-network/main.tf:18`, `variables.tf:18-22`
  (`network_zone`, to be fed from `REGION`).
- `persistent/backups/terragrunt.hcl:13`, `bootstrap/rolesanywhere/terragrunt.hcl:40`
  (both must keep the home-location name).
- `scripts/state-up.sh:12`, `:41-64` (guard); bucket-name rebuilds in
  `state-down.sh:11`, `status.sh:11`, `require-persistent.sh:9`,
  `require-unique-subdomain.sh:24`, `bootstrap-down.sh:16`,
  `account-down.sh:17`, `force-clean-ci.sh:44`, `persistent-down.sh:29,123`,
  `verify-no-leaks.sh:69`.
- `scripts/argo-up.sh:903` (`envoyGateway.location`), comments `:260-261`,
  `:891-892`; `gitops/templates/_helpers.tpl:133`.
- `scripts/park.sh:73-78` (unpark apply), `scripts/clusters.sh:179` (shows
  only the first server's location).
- CI: `.github/workflows/lab.yml:21-22`, `:67-77`, `:173`, `:191`, `:306`,
  `:312`; `lifecycle-test.yml:298`, `:559`.
- Tests: `tests/scripts/node-config-test.sh:65-68`, `:104-109`, `:150-157`,
  `:199-225`; `park-test.sh:157`; `clusters-test.sh:46-55`, `:133`;
  `recover-from-test.sh:14`, `:39-69`.
- Docs: `CLAUDE.md:154`; `README.md:167`, `:322`, `:525`;
  `specs/hetzner/architecture.md:58-59`, `:97`; `specs/hetzner/research.md`;
  `specs/shared/044-D-node-and-region-inputs/spec.md`;
  `docs/adr/0039-project-region-as-operator-input.md`.
- New: `docs/adr/0047-hetzner-region-is-a-network-zone.md`.

## 6. Implementation steps

Part A (one PR):

1. Autoscaler template: a list of groups from a `capacity.autoscaler.locations`
   value; priority expander; total cap. Check: `make gitops-check`.
2. `argo-up.sh`: pass the zone's locations that list the type, home first;
   one `nodeConfigs` entry per group. Check: `autoscaler-config-test.sh`
   updated and green.
3. Live: re-run argo-up. Check: autoscaler args show one `--nodes` per
   location; a Pending pod without a volume brings up a node in nbg1 or hel1
   while fsn1 is out of stock.

Part B (one PR):

4. ADR 0047 and SHARED-044 amendment.
5. `catalog.sh`, `region.sh`, `provider.sh`, `require-valid-node-config.sh`:
   zones, `HOME_LOCATION`, the location list. Check: `node-config-test.sh`.
6. `root.hcl` and every bucket-name rebuild: Hetzner namespace from
   `HOME_LOCATION`. Check: the computed bucket name for the live lab is
   unchanged.
7. `state-up.sh` guard scans every location of every zone. Check: the test in
   AC4.
8. `hcloud-nodes`: per-class location variables, `location` in
   `ignore_changes`; `hcloud-network`: `network_zone` from `REGION`. Check:
   AC1 plan.
9. Apply wrapper: location fallback on `resource_unavailable`. Check: a unit
   test with a stubbed apply that fails once.
10. argo-up, park, clusters, CI inputs, docs.

## 7. Dependencies and blockers

- HETZ-170 (autoscaler), HETZ-178 (control plane), HETZ-200 (park),
  SHARED-044 (region inputs) are DONE.
- HETZ-175 is READY and independent; its §4 pre-flight on the `available`
  flag is disproven and MUST NOT be reused here.
- SHARED-045 (one project, two regions) is unaffected: a project still has one
  zone and one home location.

## 8. Acceptance criteria

- AC1. On the live lab, `terragrunt plan` for `cluster-hetzner/k8s` after
  part B shows 0 to change and 0 to destroy for `cp-1` and `worker-1`.
- AC2. The load balancer keeps its ID and IP; its annotation is still
  `location: fsn1`.
- AC3. The state bucket, the backup bucket and the rolesanywhere bucket ARN
  keep their current names.
- AC4. With a `-fsn1-tf-state` bucket present, `make up` with
  `HOME_LOCATION=nbg1` is refused by the guard.
- AC5. With fsn1 out of stock for the worker type, a Pending pod with no
  volume gets a node in nbg1 or hel1 within `max-node-provision-time`.
- AC6. The autoscaler never runs more than `MAX_WORKER_NODES -
  MIN_WORKER_NODES` nodes in total across groups.
- AC7. On a fresh `make up` where the home location refuses the worker type
  with `resource_unavailable`, the worker is created in the next location and
  the cluster comes up.
- AC8. `REGION=fsn1` is refused with the message from §4.6; `REGION=us-east`
  is refused as not yet probed.
- AC9. Civo and AWS: render check, node-config test and lifecycle CI
  unchanged.

## 9. Validation

`make specs-check`, `make gitops-check`, `tests/scripts/*-test.sh`, the
Hetzner lifecycle CI job, and the live checks in AC1–AC5.

## 10. AWS regression protection

AWS refuses `REGION` today (`require-valid-node-config.sh:49-53`); that stays.
The render check and the aws golden MUST show no diff from part A or B.

## 11. Rollout and rollback/recovery

- Part A first. Rollback: revert the template; argo-up restores one group.
- Part B: run `terragrunt plan` read-only before any apply; stop on any
  change or destroy for an existing server. Rollback: revert; nothing outside
  Git changed, because the bucket names and servers are untouched.

## 12. Risks and unresolved questions

| Question | Default until decided |
|---|---|
| `REGION=fsn1`: refuse or treat as `eu-central` + `HOME_LOCATION=fsn1`? CI `lab.yml` depends on it | refuse with a message |
| Zones other than `eu-central` in the catalog now? | refused until probed |
| `HOME_LOCATION`: operator input or always the catalog's first location? | operator input, default first |
| Does `--max-nodes-total` count the control plane in CA v1.36? | verify at implementation |
| Priority expander key in chart 9.59.0 | verify at implementation |

Accepted risks:

- A retained Postgres volume pins Postgres to its location; it waits for
  stock there (§4.7).
- A worker in hel1 is about 25 ms from the fsn1 load balancer and Postgres.

## 13. Definition of done

- [ ] AC1–AC9 met and recorded
- [ ] ADR 0047 Accepted; SHARED-044 amended
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-11-23 — created as DRAFT from the CORE-230 capacity work in
  `vk-llm-on-demand`. Evidence in §3.
