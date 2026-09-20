---
id: "HETZ-017"
title: "k3s replaces kubeadm as the Hetzner bootstrap: ADR 0037, a note on ADR 0036, and the package rewrite"
status: "READY"
priority: "P0"
milestone: "M0"
type: "governance"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "One decision inverts an Accepted ADR and the acceptance criterion that guarded it; four specs retire and every reference to them must move in the same commit or specs-check fails"
effort_estimate: "One session (4–6 h), documents only"
estimate_confidence: "medium"
depends_on: ["HETZ-015"]
blocked_by: []
supersedes: []
created: "2026-09-20"
updated: "2026-09-20"
completed: ""
---

# HETZ-017 — k3s replaces kubeadm as the Hetzner bootstrap

## 1. Outcome and rationale

ADR 0036 chose kubeadm for the Hetzner control plane and rejected k3s with one
sentence: "The lab's secondary purpose is certification practice against the
tool the exam uses." The operator withdrew that purpose on 2026-09-20. The
package is now optimised for the least operational work and the fewest moving
parts, so the sentence that decided the bootstrap no longer holds and the
decision must be re-taken in the open rather than drift.

This spec records the new decision and rewrites the package to match. After it
lands, cloud-init installs k3s from `get.k3s.io` on both roles, the control
plane brings itself up with embedded etcd at first boot, and workers join at
first boot from a Terraform-generated token. No operator step, no SSH, and no
package pinning sit in the create path.

Nothing about the Hetzner target apart from the bootstrap changes. The cost
model, the node shape, the identity chain, the DNS delegation, the lifecycle
classification and the ownership boundary all stand as ADR 0036 states them.

The timing is favourable: the package is 100 % unimplemented. There is no
Hetzner Terraform, no cloud-init template and no bootstrap script on any
branch, so this is a change to 5,970 lines of specification and not to working
infrastructure.

## 2. Scope and non-goals

In scope: `docs/adr/0037-k3s-bootstrap-on-hetzner.md` (new); a dated note on
ADR 0036; the Hetzner cells of constitution §20; `docs/architecture.md` §10a and
`docs/hetzner-high-level-design.md`; the retirement of HETZ-035, HETZ-037,
HETZ-165 and HETZ-185; the rewrite of HETZ-030, HETZ-160 and HETZ-170; wording
and call-site edits across ten further specs; and the four package documents.

Not in scope: any Terraform, shell, GitOps or workflow file. No implementation
spec changes status to `IN_PROGRESS` because of this spec. The AWS and Civo
targets are untouched; no file outside `specs/hetzner/`, `docs/adr/`,
`docs/architecture.md`, `docs/hetzner-high-level-design.md`,
`specs/shared/000-D-constitution/spec.md` and `CLAUDE.md` is modified.

## 3. Current state / evidence

- `docs/adr/0036-hetzner-kubeadm-third-execution-target.md` is `Accepted`; its
  "Alternatives considered" rejects k3s on the certification argument alone, and
  its Consequences commit the platform to owning "upgrades, certificates and
  etcd backups", specified separately as HETZ-185.
- `decisions.md:63` records the same reasoning: k3s "hides kubeadm, etcd, static
  pods and kubelet-under-systemd, which the CKA syllabus … and the upgrade
  runbook need; the SQLite datastore has no snapshot/restore practice."
- `decisions.md:43` ("Bootstrap driver") rejected option (b), a
  Terraform-generated credential in `user_data`, because it "puts the CA key in
  Terraform state and in the control plane's metadata, which any `hostNetwork`
  pod reads". `decisions.md:49` states the property that decision bought: "the
  fixed nodes' `user_data` holds no secret". `030` §8 asserts it as an
  acceptance criterion.
- The package was written around k3s on 2026-09-11 and replanned around kubeadm
  by commit `a14036c` on 2026-09-19. The last k3s-era tree is `0b6a638`. It
  carries decisions corrected later for unrelated reasons — arm64 `cax21` nodes,
  a three-node 24 GB ceiling, `SUBDOMAIN=hetzner`, `secrets/hcloud-token.enc`,
  `kube-system/hcloud` holding the operator's token, and ADR number 0032 — so it
  is source material, not a revert target.
- k3s is a CNCF-certified Kubernetes distribution. The Kubernetes API, CRDs,
  Helm charts and Argo CD Applications in `gitops/` are unaffected by the
  change. Civo managed Kubernetes is itself k3s
  (`terraform/modules/civo-k8s/main.tf:7`), so the platform already runs on k3s
  on one target.
- `specs/README.md` forbids renumbering and makes the status letter the folder
  name; `scripts/specs-check.sh` rule 10 fails when any in-repo string matching
  a lettered spec path no longer resolves on disk. Retirement is therefore
  `SUPERSEDED` plus a folder rename plus reference updates, all in one commit.
