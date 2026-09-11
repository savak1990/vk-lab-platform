# Decisions

## 1. Accepted starting constraints (from the user, 2026-09-11)

| Constraint | Value |
|---|---|
| Operator surface | `PROVIDER=aws\|civo\|hetzner` on the existing `make` targets; default `aws`; no new lifecycle commands. The k3s bootstrap needs no target of its own: cloud-init runs inside `cluster-up`, and the readiness wait is part of the `cluster-up` script. The one Hetzner-only helper is `make node-ssh NODE=<name>` (HETZ-040), which prints a message and exits 0 on the other providers |
| Project identity | `PROVIDER=hetzner` defaults `PROJECT_NAME=vk-hetzner-lab`, `SUBDOMAIN=hetzner`: own state bucket, own zone `hetzner.<root-domain>`, own SSM prefix, own Roles Anywhere unit. Account layer shared |
| Goal | Maximise CPU and memory for 50–100 USD per month; Hetzner replaces only the compute path, AWS keeps Route 53, SSM, KMS, S3, GitHub OIDC |
| Kubernetes | Self-bootstrapped k3s on `hcloud_server`s (no managed offering exists); Terraform owns the servers; `argo-up` helm-installs the CCM before Argo CD (nothing schedules until it runs); Argo CD owns everything else in-cluster, including the CSI driver |
| Node plan (M1) | Three `cax21` ARM servers (4 vCPU / 8 GB each) in `nbg1`; server 1 is a schedulable k3s server, 2–3 are agents; autoscaler in M2 |
| Location | `nbg1`, network zone `eu-central`; declared once per layer, never derived |
| AWS access from workloads | IAM Roles Anywhere, same chain as Civo, names parametrized by provider (HETZ-018) |
| Kubeconfig | SSH with a KMS-encrypted private key committed as `secrets/<project>/hetzner-ssh-key.enc`; public key in Terraform |
| Hetzner token | KMS-encrypted in repo (`secrets/hcloud-token.enc`), decrypted at run time, masked in CI; **also** placed in `kube-system/hcloud` by `argo-up` because CCM and CSI need it |
| Persistence | Logical dumps to S3 (ADR 0031) — Hetzner CSI has no snapshot or clone either |
| TLS | cert-manager at Envoy, wildcard through DNS-01 (Civo end state); HTTP-01 never used on Hetzner |
| AWS and Civo regression | both stay byte-identical; golden renders for `aws` and `civo`, `make -n` identity for both |

## 2. Proposed ADRs and amendments (HETZ-015)

| ADR | Title | Conflict it resolves | Rationale | Reversibility |
|---|---|---|---|---|
| 0032 (next free; `specs/local/` also claims it — renumber on landing) | Hetzner as a third disposable target with a self-bootstrapped k3s control plane | architecture §10a (three targets), constitution §3/§18 scope, "Terraform never touches Kubernetes" vs. cloud-init installing k3s | cloud-init installs only the k3s binary and its flags; no Kubernetes object is created by Terraform; CCM/CSI go through Argo; the control plane is Disposable | high: delete the stacks |
| 0030 amendment | Provider API token handling | Civo token never enters the cluster; Hetzner's must (CCM, CSI, autoscaler) | per-*project* tokens bound the blast radius to the lab project; `argo-up` creates `kube-system/hcloud` untracked; a Secret reader gains the whole Hetzner project and nothing else; rotation = delete token, re-encrypt, `argo-up` | high |
| 0029 note | Roles Anywhere on a target where OIDC federation is possible | 0029 says federation is impossible; on self-managed k3s `--service-account-issuer` can point at a public S3 discovery document | Roles Anywhere kept: it reuses CIVO-080 to CIVO-110 verbatim and one identity mechanism across non-EKS targets; federation recorded as the documented alternative | medium |
| 0024 note | Hetzner location constant | single-region rule | `nbg1` declared in `root.hcl` and `scripts/lib/region.sh`; AWS region unchanged | high |
| Constitution §20 | Per-provider variant table | §20 is written for Civo only | one row per section per provider; Hetzner adds: control plane is platform-owned; LB has no firewall; §16 tagging fully satisfied through hcloud labels | high |
| architecture §10a | four execution targets | text says three | add Hetzner column | high |
| ADR 0002 note | ExternalDNS ownership | per project | zone `hetzner.<root-domain>`, `txtOwnerId=vk-hetzner-lab` | high |
| ADR 0022 note | Kubernetes access on Hetzner | EKS access entries / Civo API | admin kubeconfig fetched over SSH; test identity via ServiceAccount token | medium |

## 3. Open decisions

