---
id: "HETZ-185"
title: "CKA practice runbook: kubeadm upgrade 1.36 → 1.37, stacked etcd snapshot/restore, certificate checks"
status: "READY"
priority: "P2"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Documented upstream procedures executed on a real cluster; the judgement is in recording what broke"
effort_estimate: "One session (4–6 h) on a live cluster"
estimate_confidence: "medium"
depends_on: ["HETZ-037", "HETZ-040"]
blocked_by: []
supersedes: []
created: "2026-09-19"
updated: "2026-09-20"
completed: ""
---

# HETZ-185 — kubeadm operations runbook

## 1. Outcome and rationale

A runbook, `tests/manual/hetzner-185-kubeadm-operations.md`, executed once
against a real HETZ-037 cluster and recorded, turns the disposable cluster
into CKA practice: a minor upgrade (N-1 → N), a stacked etcd snapshot and
restore, and a certificate expiry check and renewal. Every command is one
the exam asks for, run against the platform's own cluster rather than a
throwaway kind cluster. `make down` then `make up` afterwards restores the
pinned 1.36 cluster, so the exercise leaves no lasting drift. This spec is
not a gate for HETZ-150 — the full-lifecycle validation runs against the
pinned 1.36 cluster regardless of whether this runbook has been executed.

## 2. Scope and non-goals

In scope: writing and executing
`tests/manual/hetzner-185-kubeadm-operations.md`, and recording its results
in `research.md`. Not in scope: automating any of the three procedures into
a script — this is manual exam practice, not permanent tooling; an HA
control-plane exercise (the cluster stays one stacked control plane,
decisions.md §3); bumping `KUBERNETES_VERSION` in `scripts/lib/versions.sh`
as the platform's own pin — the runbook upgrades a live cluster to 1.37
for practice and then discards it, it does not move the repository's
pinned target; bumping the cluster-autoscaler pin to a 1.37 release,
because none exists yet (HETZ-170 §3); HETZ-150's own full-lifecycle
validation.

## 3. Current state / evidence

- HETZ-035/HETZ-037 leave a running cluster on kubeadm 1.36 (1.36.4) with
  Cilium 1.20.2, reachable through `make node-ssh` and `make kubeconfig`
  (HETZ-040).
- `scripts/lib/versions.sh` pins `KUBERNETES_VERSION` (1.36.x) and
  `CILIUM_CHART_VERSION=1.20.2`; Kubernetes 1.37.0 is the newest minor
  (2026-08-26), making 1.36 the N-1 this runbook upgrades from.
  https://kubernetes.io/releases/
- research.md, "kubeadm package repository": the repo line is one path
  per minor, edited to move a node to a new minor.
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/
- research.md, "kubeadm upgrade procedure": control plane first
  (`kubeadm upgrade plan`, `kubeadm upgrade apply v1.37.x`, drain,
  kubelet/kubectl, `systemctl daemon-reload && systemctl restart kubelet`,
  uncordon), then workers (`kubeadm upgrade node`); no minor skipping;
  kubelet may trail the API server by up to three minors.
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/ ;
  https://kubernetes.io/releases/version-skew-policy/
- research.md, "etcd snapshot/restore": etcd 3.7.1 is kubeadm's default
  for 1.35–1.37; save with `etcdctl snapshot save`, restore with `etcdutl
  snapshot restore --data-dir`, then repoint
  `/etc/kubernetes/manifests/etcd.yaml`; `kubeadm certs check-expiration` /
  `renew all`. https://etcd.io/docs/v3.6/op-guide/recovery/ ;
  https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- research.md, "CKA curriculum": Troubleshooting 30 %, Cluster
  Architecture/Installation/Configuration 25 % (kubeadm clusters, cluster
  lifecycle, HA control plane among its items), Services & Networking 20 %,
  Workloads 15 %, Storage 10 %; the exam tracks the newest minor within
  4–8 weeks. https://training.linuxfoundation.org/certified-kubernetes-administrator-cka-program-changes/
