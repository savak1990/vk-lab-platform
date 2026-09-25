# ADR 0041: A parked cluster keeps its control plane and loses its workers, on Hetzner only

## Status

Accepted

Amends [ADR 0036](0036-hetzner-kubeadm-third-execution-target.md)'s and
[ADR 0027](0027-civo-second-execution-target.md)'s claim that `PROVIDER`
dispatch adds no lifecycle command, for one command pair and no more. Builds on
[ADR 0037](0037-k3s-bootstrap-on-hetzner.md), whose Terraform-generated join
token is what makes an unparked worker rejoin with no operator step.

## Context

The disposable lifecycle has two states: a cluster exists, or it does not.
`make down` destroys it and `make up` rebuilds it from nothing. The operator
asked for a third state — the workers gone, the control plane and everything the
cluster knows still there — and named the saving as the motivation.

The saving is real but it is not the argument. **A torn-down project is cheaper
than a parked one.** `cluster-down.sh` sweeps volumes as well as servers, so
`make down` reaches approximately zero, while a parked Hetzner project still
pays for a control plane and a load balancer:

| | EUR/month |
|---|---|
| Running: cx23 control plane + cx43 worker + lb11 + 2 primary IPv4 + 20Gi volume | 35.61 |
| Parked: the same without the worker, and one IPv4 | 16.62 |
| Torn down | ~0 |

So park cannot be justified on cost against teardown. What it buys is **time and
in-cluster state**, and those are worth more than the 19 EUR:

- A bring-up allows `ARGO_UP_WATCH_SECONDS` of 2700 for the platform to reach
  Healthy, plus a 600s node gate, a 180s cloud-controller gate and a 300s DNS
  gate. An unpark boots one server and lets the scheduler place pods.
- The TLS issuers are ACME. Production Let's Encrypt allows five duplicate
  certificates per week, so rebuilding repeatedly eventually meets a limit that
  no retry budget can clear. A park never re-issues.
- Postgres needs no dump and no restore. HETZ-120 makes the data of record an S3
  logical backup and calls the volume disposable; a park keeps the volume and
  skips both halves of that round trip.
- etcd, every Argo CD `Application` object, the DNS records and the load
  balancer's address all survive.

### Why this is possible on Hetzner and awkward elsewhere

On Hetzner the control plane is not pods. `k3s server` runs the API server, the
controller manager, the scheduler and embedded etcd as goroutines in one
systemd unit with `Restart=always`, so it answers `kubectl` and holds etcd with
no worker present at all. HETZ-178 then tainted it, which removed the reason a
zero-worker cluster would have been unpleasant: nothing tries to cram the
platform onto a 2 vCPU control plane, so the parked state is quiet rather than
thrashing.

The pieces that make a worker come back were already built for other reasons.
The join token is a `random_password` held in state with no keepers, the join
address is `cidrhost(subnet, 10)` derived from the **persistent** subnet, the
agent retries until the API answers, worker names and private addresses are
deterministic in `count.index`, and the firewall attaches by label selector. A
worker destroyed today and recreated next week rejoins with no coordination
step and no SSH.

## Decision

**A parked cluster is a live, empty cluster.** The API answers, etcd is intact,
volumes stay bound, and every platform workload is Pending. Postgres is stopped,
not running. Unpark is a scheduling event, not a restore.

**`make park` and `make unpark` are a guarded modifier on the Disposable pair,
not a fifth lifecycle class.** They create and destroy nothing outside the class
`make up` and `make down` already own, and they change no other command's
contract or guards. This is the shape `make full-up`/`full-down` earned their
place in constitution §17 with, and the same sentence applies: they are not a
new lifecycle class.

**Park never deletes the Argo CD root Application.** `cluster-down.sh` refuses to
run while root exists, and for a parked cluster that refusal is the protection
the state needs — its surviving servers and volumes still carry the labels a
teardown sweep matches on. A park that removed root would silently unlock a
destroy.

**The load balancer stays up while parked.** It is the largest parked line item
at 8.49 EUR/month and it routes to a Pending pod, which is waste. It is
deliberate waste. The hcloud load balancer carries no static-address annotation
and its location is immutable, so a recreated one takes a new address — which
means re-publishing DNS, waiting for propagation and re-entering the certificate
path. That spends most of what park was bought for.

**Hetzner only.** The command exists on every target and refuses on the others,
naming why.

## Alternatives considered

- **Powering the servers off instead of destroying them.** Rejected: it saves
  nothing. Hetzner bills a server "for as long as it exists, regardless of
  whether it is turned on or not". Only deletion stops the meter, and billing is
  hourly with a one-hour minimum, so a park shorter than an hour is free of
  benefit as well as free of cost.
- **A snapshot of the worker, restored on unpark.** Rejected as unnecessary. The
  worker holds no state worth keeping — its cloud-init rebuilds it identically
  from a render Terraform already publishes — and a snapshot bills per GB while
  adding a restore step that the join already makes redundant.
- **Park on AWS.** Declined and costed in AWS-034-Z. The EKS control plane is a
  fixed hourly charge that park cannot touch, so the saving is about a fifth of
  the bill; the node group's `min_size`, `max_size` and `desired_size` are all
  one variable with no `ignore_changes`, so any out-of-band scaling is reverted
  by the next apply; and Karpenter, the only thing that creates nodes there, is
  pinned to the very node group park would remove, so it cannot provision the
  node it needs to run on. Unpark would have to be an EKS API call that
  Terraform then fights.
- **Park on Civo.** Not built. It is the best target on paper — the control plane
  is free, so a parked Civo cluster costs no more than a deleted one, and
  Terraform already concedes the pool count with
  `ignore_changes = [tags, pools[0].node_count]`. But the in-cluster autoscaler
  owns that count with an absolute `minSize` under `selfHeal: true` and its own
  API token, so park would have to disarm it and re-arm it; and whether the Civo
  API accepts a pool count of zero is undocumented and untested. That is more
  code and an unproven dependency, for a target the operator does not park.
- **Scaling workloads to zero instead of nodes.** Rejected, and dangerous. The
  Prometheus, Alertmanager and Loki claims all carry `whenScaled: Delete`, so
  scaling those StatefulSets destroys their volumes. Park scales nodes and never
  replicas.
- **Recording the parked state in SSM or a marker file.** Rejected as
  unnecessary state. Zero workers *is* the parked state, and it is observable
  from the cloud API that park already talks to.

## Consequences

Two floors that were invariants become conditional. The Terraform validation on
`min_worker_nodes` relaxes from `> 0` to `>= 0`. The operator-facing offline gate
does **not** relax: `require-valid-node-config` still refuses
`MIN_WORKER_NODES=0`, because it is a Make prerequisite rather than something the
script calls, so `park.sh` sets zero for itself and a mistyped `make up` is still
caught.

`aws_ssm_parameter.worker_ips` gains a sentinel for the empty pool, because SSM
rejects an empty value. The parameter is kept rather than removed: no code reads
it, but HETZ-030's acceptance criteria name it.

Park acquires the only `kubectl delete node` in the repository. Nothing reaps a
stale `Node`, and `wait_for_nodes_ready` requires every present node to be
Ready, so a leftover `NotReady` object would wedge the unpark rather than the
park.

A parked cluster is not free, so parking for weeks is the wrong choice and
tearing down is the right one. HETZ-200 carries that threshold in hours against
the measured unpark time.
