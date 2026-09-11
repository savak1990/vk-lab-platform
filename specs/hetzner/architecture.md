# Hetzner target: what changes, coupling inventory, and change map

Companion to `docs/civo-high-level-design.md` (the shared non-EKS model)
and `specs/civo/architecture.md` (the Civo coupling inventory). Baseline:
branch `civo-115-cnpg-cluster-on-civo`, 2026-09-11. Paths marked
*(proposed)* do not exist yet.

## 1. What Hetzner is, in one paragraph

Hetzner Cloud sells servers, private networks, firewalls, load balancers
and volumes over one API, priced far below EKS and, on ARM, below Civo.
It sells no Kubernetes. The platform therefore owns the control plane: a
cloud-init script installs k3s on the first server, the other servers join
over the private network. `argo-up` helm-installs the Hetzner cloud
controller manager (CCM) before Argo CD, because no node schedules
anything until the CCM runs, and Argo CD then installs the CSI driver as
an ordinary Application. Civo pre-installs both. Everything above that
line — Envoy, cert-manager, ESO, ExternalDNS, CNPG, observability, the
Roles Anywhere identity chain, logical dumps to S3 — is the Civo design,
reused through the generalisation specs HETZ-016 and HETZ-018.

## 2. Target flow (condensed)

```
make bootstrap-up  → state bucket, Route 53 hetzner zone, Roles Anywhere unit   (bootstrap, ACM excluded)
make persistent-up → SSM secrets, S3 backup bucket                               (persistent, VPC excluded)
                   + hcloud network/subnet, hcloud SSH key                        (terraform/live/persistent-hetzner)
make cluster-up    → hcloud firewall, 3 × CAX21 servers, cloud-init k3s           (terraform/live/cluster-hetzner)
                   → wait for nodes Ready via SSH-fetched kubeconfig              (scripts, HETZ-040)
make argo-up       → SSM read → kubeconfig → hcloud Secret → helm hcloud CCM
                   → wait for the uninitialized taint to clear → CA Secret
                   → helm argocd → helm root-application(target=hetzner)         (scripts/argo-up.sh)
Argo root          → CSI (wave -3) → ESO → Envoy → cert-manager → …              (gitops/templates/platform/{shared,hetzner})
make argo-down     → dump → Envoy Service delete, LB-gone wait → DNS wait → cascade
make cluster-down  → terragrunt destroy → label-based leak sweep                 (scripts/cluster-down.sh)
```

## 3. Coupling inventory: Civo package → Hetzner

Classification: **reuse** = Civo output consumed as-is; **generalise** =
HETZ-016/018 turn a Civo branch into a non-AWS or per-provider form;
**mirror** = a Hetzner spec covers the same ground; **new** = no Civo
equivalent; **n/a** = not applicable on Hetzner.