- HETZ-170 §3: `cluster-autoscaler` has no 1.37 tag yet, so the
  autoscaler stays pinned at 1.36.1 through this upgrade practice; the
  cluster-autoscaler-to-apiserver skew this leaves is within the
  documented `≤` relationship, not a break.
  https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/README.md
- HETZ-037 §3: Cilium 1.20.2's documented Kubernetes compatibility is
  1.33–1.36, which does not yet list 1.37 — the runbook's own Cilium
  upgrade step in procedure (A) depends on whichever chart version
  publishes 1.37 support by the time it is run.
  https://docs.cilium.io/en/stable/network/kubernetes/compatibility/
- HETZ-115 places CNPG on the cluster; draining the control plane while
  it is the only other schedulable node evicts CNPG's pod, which this
  spec's §12 records rather than works around.

## 4. Design and contracts

`tests/manual/hetzner-185-kubeadm-operations.md` records three procedures,
each with exact commands, run in order against the live cluster, with
timings and every error recorded verbatim rather than summarized.

**(A) Minor upgrade, 1.36 → 1.37.** On the control plane, over
`make node-ssh`: edit `/etc/apt/sources.list.d/kubernetes.list` to the
`v1.37` repo line; `apt-mark unhold kubeadm && apt-get update && apt-get
install -y kubeadm='1.37.x-*' && apt-mark hold kubeadm`; `kubeadm upgrade
plan`; `kubeadm upgrade apply v1.37.x`; `kubectl drain <cp>
--ignore-daemonsets`; `apt-mark unhold kubelet kubectl && apt-get install
-y kubelet='1.37.x-*' kubectl='1.37.x-*' && apt-mark hold kubelet kubectl`;
`systemctl daemon-reload && systemctl restart kubelet`; `kubectl uncordon
<cp>`. Then on the worker: the same repo edit, the same kubeadm package
step, `kubeadm upgrade node`, drain, the kubelet/kubectl package step,
`systemctl daemon-reload && systemctl restart kubelet`, uncordon. Then
`helm upgrade cilium cilium/cilium --version <1.37-compatible version>`
against the running release, and a recorded note that the cluster
autoscaler stays at 1.36.1 until a 1.37 tag exists — allowed because the
version-skew policy permits the autoscaler to trail the API server.
`kubectl drain` works because no PodDisruptionBudget exists in M1 (CNPG
`enablePDB: false`, HETZ-050); if a PDB ever blocks it, fix the PDB rather
than using `--disable-eviction`.

**(B) Stacked etcd snapshot and restore.** On the control plane: install
`etcd-client` (or run the matching `etcd` container image) so `etcdctl`
and `etcdutl` exist; create a marker `ConfigMap`, so the snapshot taken
next contains it; `ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379
--cacert=/etc/kubernetes/pki/etcd/ca.crt
--cert=/etc/kubernetes/pki/etcd/server.crt
--key=/etc/kubernetes/pki/etcd/server.key snapshot save /root/snap.db`;
delete the marker `ConfigMap`; `etcdutl snapshot restore
/root/snap.db --data-dir /var/lib/etcd-restored`; move
`/etc/kubernetes/manifests/{kube-apiserver,etcd}.yaml` out of the manifests
directory to stop both static pods; edit `etcd.yaml`'s `hostPath` to point
at `/var/lib/etcd-restored`; move both manifests back; confirm the marker
`ConfigMap` is present again, proving the restore rolled the cluster back
to the snapshot taken before the deletion.

**(C) Certificate expiry and renewal.** On the control plane:
`kubeadm certs check-expiration`; `kubeadm certs renew all`; restart the
control-plane static pods (moving the manifests out and back, the same
mechanism as (B)); refetch `admin.conf` with `make kubeconfig`, because
`renew all` issues new client certificates that the previously fetched
kubeconfig no longer matches.

## 5. Files/components affected