| Decision | Options | Recommendation | Trade-offs | Reversible | Affected specs | Blocks READY |
|---|---|---|---|---|---|---|
| Node shape | (a) 3 × CAX21 ARM; (b) CAX11 + 2 × CAX21; (c) 3 × CX33 x86; (d) 3 × CPX22 x86 | **Decided 2026-09-11: (a).** ≈43 EUR/month for ~21 GiB; every platform image publishes arm64 | CAX stock is limited since 2026-09-02; HETZ-175 defines the CPX fallback; `pg-backup` must be built multi-arch (HETZ-182) | high | 030, 160, 175, 182 | no |
| Location | nbg1 / fsn1 / hel1 | **Decided 2026-09-11: nbg1** | none material; all `eu-central` | high | 025, 030 | no |
| Kubeconfig retrieval | (a) SSH with a KMS-encrypted key; (b) pre-generated k3s CA, kubeconfig minted locally | **Decided 2026-09-11: (a).** Also gives node access for debugging a self-managed cluster | (b) would put the CA bundle in `user_data`, readable from the metadata service by any `hostNetwork` pod, and needs a per-cluster key stored somewhere | high | 025, 040 | no |
| Identity chain naming | (a) parametrize by provider, Civo unchanged; (b) reuse `civo` names verbatim; (c) rename provider-neutral now | **Decided 2026-09-11: (a).** The trust anchor is per project (bootstrap unit), so one anchor per provider is the existing shape | (c) would touch the live Civo trust anchor and committed Civo secrets | high | 018, 080 | no |
| Control-plane topology | (a) 1 schedulable server + 2 agents, SQLite; (b) 3 servers, embedded etcd | (a) for M1: simplest, full capacity, one node to SSH; API downtime on a control-plane reboot is acceptable for a lab | (b) costs no money but doubles the cloud-init and the failure modes; revisit if HETZ-150 shows control-plane flakiness | medium | 030 | no |
| CCM before Argo | (a) Argo CD tolerates the uninitialized taint and installs CCM/CSI as wave −3 Applications; (b) `argo-up` helm-installs the CCM before Argo CD, CSI stays an Argo Application; (c) k3s auto-deploy manifest in `/var/lib/rancher/k3s/server/manifests` | **Decided 2026-09-11: (b) for the CCM only.** (a) deadlocks: k3s's bundled CoreDNS tolerates only `CriticalAddonsOnly` and the control-plane taint (verified in `manifests/coredns.yaml`), so a tainted cluster has no DNS, Argo CD cannot reach its repo-server or GitHub, and the CCM is never installed. The CCM chart itself tolerates the taint and runs `hostNetwork` with `dnsPolicy: Default` when `networking.enabled`, so it needs neither DNS nor an initialised node. It joins Argo CD in the untracked-bootstrap class the script already owns. (c) makes Terraform own a Kubernetes object | one more helm release outside Argo; upgrades go through `argo-up` like Argo CD's own | high | 045, 050 | no (ordering proven end to end in 020) |
| metrics-server | (a) keep k3s bundled; (b) `--disable metrics-server` and install via Argo | (a) for M1: same posture as Civo's built-in one | Argo does not own it; acceptable for a bundled k3s addon | high | 030, 160 | no |
| Control-plane metrics | expose scheduler/controller-manager/etcd metrics on the private address via k3s flags | yes: educational value, no cost; scrape targets on the private IP only | more cloud-init flags | high | 030, 160 | no |
| SSH port 22 exposure | (a) 0.0.0.0/0, key-only; (b) operator/CI IP allowlist | (a): GitHub runners have no fixed IP, same reasoning as 6443 on Civo; password auth is off on Ubuntu 24.04 | brute-force noise in `auth.log`; consider fail2ban later | high | 030 | no |
| Stable LB address | (a) accept a new LB IP per `make up`, rely on ExternalDNS; (b) Terraform-owned LB with `hcloud_load_balancer` and label-selector targets | (a): the CCM cannot adopt an existing LB; (b) would make Terraform own an ingress object Argo also reconciles | DNS-01 removes the HTTP-01 ordering flake; DNS TTL is the only propagation delay | high | 060, 070 | no |
| Autoscaler credential | join token and Hetzner token in-cluster | M2; the Hetzner token is in-cluster already for CCM; the autoscaler adds only the join token; a dedicated second token for the autoscaler is optional | anyone reading the Secret can add a node | high | 170 | no |
| CI provider runs | enable `PROVIDER=hetzner` in `lab.yml` now vs later | now, behind the environment and concurrency group, after HETZ-150 passes once by hand | account default limit of 5 servers: CI and lab cannot both run 3-node clusters until a limit increase | high | 140 | no |

## 4. Rejected alternatives

- `kube-hetzner` Terraform module: installs CCM, CSI, CNI, cert-manager, autoscaler from Terraform, which violates the Terraform/Argo ownership split and duplicates Argo-owned components.
- `hetzner-k3s` CLI: no Terraform state, so the lifecycle scripts, guards and leak sweeps would have nothing to bind to.
- Hetzner Object Storage for dumps: 6.49 EUR/month minimum against S3 at cents.
- IPv6-only nodes: SSM Parameter Store has no IPv6 endpoint and Hetzner has no managed NAT; one primary IPv4 per node costs 0.50 EUR.
- Floating IP for the LB: the CCM cannot attach one to a load balancer.
- x86 CPX as the default: 3 × CPX22 costs about what Civo costs for less memory; it is the stock fallback only.
- OIDC federation instead of Roles Anywhere: possible on k3s but discards six DONE Civo specs; documented as the alternative in ADR 0029's note.
- Static AWS access keys anywhere: forbidden by constitution §5.