| Component | Civo implementation | Hetzner difference | Classification | Owning spec |
|---|---|---|---|---|
| Make surface, `provider.sh`, token helper | `PROVIDER=aws\|civo`, `civo_token()` | third value; `hcloud_token()` exporting `HCLOUD_TOKEN`; `secrets/hcloud-token.enc` | mirror | 010 |
| Governance | ADRs 0027–0031, constitution §20 (Civo) | ADR 0032 (self-bootstrapped k3s); §20 becomes per-provider; ADR 0030 amended (token lives in-cluster); ADR 0029 note (federation possible, rejected) | mirror | 015 |
| Script branches `[ "$PROVIDER" = civo ]` | CA Secret, TLS export/import, no EBS snapshot, kinds filter, PVC wait, teardown dump gate | semantics are "non-EKS"; become `!= aws` | generalise | 016 |
| GitOps gates `eq .Values.target "civo"` (11 sites), `validateTarget`, render-check sets | literal `civo` | `platform.selfManaged` helper (civo, hetzner); `hetzner` in the allowed list; per-target required/forbidden sets | generalise | 016 |
| Identity chain names | `${project}-civo-workload-ca`, CN `${project}-civo-${consumer}`, `civo-workload-ca` Secret/ClusterIssuer, `secrets/<project>/civo-ca-*`, `make civo-ca-init`, `civoIdentity.consumers` | `${project}-${provider}-…`; Civo strings byte-identical; `make ca-init` with `PROVIDER` | generalise | 018 |
| State backend | own bucket per project | `vk-hetzner-lab-tf-state` via unchanged `state-up` | reuse | 010 |
| Provider generation, lifecycle lookup | `provider "civo"` when `path_parts[0]` ∈ civo stacks; `civo_region = "LON1"` | `provider "hcloud" {}` (token from env) for `persistent-hetzner`, `cluster-hetzner`; `hcloud_location = "nbg1"` | mirror | 025 |
| Region constant | `LON1` in `root.hcl`, `scripts/lib/region.sh` | `nbg1` (`HCLOUD_LOCATION`), network zone `eu-central`; AWS region unchanged | mirror | 025 |
| Bootstrap route53 / acm | zone `civo.<root>`; ACM excluded | zone `hetzner.<root>`; ACM excluded | reuse | 025 |
| Roles Anywhere unit | per project, guarded by `fileexists` on the CA cert | same unit under the Hetzner project; names from 018 | reuse | 080 |
| Persistent network | `civo_network`, free | `hcloud_network` + `hcloud_network_subnet` (`eu-central`, `10.0.0.0/16`), free | mirror | 025 |
| Reserved IP | `civo_reserved_ip` for the LB | **none**: primary IPs attach to servers only; the LB owns its address and gets a new one per `make up` | n/a | 025, 060 |
| SSH key | — | `hcloud_ssh_key` from a committed public key; private key `secrets/<project>/hetzner-ssh-key.enc` | new | 025 |
| Cluster | `civo_kubernetes_cluster` (managed) | `hcloud_firewall` + 3 × `hcloud_server` (`cax21`, `ubuntu-24.04` arm64) with cloud-init installing k3s; server 1 runs `k3s server`, 2–3 run `k3s agent` | new | 030 |
| Capacity | fixed pool of three Medium | fixed three CAX21 (4 vCPU / 8 GB); autoscaler 0–2 extra in M2 | mirror | 030, 170 |
| Kubeconfig | `civo kubernetes config` | `ssh root@<cp> cat /etc/rancher/k3s/k3s.yaml`, server rewritten to the public IP | new | 040 |
| Readiness | `kubectl get nodes` (provider `ready` unreliable) | Terraform returns when servers exist, not when k3s is up; scripts wait for 3 nodes Ready | mirror | 040 |
| Leak sweep | `civo` CLI by name/network | `hcloud` CLI by label `project=<project>` over servers, load balancers, volumes, primary IPs, firewalls | mirror | 040 |
| CCM | pre-installed by Civo | helm release installed by `argo-up` before Argo CD (untracked bootstrap class, like Argo CD itself); `kube-system/hcloud` Secret (keys `token`, `network`) created by `argo-up` | new | 045 |
| CSI | pre-installed by Civo | Argo Application at wave −3 under `platform/hetzner/`; reads the same `hcloud` Secret | new | 050 |
| Storage | `civo-volume` (k3s addon, cannot be edited) | `hcloud-volumes` from the CSI chart (Argo-owned; reclaim `Delete`; 10 GB minimum; no snapshot/clone) | mirror | 050 |
| Snapshot controller | aws-only | aws-only | n/a | 050 |
| Load balancing | Civo LB via `kubernetes.civo.com/*` | LB11 via `load-balancer.hetzner.cloud/{location,type,name,use-private-ip,ipv6-disabled}`; no firewall on LBs; k3s `servicelb` disabled | mirror | 060 |
| TLS | HTTP-01 then DNS-01 wildcard (CIVO-075) | start at the DNS-01 end state; HTTP-01 never used | reuse | 070 |
| DNS | ExternalDNS via sidecar, waits on the reserved IP | same chart; waits use the discovered LB address | reuse + branch | 070 |
| Workload identity | Roles Anywhere chain, x86 sidecar digest | same chain; CA ceremony and Roles Anywhere unit for the Hetzner project (080); certificates and multi-arch sidecars (085) | reuse | 080, 085 |
| PostgreSQL | CNPG on `civo-volume`, logical dumps to S3 | CNPG on `hcloud-volumes`; same dumps; `pg-backup` image must be arm64 | mirror | 115, 120, 182 |
| Observability | control-plane scrapes off (managed k3s hides it) | control-plane scrapes **on** (k3s flags bind scheduler/controller-manager/etcd metrics); k3s bundled metrics-server kept; 10 GB volume floor | mirror | 160 |
| Tests | SA-token context `${PROJECT_NAME}-civo-test` | `${PROJECT_NAME}-hetzner-test` | mirror | 130 |
| CI | `lab.yml` provider input aws\|civo | three values; `hcloud` CLI; cleanup sweeps volumes/LBs/IPs | mirror | 140 |
| Backups, AWS migration, promotion | CIVO-180/185/186 | provider-neutral; `FROM/TO` enum gains `hetzner` in 010 | reuse | — |
| Identity hardening, least privilege, login | CIVO-200/205/210 | provider-neutral | reuse | — |
| Tagging §16 | Civo `tags` string, best-effort | hcloud `labels` map on every resource: full §16 compliance possible | mirror | 015, 025, 030 |

## 4. Provider contract (Hetzner column)

Adds to `docs/civo-high-level-design.md` §5.