`tests/manual/hetzner-185-kubeadm-operations.md` (new); `research.md`
(execution results: timings, verbatim errors, and the recorded state
after each procedure).

## 6. Implementation steps

1. Write `tests/manual/hetzner-185-kubeadm-operations.md` with the three
   procedures' exact commands from §4.
2. Execute procedure (A) against a real HETZ-037 cluster; record timings
   and every error verbatim; confirm `kubectl version` reports 1.37 on
   every node afterward.
3. Execute procedure (B); confirm the marker `ConfigMap`, created before
   the snapshot and deleted after it, is present again after the restore.
4. Execute procedure (C); confirm `kubeadm certs check-expiration` shows
   renewed dates and `make kubeconfig` succeeds against the restarted API
   server.
5. `make down` then `make up`; confirm the recreated cluster is back on
   1.36; commit the runbook with its recorded output and the `research.md`
   update.

## 7. Dependencies and blockers

HETZ-037 supplies the running cluster (kubeadm 1.36, Cilium, every node
`Ready`) this runbook upgrades and restores. HETZ-040 supplies
`make node-ssh` and `make kubeconfig`, the two entry points every
procedure in §4 uses.

## 8. Acceptance criteria

- All three procedures in §4 are executed on a real HETZ-037 cluster;
  nodes are `Ready` after each one.
- The marker `ConfigMap` procedure (B) creates before the snapshot and
  deletes after it is present again after the etcd restore.
- `kubectl version` reports 1.37 on every node after procedure (A).
- `make down` followed by `make up` yields a 1.36 cluster again.
- The runbook is committed with its recorded output (timings and every
  error, verbatim).

## 9. Validation

Offline: `make specs-check`. Real cloud: the three-procedure execution in
§6, against a HETZ-037 cluster already billed for that spec's own
validation, plus the closing `make down`/`make up` cycle to confirm the
pinned 1.36 cluster returns.

## 10. AWS regression protection

Not applicable: this spec adds one hetzner-only manual runbook file and
touches no shared script, Terraform, or GitOps path. No aws or civo
behavior changes.

## 11. Rollout and rollback/recovery

`make down` then `make up` discards the 1.37/restored-etcd/renewed-cert
state this runbook creates and returns to the pinned 1.36 cluster — the
same disposable-lifecycle mechanism every other Hetzner exercise relies
on. The runbook file itself is documentation; reverting it is deleting the
file.

## 12. Risks and unresolved questions

- `etcdutl`, not `etcdctl`, performs the restore in procedure (B); the two
  tools are easy to confuse and the wrong one fails immediately.
- `cluster-autoscaler` has no 1.37 tag yet (HETZ-170 §3), so procedure
  (A) leaves the autoscaler at 1.36.1 against a 1.37 control plane —
  within the documented skew, but a gap to close once a 1.37 release
  exists.
- Cilium 1.20.2's documented compatibility list stops at 1.36 (HETZ-037
  §12); procedure (A)'s Cilium upgrade step depends on a chart version
  whose 1.37 compatibility is not yet published upstream at the time this
  spec is written.
- Draining the control plane on a two-node cluster evicts CNPG's pod
  (HETZ-115), because no other schedulable node exists; run procedure (A)
  before HETZ-115 lands, or accept the CNPG restart it causes.
- The control-plane API server is unreachable for the duration of both
  procedure (B)'s manifest swap and procedure (C)'s static-pod restart;
  `kubectl` commands issued during either window fail until the
  `kube-apiserver` static pod comes back.

## 13. Definition of done

- [ ] All three procedures executed on a real cluster with timings and
      verbatim errors recorded
- [ ] Marker `ConfigMap` deleted after the snapshot is present again
      after the etcd restore
- [ ] `make down`/`make up` confirmed to restore the pinned 1.36 cluster
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-19 — created as READY (kubeadm replan); CKA practice.
- 2026-09-20 — records why `kubectl drain` is unblocked in M1 (no PDB;
  decisions.md §3, "Schedulable control plane").