- ADR 0011 established the amendment convention and commit `27024ae` applied it
  to five ADRs: a dated blockquote after the title line, above `## Status`,
  leaving the original text untouched. Supersession is different — ADR 0031's
  `## Status` body was replaced and its text kept.

## 4. Design and contracts

**ADR 0037, the new record.** Status `Accepted`. Context: the withdrawn
certification goal; the unimplemented state of the package; the measured cost
of the kubeadm design, about 1,100 lines of new code of which about 370 are apt
repository pinning, containerd configuration, a kubeadm v1beta4 document and a
token-over-SSH join loop. Decision: k3s from `get.k3s.io` in cloud-init,
embedded etcd through `--cluster-init`, flannel, and a Terraform-generated join
token in `user_data` so that workers and autoscaled nodes join at first boot
from one template. Alternatives considered, each with its reason: kubeadm (the
superseded choice, and why the reason for it lapsed); kOps (native hcloud
support is beta, and it would create the network, firewall and load balancer
that Terraform owns); the `kube-hetzner` module and the `hetzner-k3s` CLI (both
already rejected in ADR 0036 for reasons this change does not alter); Talos and
Cluster API Provider Hetzner (each adds a toolchain or a management cluster);
OKD (free, but 128 to 369 EUR per month against a 50 to 100 USD ceiling).

**The bootstrap.** Both roles get a `#cloud-config` with a `bootcmd` that waits
for the private NIC and a `runcmd` that reads the public IPv4 from
`169.254.169.254/hetzner/v1/metadata/public-ipv4` and then installs k3s.

Control plane:

```
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} K3S_TOKEN=${token} sh -s - server \
  --cluster-init \
  --disable-cloud-controller \
  --disable=servicelb,traefik,local-storage \
  --kubelet-arg=cloud-provider=external \
  --kubelet-arg=system-reserved=cpu=500m,memory=1Gi \
  --kubelet-arg=kube-reserved=cpu=250m,memory=512Mi \
  --kubelet-arg=eviction-hard=memory.available<300Mi \
  --node-ip=10.0.1.10 --node-external-ip=$PUB --tls-san=$PUB \
  --flannel-iface=<private nic> --etcd-expose-metrics \
  --kube-controller-manager-arg=bind-address=10.0.1.10 \
  --kube-scheduler-arg=bind-address=10.0.1.10 \
  --write-kubeconfig-mode=0600
```

Worker:

```
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${k3s_version} K3S_TOKEN=${token} \
  K3S_URL=https://10.0.1.10:6443 sh -s - agent \
  --kubelet-arg=cloud-provider=external \
  --node-ip=${private_ip} --node-external-ip=$PUB \
  --flannel-iface=<private nic>
```

The agent service restarts until the control plane answers, so Terraform creates
both servers at once and boot order does not matter. This removes the ordering
dependency the kubeadm design needed `depends_on` and an SSH join loop to
express.

**Why embedded etcd and not the SQLite default.** `--cluster-init` is one flag
at first boot. It gives snapshot and restore, makes `--etcd-expose-metrics`
meaningful so HETZ-160 gains a real scrape target instead of disabling one, and
makes a later HA spec additive — a SQLite cluster cannot become HA without
re-initialising. The control plane is schedulable and carries workloads, so the
kubelet reservations from `decisions.md:44` are carried over verbatim as
`--kubelet-arg` values. Their distribution mechanism changes: kubeadm set them
once in the `kube-system/kubelet-config` ConfigMap and every join inherited
them, while k3s needs them on each node's install line. The values are
identical; the one template that renders them is the single source.

**Why flannel.** It is k3s's default, it needs no install step, and nothing in
`gitops/` references Cilium. Flannel runs VXLAN, so the CCM keeps
`HCLOUD_NETWORK_ROUTES_ENABLED=false`, exactly as the kubeadm design set it for
Cilium VXLAN. `--flannel-backend=none` remains the documented route to another
CNI. Pod and service CIDRs become the k3s defaults `10.42.0.0/16` and
`10.43.0.0/16`; four call sites carry `10.244.0.0/16` today.

**What k3s brings that must be switched off.** `--disable=servicelb,traefik,`
`local-storage` leaves the hcloud CCM as the only LoadBalancer controller and
`hcloud-volumes` as the only default StorageClass. k3s ships metrics-server, so
the Argo-owned metrics-server Application the kubeadm design added
(`decisions.md:45`) is dropped and `--kubelet-insecure-tls` is not needed. The
CCM still runs before Argo CD for the reason ADR 0036 gives, unchanged: the
kubelet self-taints `node.cloudprovider.kubernetes.io/uninitialized` under
`cloud-provider=external`, k3s's bundled CoreDNS does not tolerate that taint,
and Argo CD needs DNS to reach its own repository server.