| Name | Type | Source of truth | Default | Secret | Reaches Argo/Helm via |
|---|---|---|---|---|---|
| `PROVIDER` | enum aws\|civo\|hetzner | operator/CI input | `aws` | no | `--set target` |
| `PROJECT_NAME` | string | operator input | `vk-hetzner-lab` | no | `--set project` |
| `SUBDOMAIN` | string | operator input | `hetzner` | no | via SSM `fqdn` |
| `HCLOUD_TOKEN` | string | `secrets/hcloud-token.enc` | — | yes | Terraform/CLI env; **and** `kube-system/hcloud` Secret created by `argo-up` |
| Hetzner location | constant | `root.hcl` (`hcloud_location`), `scripts/lib/region.sh` (`HCLOUD_LOCATION`) | `nbg1` | no | `envoyGateway.location` |
| SSH private key | file | `secrets/<project>/hetzner-ssh-key.enc` | — | yes | never; scripts only |
| k3s join token | string | generated per `make up` by Terraform, in `user_data` | — | yes (disposable) | never |
| `controlPlaneIp` | IPv4 | SSM `/<project>/cluster-hetzner/k8s/control_plane_ip` *(proposed)* | — | no | scripts only |
| `networkId` | string | SSM `/<project>/persistent-hetzner/network/network_id` *(proposed)* | — | no | `hcloud` Secret key `network` |
| `storage.className` | string | values per target | `hcloud-volumes` | no | direct |
| `awsIdentity.mode` | enum | values per target | `rolesAnywhere` | no | direct |
| `externalDns.txtOwnerId` | string | values | `vk-hetzner-lab` | no | direct |

Provider-specific configuration (server types, cloud-init, LB annotations,
CCM/CSI charts) never leaves `terraform/live/*-hetzner`,
`terraform/modules/hcloud-*` and `gitops/templates/platform/hetzner/`.

## 5. State, lifecycle, ownership

- Terraform owns the network, subnet, SSH key, firewall, servers and their
  primary IPs. The CCM owns load balancers and the CSI driver owns volumes;
  both are Argo-installed controllers, so their resources are deleted by
  Kubernetes reconciliation while the controllers run, and swept by label
  afterwards as defence. Autoscaler-created servers (M2) are outside
  Terraform and are swept the same way.
- `argo-up` creates exactly three untracked Secrets on Hetzner: the CA key
  (as on Civo), the optional re-imported TLS Secret (as on Civo), and
  `kube-system/hcloud` (new), plus one untracked helm release, the hcloud
  CCM, in the same class as the Argo CD release. Nothing else in-cluster is
  outside Argo. The `lab-role` SSM ARNs gain `*/persistent-hetzner/*` and
  `*/cluster-hetzner/*`, applied by `account-up` outside the composites.
- The k3s join token and the cloud-init that carries it are in Terraform
  state and readable from the node's metadata service. Both are regenerated
  on every `make up` and die with the cluster; they never grant anything
  outside the cluster. No long-lived secret is ever placed in `user_data`.
- State keys under `vk-hetzner-lab-tf-state/`:
  `bootstrap/{route53,rolesanywhere}`, `persistent/{secrets,backups}`,
  `persistent-hetzner/{network,ssh-key}`, `cluster-hetzner/{firewall,k8s}`.
- Concurrency: S3 lockfiles per unit; CI concurrency group
  `lab-<project>-hetzner`.

## 6. Bootstrap ordering on a self-managed cluster

Two traps have no Civo precedent and shape 030, 045 and 050:

1. **The uninitialised taint.** k3s starts the kubelet with
   `cloud-provider=external`, so every node carries
   `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` until the
   CCM sets its `providerID`. Nothing schedules before the CCM — not even
   k3s's bundled CoreDNS, which tolerates only `CriticalAddonsOnly` and the
   control-plane taint. Argo CD therefore cannot be the installer: without
   DNS it can neither reach its repo-server nor GitHub. Resolution:
   `argo-up` helm-installs the CCM chart (it tolerates the taint and runs
   `hostNetwork` with `dnsPolicy: Default` when `networking.enabled`), waits
   for the taint to clear on all nodes, then installs Argo CD as today. The
   CSI driver has no such constraint and stays an Argo Application.
2. **Terraform returns before Kubernetes exists.** `hcloud_server` is
   complete when the server boots, not when cloud-init finishes. The
   scripts, not Terraform, wait for three Ready nodes over the SSH-fetched
   kubeconfig, with a bounded timeout.

## 7. Decision areas (mapping to specs)

| Area | Decision summary | Specs |
|---|---|---|
| A boundary/state/contract | own project `vk-hetzner-lab`; `-hetzner` stack dirs; contract above | 010, 025, 030, 050 |
| B lifecycle and Argo | same stage model; non-AWS branches generalised; CCM helm-installed by `argo-up` before Argo CD | 016, 040, 045 |
| C cluster/networking/ingress | firewall 22 + 6443 public, everything else private; LB11 with private-IP targets; no reserved IP | 025, 030, 060 |
| D storage/CNPG | `hcloud-volumes`; logical dumps; no snapshots | 050, 115, 120 |
| E capacity | 3 × CAX21 ARM; autoscaler 0–2 in M2; stock fallback to CPX | 030, 170, 175 |
| F identity/secrets | Roles Anywhere per project, names per provider; ceremony before the first `bootstrap-up`; token in-cluster | 018, 080, 085, 015 |
| G destruction/recovery | label sweep for LBs, volumes, IPs, extra servers | 040, 140, 150 |
| H tests/CI/cost | Ginkgo reuse; `lab.yml`; cost model in `research.md` | 130, 140, 175 |
