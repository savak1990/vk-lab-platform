# Research: Hetzner Cloud — verified capabilities, prices, and uncertainties

All items accessed 2026-09-11 unless stated. Confidence: **high** = official
doc or source code states it; **medium** = official doc implies it, a maintained
README states it, or a dated third-party price reading agrees with a second
source; **low** = inferred, needs the spike.

Prices are EUR excl. VAT (German list prices; +19 % VAT for a German
customer, reverse-charge for EU VAT-registered businesses). Hetzner publishes
USD equivalents in its own price-adjustment table; those are quoted where
available. Hetzner's own pricing pages (`hetzner.com/cloud`, `/cloud/load-balancer`,
`/cloud/block-storage`) render prices client-side and were unreadable through
fetch; the numbers below therefore come from Hetzner's docs price table (high)
and dated third-party readings of the pricing page (medium).

## Hetzner

| Topic | Finding | Source | Confidence |
|---|---|---|---|
| **Price shocks in 2026** | Two increases this year. **1 April 2026**: all products, incl. existing subscriptions, ~30–37 % (LB11 5.39→7.49; Object Storage base 4.99→6.49). **15 June 2026**: cloud servers again, new orders and rescales only; CX/CAX +30–40 %, **CPX ×2.4–2.75, CCX ×2.1–2.7**. A disposable cluster is a new order on every `make up`, so it always pays the newest price | https://www.hetzner.com/pressroom/statement-price-adjustment/ ; https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/ ; https://www.igorslab.de/en/hetzner-to-significantly-increase-prices-for-cloud-and-dedicated-servers-from-april-2026/ | high |
| **Cheap lines are stock-limited** | Since 2 Sept 2026 the Cost-Optimized page marks CX23–CX53 and CAX11–41 "not available"; Hetzner calls it a capacity limit of "proven hardware generations", not a discontinuation. Live tracker at 2026-09-11 16:10 UTC: **CX33/43/53 sold out in nbg1/fsn1/hel1, CX23 "limited"; CAX11–41 available in all three; CPX12–62 available.** Stock changes hour to hour; CX23 has sold out within 20 min–3 h of restock. **Real creates on 2026-09-19 (project's own token, `--start-after-create=false`, deleted at once): `cx23` OK in nbg1/fsn1/hel1; `cx33` OK in nbg1/fsn1/hel1; `cax11` and `cax21` FAIL in nbg1 and hel1 with `hcloud: unsupported location for server type (invalid_input)`.** The API's per-type `locations[].available` flag is not trustworthy either way: it said `false` for `cx23`/`cx33` in locations where the create succeeded and the datacenter list said CAX was available where the create failed. `cx22` no longer exists in the catalogue; `cpx11` is deprecated in the EU locations (`unavailable_after` 2025-12-31) | https://stackvaluelab.com/hetzner-cx-cax-unavailable/ ; https://hetzner.thegoated.dev/ ; https://radar.iodev.org/cloud-status (403 to fetch) ; real creates 2026-09-19 | high (real creates, this date) / medium (trackers) |
| Server prices, Germany/Finland, after 15 June 2026 (EUR/month, hourly, USD/month) | **CX (Intel shared, Gen3)**: CX23 2 vCPU/4 GB/40 GB **5.49** (0.0088/h, $6.49); CX33 4/8/80 **8.49** (0.0136, $9.99); CX43 8/16/160 **15.99** (0.0256, $18.49); CX53 16/32/320 **29.49** (0.0473, $34.99). **CAX (Ampere Altra ARM)**: CAX11 2/4/40 **5.99** (0.0096, $6.99); CAX21 4/8/80 **10.49** (0.0168, $12.49); CAX31 8/16/160 **20.99** (0.0336, $24.99); CAX41 16/32/320 **40.99** (0.0657, $48.49). **CPX (AMD EPYC shared)**: CPX22 2/4/80 **19.49**; CPX32 4/8/160 **35.49**; CPX42 8/16/320 **69.49**; CPX52 12/24/480 **100.49**; CPX62 16/32/640 **129.99**. **CCX (dedicated)**: CCX13 2/8 **42.99**; CCX23 4/16 **85.99**; CCX33 8/32 **138.49**. Prices exclude the primary IPv4 (+0.50). **API `price_monthly.net` on 2026-09-19, eu-central, EUR: CX23 6.49, CX33 9.99 (0.0160/h), CX43 18.49; CAX11 6.99, CAX21 12.49; CPX12 13.49, CPX22 22.99, CPX31 20.49** — about 18 % above the June table for CX/CAX; use the API figures for the cost model | https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/ (specs from https://www.bitdoze.com/hetzner-cloud-cost-optimized-plans/) ; `hcloud server-type list -o json` 2026-09-19 | high (API prices, this date) / medium (specs) |
| Server availability by location | CX and CAX: **eu-central only** (fsn1, nbg1, hel1) plus CX in Singapore per one source; **US (ash, hil) and Singapore have CPX/CCX only**. Hetzner's docs locations table confirms "Cloud Shared AMPERE" and "INTEL/AMD" rows exist but the per-location ticks were not machine-readable | https://docs.hetzner.com/cloud/general/locations/ ; https://costgoat.com/pricing/hetzner ; https://www.bitdoze.com/hetzner-cloud-cost-optimized-plans/ | medium |
| Locations and network zones | fsn1 Falkenstein, nbg1 Nuremberg, hel1 Helsinki → `eu-central`; ash Ashburn → `us-east`; hil Hillsboro → `us-west`; sin Singapore → `ap-southeast`. Networks, LB targets and Floating IPs must stay inside one network zone; IP-based LB targets only in eu-central | https://docs.hetzner.com/cloud/general/locations/ | high |
| Primary IPv4 | **0.50 EUR/month per address**, billed for every Primary IP that finished creation **even when unassigned**; IPv6 /64 free. An `hcloud_server` without a `public_net` block auto-creates one IPv4 and one IPv6 Primary IP; `ipv4_enabled=false` gives an IPv6-only server. Primary IPs can be detached before server deletion and survive it (`auto_delete=false` recommended by the provider docs) | https://docs.hetzner.com/cloud/servers/overview/ ; https://docs.hetzner.com/cloud/billing/faq/ ; https://github.com/hetznercloud/terraform-provider-hcloud/blob/main/docs/resources/server.md ; .../primary_ip.md | high |
| Floating IP | Billed monthly, pro-rated; price not readable (pre-April was 3.00 EUR/month for IPv4). A **Primary IP at 0.50/month is the cheaper "reserved IP"** for the Civo-style stable-address decision | https://docs.hetzner.com/cloud/billing/faq/ | medium |
| Load balancer | LB11: 5 services, 25 targets, 10 managed certs, 1 TB traffic; LB21: 15/75/25, 2 TB; LB31: 30/150/50, 3 TB. All six locations. **LB11 = 7.49 EUR/month (0.0120/h) since 1 April 2026; excluded from the June round.** Each LB has its own public IPv4 + IPv6 and a private IP when attached to a network. Location/network-zone is immutable: recreating an LB gives a **new IP**. Firewalls attach to servers only — the LB has no firewall; it exposes only its configured services | https://www.hetzner.com/cloud/load-balancer/ (limits) ; https://agentdeals.dev/hetzner-pricing-2026 and https://ubos.tech/news/hetzner-price-adjustment-updated-cloud-costs-effective-april-2026/ (price) ; https://docs.hetzner.com/cloud/load-balancers/faq/ ; https://github.com/hetznercloud/terraform-provider-hcloud/blob/main/docs/resources/firewall.md (`apply_to` = server or label_selector only) | high (limits, firewall) / medium (price) |
| Volumes | 10 GB–10 TB in 1 GB steps, up to 16 per server, location-bound, triple-replicated, online grow only. **No Hetzner-side snapshots or backups for volumes.** Price after April: **≈0.0572 EUR/GB/month** (one Sept 2026 reading; pre-April list was 0.044). Volume survival after server deletion is not stated in the docs FAQ; the API models volumes as independent resources with an optional `server` field, so survival is expected — **spike must verify**, as CIVO-020 did | https://docs.hetzner.com/cloud/volumes/overview/ ; https://docs.hetzner.com/cloud/volumes/faq/ ; https://costgoat.com/pricing/hetzner (price) | high (limits) / medium (price) / low (survival) |
| Snapshots / backups (servers) | Server snapshots 0.0143 EUR/GB/month (compressed size); automatic backups 20 % of server price, 7 slots. Neither includes attached volumes | https://docs.hetzner.com/cloud/billing/faq/ ; https://costgoat.com/pricing/hetzner | medium |
| Traffic | Outgoing only is billable; shared servers include 20 TB/month in EU (CPX in US 1–8 TB, SIN 0.5–8 TB); overage 1 EUR/TB (EU/US), 7.40 EUR/TB (SIN), billed in 100 MB blocks. Ingress and private-network traffic free. LB includes 1–3 TB by type | https://docs.hetzner.com/cloud/billing/faq/ ; https://costgoat.com/pricing/hetzner ; https://www.bitdoze.com/hetzner-cloud-cost-optimized-plans/ | medium |
| Networks, firewalls, SSH keys, placement groups | No price line anywhere; billing FAQ lists only servers, IPs, volumes, snapshots, backups, traffic, LBs, object storage. Treated as free; spike should confirm on the invoice as CIVO-020 did | https://docs.hetzner.com/cloud/billing/faq/ | medium |
| Object Storage | S3-compatible; **fsn1, hel1, nbg1 only**; base price includes 1 TB storage + 1 TB egress, billed hourly, capped monthly; **base 6.49 EUR/month since April** (was 4.99). 100 buckets, 100 TB/bucket. Same shape as Civo's 500 GB minimum: too big for a few GB of dumps — keep AWS S3 (ADR 0031) | https://www.hetzner.com/storage/object-storage/ ; https://www.igorslab.de/en/hetzner-to-significantly-increase-prices-for-cloud-and-dedicated-servers-from-april-2026/ | high (shape) / medium (price) |
| Billing shape | Hourly, **rounded up to the full hour**; monthly cap per resource; billing stops on deletion. Same as Civo | https://docs.hetzner.com/cloud/billing/faq/ | high |
| Default limits | "Up to 5 servers" by default (docs overview); Primary IP limit = server limit × 2; other limits shown in Console → Limits; increases via ticket, **only after one month as a customer and a paid first invoice**; 1–3 business days. A brand-new account may therefore not be able to run 3 nodes + autoscaler headroom | https://docs.hetzner.com/cloud/servers/overview/ ; https://docs.hetzner.com/cloud/servers/faq/ ; https://docs.hetzner.com/cloud/servers/primary-ips/overview/ | medium |
| API rate limit | 3600 requests/hour per project, refilled at 1/s; `RateLimit-Limit/Remaining/Reset` headers; HTTP 429 on exhaustion. The provider's `poll_interval` (default 500 ms, exponential) exists for this; the cluster autoscaler has a history of eating the whole budget | https://docs.hetzner.cloud/reference/cloud (via search summary) ; https://github.com/kubernetes/autoscaler/issues/4133 | high |
| **API token / auth** | Tokens are **per project**, created in Console → Security → API tokens; permission is **Read** (GET only) or **Read & Write** (GET/POST/PUT/DELETE) — **no finer scopes**; shown once; **no expiry option documented**; static until deleted. Projects are Console objects — **no `POST /projects` in the API**, so a project is a manual bootstrap step. Header `Authorization: Bearer <token>` | https://docs.hetzner.com/cloud/api/getting-started/generating-api-token/ ; https://docs.hetzner.cloud/reference/cloud | high (per-project, R/RW) / medium (no expiry, no project API — absence of a doc, not a statement) |
| Terraform provider | `hetznercloud/hcloud` **v1.69.0** (2026-09-11; Terraform ≥1.15 support, dropped 1.14). Provider args: `token` (or **`HCLOUD_TOKEN`** env — use the env var, never the argument, to keep it out of tfvars), `endpoint`, `endpoint_hetzner`, `poll_interval`, `poll_function`. `datacenter` removed since v1.67 → use `location` | https://github.com/hetznercloud/terraform-provider-hcloud/blob/main/docs/index.md ; https://github.com/hetznercloud/terraform-provider-hcloud/releases | high |
| `hcloud_server` | Required: `name` (unique, RFC 1123 hostname), `server_type`, `image`. Optional: `location`, `user_data` (**≤32 KiB**, cloud-init), `ssh_keys` (immutable after create — change forces replace; **if omitted, Hetzner e-mails a root password**, and Ubuntu ≥22.04 images disable password SSH anyway), `public_net { ipv4_enabled, ipv6_enabled, ipv4/ipv6 (primary IP ids) }`, `network { network_id | subnet_id, ip, alias_ips }` (set `alias_ips = []` to avoid a known detach/attach churn bug), `firewall_ids`, `placement_group_id`, `labels`, `backups`, `keep_disk`, `delete_protection`+`rebuild_protection`, `shutdown_before_deletion` | https://github.com/hetznercloud/terraform-provider-hcloud/blob/main/docs/resources/server.md ; https://docs.hetzner.com/cloud/servers/faq/ | high |
| `hcloud_network` / `_subnet` | `hcloud_network { name, ip_range }` (private, IPv4 only, max 100 servers/network per community reports); `hcloud_network_subnet { network_id, type = "cloud", network_zone = "eu-central", ip_range }`. Servers and LBs attach by `network` block / `hcloud_load_balancer_network`; the LB private IP is auto-assigned | provider docs `network.md`, `network_subnet.md`, `load_balancer_network.md` ; https://lowendtalk.com/discussion/187187 (100-server limit) | high / medium (limit) |
| `hcloud_firewall` | `name`, `labels`, repeated `rule { direction in|out, protocol tcp|udp|icmp|gre|esp, port (single, range, or any), source_ips / destination_ips (list, IPv4 and IPv6 CIDRs), description }`, `apply_to { server = id | label_selector = "k=v" }`. **Default-deny inbound when attached; outbound allowed unless an `out` rule exists** (then default-deny outbound — same UDP/53 trap CIVO-030 hit). Attaches to **servers only** | https://github.com/hetznercloud/terraform-provider-hcloud/blob/main/docs/resources/firewall.md ; https://docs.hetzner.com/cloud/firewalls/overview/ | high |
| `hcloud_load_balancer` and friends | `hcloud_load_balancer { name, load_balancer_type ("lb11"), location | network_zone, algorithm { type }, delete_protection }` → attributes `ipv4`, `ipv6`, `network_ip`; `hcloud_load_balancer_service { protocol tcp|http|https, listen_port, destination_port, proxyprotocol, health_check {…}, http {…} }`; `hcloud_load_balancer_target { type server|label_selector|ip, use_private_ip }`; `hcloud_load_balancer_network`. Not needed when the CCM owns the LB (Argo/Service path), listed for a Terraform-owned alternative | provider docs `load_balancer*.md` | high |
| `hcloud_primary_ip`, `hcloud_floating_ip`, `hcloud_volume`, `hcloud_ssh_key`, `hcloud_placement_group` | `hcloud_primary_ip { name, type ipv4|ipv6, location, assignee_type "server", assignee_id, auto_delete (keep false), delete_protection }` → `ip_address`; `hcloud_volume { name, size (GB, ≥10), location | server_id, automount, format xfs|ext4 }`; `hcloud_ssh_key { name, public_key }`; `hcloud_placement_group { name, type "spread" }`; `hcloud_floating_ip { type, home_location | server_id }` | provider docs | high |
| `hcloud` CLI | v1.68.0 installed and exercised on 2026-09-19 (create, describe, delete, every list verb below); v1.67.0 was the 2026-07-24 release the specs pin — bump the pin to 1.68.0. Config file `~/.config/hcloud/cli.toml` (override `HCLOUD_CONFIG`); **stateless with `HCLOUD_TOKEN` set — no file is written unless you run `hcloud context create`**, which stores the token in `cli.toml` in plaintext. Verbs for a leak sweep: `hcloud server list`, `load-balancer list`, `volume list`, `firewall list`, `network list`, `primary-ip list`, `floating-ip list`, `ssh-key list`, `placement-group list`, all with `-o json` and `-l key=value` label selectors. `hcloud server ssh <name>` exists | https://github.com/hetznercloud/cli/blob/main/docs/reference/configuration.md ; https://github.com/hetznercloud/cli/releases | high |
| Metadata service | `http://169.254.169.254/hetzner/v1/metadata` (hostname, instance-id, public-ipv4, region, availability-zone, `metadata/private-networks`) and **`/hetzner/v1/userdata` — cloud-init user data is readable by any process on the node without authentication**. **Amended 2026-09-21 (HETZ-020, ADR 0037).** Observed directly: a `hostNetwork` pod on a spike node read the whole cloud-config, `K3S_TOKEN` included, from `/hetzner/v1/userdata`. ADR 0037 accepts exactly that for the k3s join token, bounded (join-only, private network, regenerated per `make up`, `k3s token rotate` exists). The prohibition still stands for a CA private key or the Hetzner API token, which grant far more and are never placed there. The Roles Anywhere helper's `serve` mode listens on `127.0.0.1:9911`, so there is no conflict | https://github.com/canonical/cloud-init/blob/main/cloudinit/sources/DataSourceHetzner.py | high |
| **hcloud-cloud-controller-manager (CCM)** | **Not preinstalled** (unlike Civo). v1.37.0 (2026-09-11). Chart `hcloud/hcloud-cloud-controller-manager` from `https://charts.hetzner.cloud`, namespace `kube-system`. Needs Secret `kube-system/hcloud` with key `token` (**read+write** token) and, for private networking, key `network` (id or name) plus `--set networking.enabled=true --set networking.clusterCIDR=<pod CIDR>`. Kubelet must start with `--cloud-provider=external`; nodes then carry the `node.cloudprovider.kubernetes.io/uninitialized` taint until the CCM initialises them — **the CCM must be the first thing after the kubeadm bootstrap, before Argo CD can schedule** (bootstrap-ordering trap: either tolerate the taint in the CCM chart — it does — and install it from `argo-up`, or run Argo with the toleration). Route controller is on by default with networking; it needs a CNI in native routing mode (Cilium native) — with **Cilium's default VXLAN datapath set `HCLOUD_NETWORK_ROUTES_ENABLED=false`** or do not enable `networking` at all. Private networks are IPv4-only. Images amd64/arm64 | https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/docs/guides/quickstart.md ; .../guides/private-network-setup.md ; .../explanation/private-networks.md ; .../explanation/controllers.md ; chart `values.yaml` | high |
| CCM load balancer annotations | Prefix `load-balancer.hetzner.cloud/`: `type` (default `lb11`), `location` **or** `network-zone` (mutually exclusive; immutable — a change means delete+recreate = new IP), `name`, `algorithm-type` round_robin|least_connections, `protocol` tcp|http|https (default tcp), `use-private-ip` (targets via private IPs; needs CCM networking), `disable-private-ingress`, `private-subnet-ip-range`, `private-ipv4`, `disable-public-network`, `ipv6-disabled` (recommended with external-dns so only an A record is published), `hostname` (status carries hostname instead of IP), `uses-proxyprotocol`, `node-selector`, `health-check-{protocol,port,interval,timeout,retries,http-domain,http-path,http-validate-certificate}`, `http-status-codes`, sticky/cookie/redirect/managed-certificate options; read-only status annotations `id`, `ipv4`, `ipv6`, `ipv4-rdns`, `ipv6-rdns`. Defaults also settable cluster-wide via `HCLOUD_LOAD_BALANCERS_*` env (`LOCATION`, `NETWORK_ZONE`, `USE_PRIVATE_IP`, `DISABLE_IPV6`, `TYPE`, health-check defaults 10 s/15 s/3). LB is created and deleted by the CCM with the Service (standard cloud-provider contract; deletion path not spelled out in the docs — spike verifies as CIVO-020 did). Adopting a pre-existing LB by `name` is not documented | https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/docs/reference/load_balancer_annotations.md ; .../reference/load_balancer_envs.md ; .../guides/load-balancer/private-networks.md | high (annotations) / medium (deletion, adoption) |
| LB → node traffic and firewalls | With `use-private-ip: "true"` the LB reaches nodes over the private network, which Hetzner firewalls do not filter (firewalls apply to the public interface); the NodePort range therefore needs **no** public firewall rule. Without it the LB hits the public IPs and the firewall must allow the NodePorts from the LB's IPs. IPVS-mode kube-proxy needs `disable-private-ingress` | https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/docs/guides/load-balancer/private-networks.md ; https://docs.hetzner.com/cloud/firewalls/overview/ | medium |
| **hcloud-csi-driver** | v2.23.0 (2026-09-03). Chart `hcloud/hcloud-csi`, namespace `kube-system`, reads the same `kube-system/hcloud` Secret key `token`. Ships StorageClass **`hcloud-volumes`**, `defaultStorageClass: true`, **`reclaimPolicy: Delete`** (chart value, so a Retain class is one values entry — no k3s-addon revert problem as on Civo), `WaitForFirstConsumer`, expansion supported. Controller Deployment + node DaemonSet. Min volume 10 GB (Hetzner limit). Images amd64/arm64 | https://github.com/hetznercloud/csi-driver/blob/main/docs/kubernetes/guides/quickstart.md ; `chart/values.yaml` | high |
| **VolumeSnapshot / clone** | **Not supported.** `ControllerGetCapabilities` in `internal/driver/controller.go` lists exactly `CREATE_DELETE_VOLUME`, `PUBLISH_UNPUBLISH_VOLUME`, `EXPAND_VOLUME`, `LIST_VOLUMES`, `SINGLE_NODE_MULTI_WRITER` — no `CREATE_DELETE_SNAPSHOT`, no `CLONE_VOLUME`. Hetzner has no volume snapshot product at all. **Same conclusion as Civo: ADR 0031 logical dumps to S3 stands; retained-volume rebind remains the only in-provider option and is untested** | https://github.com/hetznercloud/csi-driver/blob/main/internal/driver/controller.go ; https://docs.hetzner.com/cloud/volumes/overview/ | high |
| **ARM (CAX) image viability** | Checked with `docker manifest inspect` on 2026-09-11: **every platform image publishes arm64** — `public.ecr.aws/rolesanywhere/credential-helper` (amd64+arm64), cloudnative-pg 1.29.0 and postgresql:17, envoyproxy/gateway v1.2.1 and envoy distroless, cert-manager v1.21.1, external-secrets v0.20.0, external-dns v0.20.0, prometheus v3.5.0, loki 3.5.0, alloy v1.10.0, tempo 2.8.0, argocd v3.1.0, hcloud CCM v1.37.0, hcloud CSI v2.23.0, cluster-autoscaler v1.34.0, metrics-server v0.8.0, otel-collector-contrib, alpine/k8s 1.36.4. **The only risk is the repo-built `images/pg-backup` from CIVO-180 (still READY, not built): its workflow must build `linux/amd64,linux/arm64`** | `docker manifest inspect` results ; https://github.com/aws/rolesanywhere-credential-helper/blob/main/docker_image_resources/README.md | high |
| **k3s install and server flags** | One binary and one systemd unit from `https://get.k3s.io`, pinned with `INSTALL_K3S_VERSION`; no apt repository, no package hold, and containerd is embedded rather than installed. Server flags that matter here: `--cluster-init` (embedded etcd instead of the SQLite default), `--disable-cloud-controller`, `--kubelet-arg=cloud-provider=external`, `--disable=servicelb,traefik,local-storage`, `--tls-san`, `--node-ip`/`--node-external-ip`, `--flannel-iface`, `--etcd-expose-metrics`, `--kube-controller-manager-arg`/`--kube-scheduler-arg`, `--write-kubeconfig-mode`, and `--kube-apiserver-arg` for any API server flag | https://docs.k3s.io/installation/configuration ; https://docs.k3s.io/cli/server ; https://docs.k3s.io/datastore/ha-embedded | high (2026-09-20) |
| **k3s agent join** | An agent joins with `K3S_URL` and `K3S_TOKEN` and needs no operator step: its systemd unit restarts until the URL answers, so servers may be created in any order. Only the short password-form token may be pre-set on the server before it starts, which is what allows Terraform to generate one and place it in both renders; the full-form token is generated by the server and cannot be pre-set | https://docs.k3s.io/cli/token ; https://docs.k3s.io/installation/configuration | high (2026-09-20) |
| **hcloud CCM name matching** | hcloud CCM name matching: looks up by `spec.providerID`, falls back to the node name as the Hetzner server name; hostname must equal the server name; a kubelet without `cloud-provider=external` never gets a `providerID` (issue #267) | https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/hcloud/instances.go ; https://github.com/hetznercloud/hcloud-cloud-controller-manager/issues/267 | high (2026-09-19) |
| **k3s bundled components** | k3s ships CoreDNS, Traefik, ServiceLB (klipper), local-path-provisioner, metrics-server, flannel and kube-proxy. `--disable=servicelb,traefik,local-storage` removes the three the platform supplies itself; metrics-server is kept, so this target installs none of its own. A release that adds a further bundled component would install it silently, so the disable list is checked at every version bump | https://docs.k3s.io/installation/packaged-components ; https://docs.k3s.io/networking/networking-services | high (2026-09-20) |
| **flannel on Hetzner** | k3s's default CNI is flannel with a VXLAN backend on 8472/UDP, bound to the private NIC with `--flannel-iface=enp7s0` (MTU 1450 on cx33); default pod CIDR `10.42.0.0/16` and service CIDR `10.43.0.0/16`, neither colliding with the hcloud private network `10.0.0.0/16`. It runs inside the k3s process, so there is no DaemonSet to schedule and no toleration question. kube-proxy stays. The CCM's route controller must be off (`HCLOUD_NETWORK_ROUTES_ENABLED=false`) because flannel runs its own datapath. `--flannel-backend=none` is the documented route to another CNI | https://docs.k3s.io/networking/basic-network-options ; https://docs.hetzner.com/networking/networks/server-configuration/ | high (2026-09-20) |
| **k3s kubelet arguments are per node** | k3s has no `kubelet-config` ConfigMap: an agent does not download a cluster-wide kubelet configuration on join, so `system-reserved`, `kube-reserved` and `eviction-hard` are `--kubelet-arg` flags on each node's install line. Rendering both templates from the same Terraform variables is what keeps them identical; a node-local difference would silently change that node's allocatable figure | https://docs.k3s.io/cli/agent ; https://docs.k3s.io/installation/configuration | high (2026-09-20) |
| **k3s CoreDNS tolerations vs. CCM** | k3s's bundled CoreDNS tolerates `CriticalAddonsOnly` and the control-plane taint, not `uninitialized`, so it stays Pending until the CCM sets `providerID` — the same trap as on kubeadm. The CCM chart tolerates `uninitialized`/`not-ready`, runs `hostNetwork` with `dnsPolicy: Default`, and takes `--allocate-node-cidrs --cluster-cidr`; `HCLOUD_NETWORK_ROUTES_ENABLED` is an env toggle | https://github.com/k3s-io/k3s/blob/master/manifests/coredns.yaml ; https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/chart/templates/deployment.yaml ; https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/docs/guides/private-network-setup.md | high (2026-09-20) |
| **k3s join token** | The k3s token does not expire and needs no CA hash: a joining agent trusts the server after the token matches, and the cluster CA is derived from the token itself, so no CA private key has to exist before the first boot. `k3s token rotate` replaces it on a running cluster. A token placed in `user_data` is readable from the metadata service by any process on the node | https://docs.k3s.io/cli/token ; https://docs.k3s.io/architecture | high (2026-09-20) |
| **k3s upgrade procedure** | Re-run the install script with a new `INSTALL_K3S_VERSION` and restart the unit, or use the system-upgrade-controller with `Plan` CRs. On a disposable cluster the supported path here is `make down` then `make up` with a new pin, which sidesteps in-place upgrade ordering entirely. No minor skipping; kubelet ≤ apiserver | https://docs.k3s.io/upgrades/manual ; https://docs.k3s.io/upgrades/automated ; https://kubernetes.io/releases/version-skew-policy/ | high (2026-09-20) |
| **k3s etcd snapshot/restore** | With `--cluster-init`, k3s manages embedded etcd itself: `k3s etcd-snapshot save`, `k3s etcd-snapshot list`, and restore with `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>`. Scheduled snapshots default to on, to `/var/lib/rancher/k3s/server/db/snapshots`, and can go to S3. With the SQLite default none of this exists | https://docs.k3s.io/datastore/backup-restore ; https://docs.k3s.io/cli/etcd-snapshot | high (2026-09-20) |
| **Versions on 2026-09-19** | Kubernetes 1.37.0 newest (2026-08-26), 1.36.4; cluster-autoscaler must match the k8s minor, latest 1.36.1, no 1.37 tag; hcloud CCM v1.37.0 (own numbering, supports 1.34–1.36); hcloud-csi v2.23.0. The k3s release the target pins (`K3S_VERSION`) carries the Kubernetes minor, so it, the CCM's support window and the cluster-autoscaler tag move together | https://kubernetes.io/releases/ ; https://github.com/k3s-io/k3s/releases ; https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/README.md ; https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/docs/reference/version-policy.md ; https://github.com/hetznercloud/csi-driver/blob/main/docs/kubernetes/reference/version-policy.md | high (2026-09-19) |
| **k3s is conformant** | k3s is a CNCF-certified Kubernetes distribution, so the API, CRDs, Helm charts and Argo CD Applications in `gitops/` behave as on any other target. The platform already runs on it: Civo managed Kubernetes is k3s (`terraform/modules/civo-k8s/main.tf`) | https://www.cncf.io/training/certification/software-conformance/ ; https://docs.k3s.io/ | high (2026-09-20) |
| Community bootstrappers | **kube-hetzner** (`kube-hetzner/terraform-hcloud-kube-hetzner` v3.2.1, MIT): openSUSE Leap Micro images built by Packer, k3s or RKE2, installs CCM, CSI, CNI (flannel/Calico/Cilium), cert-manager, ingress, autoscaler, system-upgrade-controller and kured **from Terraform** — violates "Terraform never touches Kubernetes objects" and duplicates what Argo owns; needs a passphrase-less SSH key. **hetzner-k3s** (`vitobotta/hetzner-k3s` v2.6.0, Go, YAML config): creates servers/network/firewall over the API, installs k3s over SSH, then CCM, CSI, system-upgrade-controller, autoscaler; supports CAX; no Terraform state at all — the platform's Terraform/Terragrunt ownership and leak sweeps would have nothing to bind to. **Recommendation: plain `hcloud_*` resources + a cloud-init that installs the kubeadm prerequisites only**; CCM and CSI go through the existing `argo-up` path (like the CA Secret) or Argo itself, so ownership stays Terraform = cloud, Argo = cluster | https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner ; https://github.com/vitobotta/hetzner-k3s | high (facts) / recommendation |
| Cluster autoscaler `cloudProvider: hetzner` | Env: `HCLOUD_TOKEN` (read+write), `HCLOUD_CLUSTER_CONFIG` (base64 JSON: `imagesForArch {arm64, amd64}`, per-pool `cloudInit`, `labels`, `taints`, `serverLabels`, `subnetIPRange`, `firewalls`) or legacy `HCLOUD_CLOUD_INIT` + `HCLOUD_IMAGE`; `HCLOUD_NETWORK`, `HCLOUD_FIREWALL`, `HCLOUD_SSH_KEY`, `HCLOUD_PUBLIC_IPV4/6` (default true). Node groups `--nodes=<min>:<max>:<TYPE>:<LOCATION>:<name>` (e.g. `0:2:CAX21:NBG1:workers`); the README examples use min 1 but the flag accepts 0 (generic autoscaler semantics) — **verify scale-to-zero in the spike**. **The cloud-init must carry the kubeadm join token** → the token and the Hetzner token both live in-cluster; ARM pools need `imagesForArch.arm64`. Same in-cluster-credential decision as Civo's autoscaler question, but here the Hetzner token is already in-cluster for CCM/CSI, so the autoscaler adds only the join token | https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/hetzner/README.md | high |
| IPv6-only nodes vs AWS | Dual-stack exists for **STS** (`sts.<region>.api.aws`, Nov 2025), **IAM**, **Roles Anywhere** (`rolesanywhere.<region>.api.aws`), **Route 53** (`route53.global.api.aws`), **S3** (`s3.dualstack.<region>.amazonaws.com`), **KMS**; **SSM Parameter Store has no documented public IPv6 endpoint** (re:Post, 2024: "none of the SSM endpoints provides an IPv6 response"). `argo-up` reads SSM from the operator's machine, but ESO reads SSM from inside the cluster → **nodes need IPv4 egress**. Hetzner has **no managed NAT gateway**; a NAT server is a DIY pattern. Budget 0.50 EUR/node for a Primary IPv4 | https://aws.amazon.com/about-aws/whats-new/2025/11/aws-sts-ipv6/ ; https://docs.aws.amazon.com/rolesanywhere/latest/userguide/ip-access.html ; https://aws.amazon.com/about-aws/whats-new/2025/11/amazon-route-53-dns-service-ipv6-api-endpoint/ ; https://docs.aws.amazon.com/AmazonS3/latest/API/ipv6-access.html ; https://repost.aws/questions/QU4lcOfpvgQXS9SrXfHUErHg | medium |
| New-account friction | Limit increases only after one month + first paid invoice; default 5 servers; identity verification on sign-up is common. Plan the spike inside 5 servers and 10 Primary IPs | https://docs.hetzner.com/cloud/servers/faq/ | medium |

## AWS (delta to `specs/civo/research.md`)

Everything in the Civo AWS table still holds: Roles Anywhere trust model, credential helper 1.8.5 (`serve` on `127.0.0.1:9911`, official multi-arch image), ESO/ExternalDNS/cert-manager credential chains, CNPG plugin-barman sidecar limitation. Two deltas:

| Topic | Finding | Source | Confidence |
|---|---|---|---|
| OIDC federation is possible here | A self-managed control plane can set `service-account-issuer=…` and `service-account-jwks-uri=…` — on k3s through `--kube-apiserver-arg`, which passes any API server flag through; hosting the discovery document on S3 (public-read, two small JSON files) lets IAM trust the cluster's SA tokens. It removes the CA ceremony, the sidecar and the 24 h certificates — but discards CIVO-080/082/085/090/100/110, all DONE. Record as rejected-for-now | https://docs.k3s.io/cli/server ; AWS IAM OIDC provider docs | medium |
| Dual-stack AWS endpoints | See the IPv6 row above | — | medium |

## Cost model (EUR/month excl. VAT, 15 June 2026 prices, eu-central)

Six candidate node shapes. Every shape adds one LB11 (7.49), Primary IPv4 per node (0.50 each), a 20 GB CNPG volume (1.14) and four observability volumes at the 10 GB minimum each (40 GB, 2.29). Network, firewall, SSH key: 0.

| Shape | Nodes | Node cost | IPv4 | LB11 | Volumes | **Total** | Allocatable RAM (doc figures, unmeasured) |
|---|---|---|---|---|---|---|---|
| A — ARM, 3 small | 3 × CAX11 (2 vCPU/4 GB) | 17.97 | 1.50 | 7.49 | 3.43 | **30.39** | ~3 × 3.2 GiB ≈ 9.6 GiB |
| B — ARM, 1 CP + 2 workers | 1 × CAX11 + 2 × CAX21 (4/8) | 26.97 | 1.50 | 7.49 | 3.43 | **39.39** | ~3.2 + 2 × 7 ≈ 17 GiB |
| C — ARM, 3 medium | 3 × CAX21 | 31.47 | 1.50 | 7.49 | 3.43 | **43.89** | ~21 GiB |
| D — x86 fallback | 3 × CPX22 (2/4, AMD) | 58.47 | 1.50 | 7.49 | 3.43 | **70.89** | ~9.6 GiB |
| E — x86 if in stock | 3 × CX33 (4/8, Intel) | 25.47 | 1.50 | 7.49 | 3.43 | **37.89** | ~21 GiB |
| **F — chosen 2026-09-19** | 2 × CX33 fixed + 0–2 × CX33 autoscaled (API prices 2026-09-19: 9.99 each) | 19.98 fixed / 39.96 at ceiling | 1.00 / 2.00 | 7.49 | 3.43 | **31.90 fixed / 52.88 at ceiling** | ~14 GiB fixed / ~28 GiB at ceiling |

Shape F is the decision (decisions.md §3, Node shape): CAX is not orderable on 2026-09-19 and CX33 is, in all three EU locations. The LB11 and volume figures in this table are the June list prices; re-read them from the first invoice (experiment 9).

Compare Civo: 80.67 USD (≈ 74 EUR) for 6.76 GiB allocatable. Shape C gives roughly three times the memory for about 58 % of the price — **if CAX stock holds**. Shape D (CPX) is the only shape guaranteed orderable in every location today and is close to Civo's price with fewer resources. Retained AWS costs are unchanged from the Civo model (≈1.80 USD). USD at Hetzner's own table: CAX21 = 12.49 USD, so shape C ≈ 50 USD/month.

Kubernetes overhead on a k3s control-plane node is **unmeasured on this stack** — the spike must read allocatable memory as CIVO-020 did; the "~3.2 GiB" figures above are 4 GiB minus a guess, and were estimated against kubeadm's separate components rather than k3s's single process, so they are if anything pessimistic.

## Open experiments (bounded, for the spike)

1. ~~`hcloud server-type list` and a real `hcloud server create --type cax11 --location nbg1` at spike time: confirm CAX stock, note the exact `server_type` strings and the arm64 `ubuntu-24.04` image id.~~ **Done 2026-09-19**: CAX fails, `cx33` succeeds in nbg1/fsn1/hel1; server type string `cx33`, image `ubuntu-24.04` (x86); `hcloud` v1.68.0, Terraform 1.15.9 with provider `hetznercloud/hcloud` 1.69.0 create/destroy verified; server `running` 18–19 s after create.
2. ~~Measure allocatable memory and CPU on one CX33 running k3s with CCM+CSI installed.~~ **Done 2026-09-21 — see Spike results**
3. ~~Delete a server with an attached CSI volume: confirm the volume stays `available`, its data survives re-attachment to a new server (the half CIVO-020 never ran), and the charge line keeps running.~~ **Done 2026-09-21 — see Spike results**
4. ~~Create a `type: LoadBalancer` Service with `use-private-ip: "true"` and `ipv6-disabled: "true"`; time to `status.loadBalancer.ingress`; confirm the LB is deleted with the Service and that the public firewall needs no NodePort rule.~~ **Done 2026-09-21 — see Spike results**
5. ~~Delete the cluster's servers while an LB exists: is the LB orphaned (expected yes — it is a separate resource, unlike Civo's cluster-scoped reaping)? This decides the `argo-down` ordering guard.~~ **Done 2026-09-21 — orphaned, see Spike results**
6. ~~Prove the bootstrap ordering end to end on a fresh cluster: boot the control plane with `--cluster-init --disable-cloud-controller --kubelet-arg=cloud-provider=external`; confirm CoreDNS stays Pending on the tainted node; helm-install the hcloud CCM with `networking.enabled=true`; confirm the taint clears, CoreDNS reaches Running, then Argo CD reaches Healthy. Record the private NIC name and the x86 `ubuntu-24.04` image id. Also confirm `curl 169.254.169.254/hetzner/v1/userdata` from a `hostNetwork` pod returns the cloud-init (documents the join-token exposure honestly), and that `k3s etcd-snapshot save` succeeds.~~ **Done 2026-09-21 — see Spike results**
7. From a pod with a cert-manager-issued certificate: `aws_signing_helper serve`, `aws sts get-caller-identity`, `aws ssm get-parameter` — proves IPv4 egress and Roles Anywhere from a pod on `cx33`.
8. ~~Cluster autoscaler with `--nodes=0:2:CX33:NBG1:workers`: does it scale from zero, does a node booted from the unmodified worker cloud-init join and get the CCM `providerID`? This is on the M1 path (the autoscaler adds 0–2 workers).~~ **Partly done 2026-09-21 — the node half is proven; the autoscaler component itself is HETZ-170**
9. Read the invoice after the spike: confirm 0 for network/firewall/ssh-key, the Primary IP line while unassigned, and the actual volume €/GB.

## Spike results (HETZ-020, 2026-09-21)

Run in the `vk-lab` Hetzner project, `nbg1`, `cx33`, `ubuntu-24.04`,
k3s `v1.36.4+k3s1`, hcloud CCM chart (app v1.37.0), hcloud-csi 2.23.0,
`hcloud` CLI 1.68.0. Confidence **high (2026-09-21)** unless stated. Project
swept back to zero afterwards; cost about 0.03 EUR.

### The k3s version to pin

`v1.36.4+k3s1`, not 1.37. `cluster-autoscaler` publishes no 1.37 tag (newest
`cluster-autoscaler-1.36.1`) and HETZ-170 needs a matching Kubernetes minor;
the hcloud CCM supports 1.34–1.36. This is the value `K3S_VERSION` takes.

### Availability: the API field that matters

**`/v1/datacenters`'s `server_types.available` does not predict a create.**
For `nbg1-dc3` it lists every CAX type, and `available_for_migration` lists
the same set, yet:

    $ hcloud server create --type cax21 --location nbg1 …
    hcloud: unsupported location for server type (invalid_input)

The field that does predict it is `server_types[].locations[].available`,
which is what `hcloud server-type describe <type>` prints as `Available:`.

This invalidates HETZ-175 §4's prescribed pre-flight probe, which reads the
datacenters endpoint. It must read `hcloud server-type describe "$TYPE" -o
json` and test `.locations[] | select(.name==$LOC) | .available`.

Measured 2026-09-21 (EUR/month net, nbg1 price):

| Type | arch | cpu/mem | EUR/mo | nbg1 | hel1 | fsn1 |
|---|---|---|---|---|---|---|
| cax11 / cax21 / cax31 | arm | 2–8 / 4–16G | 6.99–24.99 | no | no | no |
| cpx11 / cpx21 / cpx31 / cpx41 | x86 | 2–8 / 2–16G | 5.99–37.99 | no | no | no |
| cx23 | x86 | 2 / 4G | 6.49 | yes | yes | no |
| **cx33** | x86 | 4 / 8G | **9.99** | **yes** | **yes** | no |
| cx43 | x86 | 8 / 16G | 18.49 | yes | no | no |
| cpx22 / cpx32 / cpx42 | x86 | 2–8 / 4–16G | 22.99 / 41.99 / 81.99 | yes | yes | no |
| ccx13 / ccx23 / ccx33 | x86 ded. | 2–8 / 8–32G | 50.49 / 101.49 / 162.99 | yes | yes | no |

Consequences: **CAX has not returned** — the 2026-09-19 decision stands
unchanged. The cheap CPX generation is gone from every EU location, so the
only same-shape x86 fallback to `cx33` is `cpx32` at 4.2× the price. But
`cx33` is orderable in **`hel1` as well as `nbg1`**, so a second *location*
is a better first fallback than a second SKU — relevant to HETZ-175 and to
HETZ-025, which pins `hcloud_location = "nbg1"` as a constant. `fsn1` is out
for every type including the dedicated line, i.e. datacenter-level capacity.

### Bootstrap ordering, measured (experiment 6)

From power-on of two servers created stopped and attached at pinned addresses:

| Stage | Time |
|---|---|
| power on → `k3s.yaml` on the control plane | +47 s |
| power on → worker registered **and** `Ready` | +70 s |
| `helm install` hccm returns | +10 s |
| → `uninitialized` taint cleared on both nodes | +16 s |
| → `providerID` set on both | +16 s |
| → CoreDNS `Running` | +22 s |

Control-plane cloud-init finished at 41.4 s. `HETZNER_CP_BOOTSTRAP_SECONDS`
at 600 s is ample.

The ordering ADR 0037 predicts is confirmed exactly. Before the CCM both
nodes carried `node.cloudprovider.kubernetes.io/uninitialized=NoSchedule`,
`providerID` was empty, CoreDNS and metrics-server were `Pending`, and the
k3s journal repeated *"Network policy controller waiting for removal of
node.cloudprovider.kubernetes.io/uninitialized taint"*. After the CCM: taint
gone, `providerID=hcloud://<id>`, both pods `Running`, EXTERNAL-IP populated.

`--disable=servicelb,traefik,local-storage` leaves no trace: no `traefik`,
`svclb-` or `local-path-provisioner` pod and **no StorageClass at all** until
the CSI is installed. metrics-server IS present (k3s ships it), so the
platform installs none of its own and needs no `--kubelet-insecure-tls`.
`k3s etcd-snapshot save` succeeds (2.1 MB snapshot), proving embedded etcd.

### Allocatable on cx33 (experiment 2)

    capacity    cpu=4      mem=7937228Ki  (7.57 GiB)
    allocatable cpu=3250m  mem=6057164Ki  (5.78 GiB)

With the HETZ-030 reservations applied. The two fixed nodes give **11.56 GiB**
allocatable against Civo's 6.76 GiB for the same platform. The cost-model
table above is optimistic: shape E's "~21 GiB" is out by about 45 %, shape F's
"~14 GiB fixed" by about 17 %. Replace those with 2 × 5.78 GiB.

### Pod network MTU

The private NIC `enp7s0` is MTU 1450, but flannel creates `flannel.1` at
**1400**, subtracting the 50-byte VXLAN header. Probed with `ping -M do`
between pods on different nodes: 1372-byte payload OK, 1373 too big. So "the
1450 NIC needs no override" is correct — flannel derives it — but the pod MTU
to quote downstream (HETZ-060, HETZ-190) is **1400**. Cross-node pod traffic
works, avg 1.8 ms, pod CIDR `10.42.0.0/16`.

### CSI volume survival (experiment 3)

hcloud-csi 2.23.0 ships one StorageClass, `hcloud-volumes (default)`,
`RECLAIMPOLICY: Delete`, `WaitForFirstConsumer`, expansion allowed.

**The volume survives, and the data with it.** A 10 GiB PVC was written on the
worker and that server deleted without detaching first. `hcloud volume list`
showed the volume immediately with `SERVER: -`, and after re-attachment to the
surviving node the marker read back byte for byte.

**But re-attachment stalls for about six minutes.** The pod sits in
`ContainerCreating` with `FailedAttachVolume … Volume is already exclusively
attached to one node, waiting on detach`, while `kubectl get volumeattachment`
still claims the volume is attached to a node that no longer exists. Hetzner
and Kubernetes disagree and Kubernetes wins. It clears by itself once
Kubernetes force-detaches (6-minute default); no manual step is needed, and
deleting the VolumeAttachment by hand is a trap, because by then it may
already have been replaced by a legitimate one. Any budget for "a pod with a
volume moves between nodes" must exceed 6 minutes — HETZ-170 especially.

### Load balancer lifecycle (experiments 4 and 5)

- `status.loadBalancer.ingress` populated at **+22 s**, carrying **`.ip`**
  with `ipMode: VIP`, never `.hostname`. ExternalDNS gets an A record.
- **HTTP 200 through the LB at +23 s with only tcp/22, tcp/6443 and icmp open
  inbound.** Confirms that `use-private-ip: "true"` routes over the private
  network, which Hetzner firewalls do not filter, so **no NodePort rule is
  needed**.
- `ipv6-disabled: "true"` does **not** stop the LB getting an IPv6; it only
  suppresses it in the Service ingress status.
- The LB's Hetzner name is a **hash** (`a25ebc53fa6e547e98c46210f45f138c`),
  unrelated to the Service or project. A leak sweep cannot match it by name —
  HETZ-040 must use labels or enumerate.
- **Deletion with the Service is clean**: the LB was gone within 5 s of
  `kubectl delete svc`.
- **Orphaning is confirmed.** With the Service still present, every server was
  deleted; the LB was still there — and still `healthy` — at +15 s, +75 s and
  +195 s, and only an explicit `hcloud load-balancer delete` removed it. At
  7.49 EUR/month it bills indefinitely. **This makes HETZ-047 mandatory**:
  `argo-down` must remove the Envoy Service while the cluster still answers.

The same trap applies to volumes: at teardown the CSI volume was still present
with every server gone, because the PV's `Delete` reclaim needs a live CSI
controller. Primary IPs were the exception — removed with their servers.

### Bugs found in commands the specs prescribe verbatim

1. **HETZ-030 both templates.** `--kubelet-arg=eviction-hard=memory.available<300Mi`
   unquoted is a shell input redirection from a file named `300Mi`; since the
   install is `curl … | sh -s - server …` the redirect replaces the piped
   script and the install dies. Single-quote the whole argument.
2. **HETZ-030 worker template.** The `$PRIV` parse. The payload's first entry
   starts with a YAML list dash, so the address is field 3:
   `awk '$1=="-"&&$2=="ip:"{print $3;exit} $1=="ip:"{print $2;exit}'`. A naive
   `$1=="ip:"` yields empty and the agent crash-loops on
   `invalid node-ip: invalid ip format ''`. `/hetzner/v1/metadata`'s own
   `local-ipv4` is `""` on such a node and is not a shortcut. Add a NIC
   fallback and a `test -n "$PRIV"`.
3. **HETZ-020 §4's own CCM command.** `--set env.HCLOUD_NETWORK_ROUTES_ENABLED.value=false`
   renders a boolean and the apply is rejected with *expected string, got
   false*. Must be `--set-string`. HETZ-045 inherits this.
4. **HETZ-175 §4's pre-flight probe** reads the wrong field — see above.
5. **`hcloud server create` cannot pin a private IP.** Only `--network <name>`,
   which auto-assigns. The three-call form is create with
   `--start-after-create=false`, `attach-to-network --ip`, then `poweron`;
   cloud-init still sees the NIC on first boot. Terraform's
   `network { ip = … }` does it in one resource, so this only matters to
   scripts (HETZ-040).

   **Corrected 2026-09-21 (HETZ-030).** The last sentence is wrong, and the
   spike could not have seen it: creating servers stopped and attaching them
   before power-on is precisely what avoids the race, so a spike that did
   that had no way to observe it. One resource is not one API call. Terraform
   creates the server, which begins to boot, and attaches the network after.
   Cloud-init reads its network configuration once, so a server that loses
   that race writes an `eth0`-only netplan; the private NIC then appears as a
   link in state `DOWN` that nothing ever configures, and `--flannel-iface`
   and `--node-ip` have no address to bind. On the first real bring-up of
   `cluster-hetzner` — three servers created in one `apply` — the control
   plane won the race and both workers lost it, so both agents retried the
   API address indefinitely. The race is per server and not otherwise
   predictable. Any path that creates a server attached to the network,
   Terraform's included, must configure the private NIC itself rather than
   rely on the datasource; HETZ-030's templates write the netplan stanza and
   wait for the address before installing k3s.

### Autoscaler node path (experiment 8, node half)

A `cx33` created from the **unmodified** worker cloud-init with no pinned
address joined with no operator step and was `Ready` **+42 s** after create,
with `providerID` set. Its auto-assigned private IP was `10.0.1.1` — Hetzner's
gateway is the network's first address (`10.0.0.1`), not the subnet's, so
`.1`–`.9` stay assignable when the control plane is pinned at `.10`.
HETZ-170's premise holds: one render serves the fixed worker and any
autoscaled node.

### DataSourceHetzner is broken in init-local (HETZ-030, 2026-09-21)

On every `ubuntu-24.04` node measured across two bring-ups, `cloud-init status
--long` reports four `init-local` failures:

    errors:
      - can only concatenate str (not "NoneType") to str   (x4)
    WARNING:
      - network-config-v1 failed schema validation!        (x4)

The stage that fails is the one that builds network configuration from the
Hetzner metadata, and the run ends `error - done` — later stages complete, the
status stays latched at `error`. Two consequences.

First, **`cloud-init status` cannot gate anything on this target.** A criterion
demanding exit 0 fails a perfectly healthy three-node cluster. Assert on what
the node ends up with — `/etc/rancher/k3s/k3s.yaml`, `systemctl is-active k3s`,
an address on the private NIC — not on cloud-init's own verdict. HETZ-040's
node-Ready wait must not use it either.

Second, this is the upstream cause of the private-NIC failure recorded above.
The datasource sometimes recovers on a retry and writes the `enp7s0` stanza
anyway, and sometimes does not; that is the whole difference between a node
that joins and a node that never does. On the first bring-up one node of three
recovered, on the second all three did. Since the outcome is not controllable,
every path that creates a node configures the private NIC itself.

### Stock, 2026-09-21 later the same day (HETZ-030)

Between one `apply` and the next, **every catalogue-legal shape went out of
stock across the whole `eu-central` zone**: `cx23`, `cx33` and `cx43` all
reported `available=false` in `nbg1` and in `hel1`, and a create failed with
`error during placement (resource_unavailable)`. The morning's measurement in
the table above had `cx33` orderable in both. So the CX line's stock moves
within hours, not days, and a second *location* is not a fallback when the
shortage is zone-wide — which weakens the "a second location beats a second
SKU" conclusion recorded above, and is the strongest argument yet for
HETZ-175's pre-flight probe running before any `apply`, not as a retry.

### Still open

- **Experiment 9, the invoice.** Read the next invoice for the network,
  firewall, SSH-key, unassigned-primary-IP lines, hourly rounding, and the
  real volume and LB rates.
- **Account limits.** Not exposed by any API endpoint. Read Console → Limits.
  If the default 5-server limit applies, file the increase immediately: it is
  granted only after one month as a customer and a paid first invoice, then
  1–3 business days, making it the longest lead time in the Hetzner track.
- **Experiment 7**, Roles Anywhere from a pod on `cx33`, is untouched; it
  belongs to HETZ-085.