**The one decision that inverts.** A Terraform-generated `K3S_TOKEN` lives in
Terraform state and in both servers' `user_data`, which any `hostNetwork` pod
reads at `169.254.169.254/hetzner/v1/userdata`. This is the design
`decisions.md:43` rejected. Half of that objection lapses, because k3s derives
its cluster CA from the token and no CA private key enters state. The other half
stands and ADR 0037 states it with its bounds: the token grants node join only;
the join path is the private network; the token is regenerated on every
`make up` and dies with the cluster; and `k3s token rotate` exists. The
`030` §8 criterion is rewritten from "no join token in state" to "no kubeconfig
and no private key material in state; the join token is present and
documented". `decisions.md` rows 43 and 49 are re-decided with today's date
rather than edited in place, and `architecture.md` §5's credential table records
the exposure.

**Retirements.** Four specs stop being work. Each takes
`status: "SUPERSEDED"`, a §14 line naming this spec, a folder rename to
`NNN-Z-…`, and a reference sweep, all in the same commit.

| Spec | Lines | Why it stops |
|---|---|---|
| HETZ-035, kubeadm bootstrap | 295 | It is the SSH join. Workers join at boot |
| HETZ-037, Cilium CNI | 269 | k3s ships flannel; there is no CNI install step |
| HETZ-165, join credential | 299 | Terraform owns the token; there is nothing to mint |
| HETZ-185, operations runbook | 234 | The certification goal is withdrawn |

Residue that survives its spec: `configure_kubeconfig`'s Hetzner arm and the
node-Ready wait move from HETZ-035 into HETZ-040, with the source path
`/etc/rancher/k3s/k3s.yaml` and the rewrite of `127.0.0.1` to the public IP; the
32 KiB `user_data` guard and the allocatable-memory measurement move from
HETZ-165 and HETZ-037 into HETZ-030.

**Rewrites.** HETZ-030 keeps its number and `id` and is renamed
`030-P-hetzner-terraform-k3s-nodes`. Its firewall, server, label, private-IP and
SSM-output design survives as written; §4's two cloud-init templates and §8's
acceptance criteria are replaced. HETZ-160 §3 and §4 change scrape targets: k3s
runs the control-plane components in one process, and with `--cluster-init` the
etcd target is real. HETZ-170 §3 and §4 point the autoscaler's `cloudInit` at
the same worker `user_data` Terraform renders, and absorb HETZ-165's size guard.

**Edits.** HETZ-010 §1, HETZ-020 (the 7-item checklist shrinks to the four
Hetzner-platform items — volume survival, load balancer lifecycle and orphaning,
account limits, invoice — because the kubeadm ordering items no longer describe
anything), HETZ-025 §12, HETZ-040, HETZ-045, HETZ-050, HETZ-060, HETZ-085 §12,
HETZ-130. Unchanged: HETZ-016, HETZ-018, HETZ-047, HETZ-070, HETZ-080,
HETZ-115, HETZ-120, HETZ-140, HETZ-150, HETZ-175, HETZ-182, HETZ-190.

## 5. Files/components affected

- `docs/adr/0037-k3s-bootstrap-on-hetzner.md` (new).
- `docs/adr/0036-hetzner-kubeadm-third-execution-target.md` (dated note; title
  and body otherwise untouched, and the file is not renamed because every
  reference to its path would break).
- `specs/shared/000-D-constitution/spec.md` §20, Hetzner cells of the §3 and §5
  rows.
- `docs/architecture.md` §10a; `docs/hetzner-high-level-design.md`; `CLAUDE.md`
  where it describes the Hetzner bootstrap.
- `specs/hetzner/{035,037,165,185}-*/spec.md` and their folder names.
- `specs/hetzner/030-*/spec.md` and its folder name;
  `specs/hetzner/{160,170}-*/spec.md`.
- `specs/hetzner/{010,020,025,040,045,050,060,085,130}-*/spec.md`.
- `specs/hetzner/{README,architecture,decisions,research,roadmap}.md`.

## 6. Implementation steps

1. Write ADR 0037 and the note on ADR 0036.
2. Retire the four specs: front matter, §14 line, folder rename, then
   `grep -rn` each old folder name across the repository and update every hit.
3. Rewrite HETZ-030, then HETZ-160 and HETZ-170.
4. Apply the wording and call-site edits to the remaining nine specs.
5. Rewrite the package documents: `decisions.md` rows 7, 10, 14, 41, 43, 44, 45,
   46, 49 and the §2 ADR table and §4 rejected list; `architecture.md` §1, §2,
   §3, §4, §5 and the §6 bootstrap-ordering section; `research.md`'s kubeadm,
   Cilium and containerd fact rows; `README.md`'s header and index;
   `roadmap.md`'s milestones, graph edges and critical path.
6. Update the constitution, `docs/architecture.md`, the high-level design and
   `CLAUDE.md`.
