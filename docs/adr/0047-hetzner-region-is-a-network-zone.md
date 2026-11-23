# 0047. On Hetzner, REGION is a network zone

Date: 2026-11-23

Status: Accepted. Amends ADR 0039.

## Context

ADR 0039 made `REGION` an operator input. On Hetzner it named one location
(`fsn1`). On 2026-11-23 creates of `cx33` and `cx43` in fsn1 returned
`resource_unavailable` while nbg1 and hel1, in the same private network zone,
could host the same servers. A location-valued `REGION` pinned the control
plane, the fixed workers, the autoscaler and the load balancer to the one
location that was out of stock.

## Decision

On Hetzner, `REGION` names the network zone. The only accepted zone is
`eu-central`; other zones are refused until a create probe shows what they sell.

- The platform picks the location per server. `make up` and `make unpark`
  try the zone's locations in catalogue order (`fsn1`, `nbg1`, `hel1`) and
  move on after `resource_unavailable` or `unsupported location for server
  type`. A server keeps its location after create.
- The autoscaler runs one node group per location that sells the worker type.
- The load balancer is placed with `load-balancer.hetzner.cloud/network-zone`.
- The state and backup buckets are named after the zone
  (`<project>-eu-central-tf-state`). A location value (`REGION=fsn1`) is
  refused with a message naming the zone.

## Consequences

- Moving a live platform to the new names is a `make full-down` with the code
  before this change, then a `make full-up` with it. The region-change guard
  refuses a `full-up` while a location-named bucket still holds state.
- A volume stays in the location where it was created. After `make park`, an
  unparked worker can land in another location; pods bound to those volumes
  wait for an autoscaled node in the volumes' location.
- Civo and AWS are unchanged.