7. Run the §9 validation. Fix and re-run until clean.

## 7. Dependencies and blockers

HETZ-015 is `DONE` and supplies ADR 0036 and constitution §20, which this spec
amends. No other spec blocks it, and it blocks HETZ-020 and HETZ-030 in the
sense that both describe the superseded bootstrap until it lands.

## 8. Acceptance criteria

- `make specs-check` exits 0.
- `grep -rIn --exclude-dir=.git -e kubeadm -e 'pkgs\.k8s\.io' -e apt-mark -e cp-bootstrap-done specs/hetzner docs/ CLAUDE.md` returns hits only inside the four `NNN-Z-` folders, inside ADR 0036's original text below its note, and in dated §14 history lines.
- `grep -rn '10\.244\.0\.0/16' specs/ docs/` returns nothing outside the retired folders.
- `grep -rn 'Cilium' specs/hetzner docs/` returns hits only in the retired HETZ-037, in ADR 0036's original text, and in dated history lines.
- `docs/adr/0037-k3s-bootstrap-on-hetzner.md` exists, is `Accepted`, names the token-in-metadata exposure with its bounds, and lists at least kubeadm, kOps, Talos, Cluster API Provider Hetzner and OKD under alternatives considered.
- ADR 0036 carries a dated blockquote naming ADR 0037 above `## Status`, and its `## Status` still reads `Accepted` — the target decision is not superseded, only the bootstrap mechanism.
- The four retired specs read `status: "SUPERSEDED"`, sit in `NNN-Z-` folders, and each names HETZ-017 in §14.
- `specs/hetzner/README.md`'s index agrees with every spec's front matter on status, title and `depends_on`.
- `roadmap.md`'s dependency graph has no edge into a retired spec and its critical path routes through neither 035 nor 037.
- `make gitops-check` and `make secrets-check` exit 0, unchanged from before the commit.
- No file under `terraform/`, `scripts/`, `gitops/`, `tests/` or `.github/` is modified.

## 9. Validation

Documents only; there is nothing to deploy and no cloud cost. Run
`make specs-check`, `make gitops-check` and `make secrets-check` from the
repository root, then the four `grep` sweeps of §8, then read `README.md`'s
index against each spec's front matter by hand, because `specs-check` does not
verify the index table.

## 10. AWS regression protection

No AWS or Civo file is touched. `git diff --stat` against the merge base lists
paths under `specs/hetzner/`, `docs/adr/`, `docs/architecture.md`,
`docs/hetzner-high-level-design.md`, `specs/shared/000-D-constitution/spec.md`
and `CLAUDE.md` only. The constitution edit changes Hetzner cells inside §20's
per-provider table and no rule that applies to AWS or Civo.

## 11. Rollout and rollback/recovery

The commit is the rollout. Reverting it restores the kubeadm package whole,
because nothing implements either design. There is no data, no running cluster
and no cloud resource at risk.

## 12. Risks and unresolved questions

- The join token in `user_data` and in Terraform state is a real exposure, not a
  wording change. It is bounded and recorded in ADR 0037; a `hostNetwork` pod on
  a compromised node can add a node to the cluster.
- Reusing the `0b6a638` text verbatim would silently revert the x86 `cx33` node
  shape, the four-node ceiling, `SUBDOMAIN=hz`, `secrets/hetzner-token.enc`,
  `kube-system/cloud-operator-secret` and the ADR numbering. Every reused
  paragraph is checked against HEAD before it lands.
- A missed reference to a renamed folder fails `specs-check` rule 10 rather than
  failing silently, which makes the rename safe but noisy.
- k3s pins the whole distribution in one variable, `INSTALL_K3S_VERSION`. A
  worker rendered with a different value than the control plane fails to join
  with little explanation. One variable renders both templates.
- k3s upgrades replace the binary in place and restart one service. The platform
  still owns the control plane; the operations work shrinks but does not vanish,
  and no spec now covers it. If a runbook is wanted later it is a new spec, not
  a revival of HETZ-185.
- Embedded etcd on a single node writes more than SQLite. The `cx33` local NVMe
  has ample headroom, but HETZ-150 should record etcd write latency once.

## 13. Definition of done

- [ ] Acceptance criteria met; `make specs-check`, `gitops-check`, `secrets-check` green
- [ ] ADR 0037 written; ADR 0036 noted; constitution §20 and architecture §10a updated
- [ ] Four specs retired, three rewritten, nine edited; package documents rewritten
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-20 — created as READY. The operator withdrew the certification goal
  that ADR 0036 used to reject k3s, and asked for the solution with the least
  code and the least operational work. Datastore, CNI and node shape settled in
  the same session: embedded etcd through `--cluster-init`, flannel, and the
  unchanged 2 × `cx33` fixed pool with a schedulable control plane.
