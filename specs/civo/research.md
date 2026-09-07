# Research: verified capabilities, prices, and uncertainties

All items accessed 2026-09-06 unless stated. Confidence: **high** = official
doc states it; **medium** = official doc implies it or a maintained README
states it; **low** = inferred, needs the spike.

## Civo

| Topic | Finding | Source | Confidence |
|---|---|---|---|
| Terraform provider auth | `CIVO_TOKEN` env var takes precedence over everything; `token` argument deprecated (avoid secrets in state); `credentials_file` JSON option; Civo CLI `~/.civo.json` fallback | https://github.com/civo/terraform-provider-civo/blob/master/docs/index.md | high |
| `civo_kubernetes_cluster` | Required: `firewall_id`, exactly one `pools` block (`size`, `node_count`, optional `label`, `labels`, `taint`, `public_ip_node_pool`). Optional: `name`, `cluster_type` k3s (default) or talos, `cni` flannel (default) or cilium, `kubernetes_version`, `network_id`, `region`, `applications` (comma list, `-name` removes defaults), `tags`, `write_kubeconfig` (default false; true stores kubeconfig in state), `timeouts`. Attributes: `kubeconfig` (sensitive), `api_endpoint`, `master_ip`, `dns_entry`, `status`, `ready`, `installed_applications`. Note: application updates unsupported; apps needing volumes leave volumes behind on destroy | https://github.com/civo/terraform-provider-civo/blob/master/docs/resources/kubernetes_cluster.md | high |
| `civo_kubernetes_node_pool` | `cluster_id`, `size`, `node_count`, `label`, `labels`, `taint{key,value,effect}`, `public_ip_node_pool`; removing taints needs manual kubectl | https://github.com/civo/terraform-provider-civo/blob/master/docs/resources/kubernetes_node_pool.md | high |
| `civo_firewall` | `name`, `network_id`, `create_default_rules` (must be false with custom rules), `ingress_rule`/`egress_rule` blocks: `action`, `cidr`, `protocol` (tcp default), `port_range`, `label` | https://github.com/civo/terraform-provider-civo/blob/master/docs/resources/firewall.md | high |
| Default cluster apps | Marketplace manifests name them `traefik2-nodeport` and `metrics-server`; the CLI removes by that `name`; Terraform `applications` accepts `-name` entries (case-sensitive). **Verified by CIVO-020: the strings are correct, but `-metrics-server` is INERT** — the manifest marks metrics-server `built_in: true`, which neither civogo nor the CLI parses, and the API installs it regardless. Traefik removal works. No error is returned either way | https://github.com/civo/kubernetes-marketplace, civo/cli README, provider kubernetes_cluster.md; CIVO-020 spike | high |
| Node labels | Auto labels `kubernetes.civo.com/node-pool`, `kubernetes.civo.com/node-size` | https://www.civo.com/docs/kubernetes/advanced/managing-node-pools | high |
| Allocatable memory | **Measured on a Medium node by CIVO-020: capacity 3822196 Ki (3733 MiB), allocatable 2364020 Ki = 2308 MiB, CPU 1880m of 2.** The docs figure of ~2672 MiB is 364 MiB too high. Three Medium nodes give **6.76 GiB**, not 7.8 GiB. Large and Small are still doc figures only (~5949 MiB, ~1336 MiB) | CIVO-020 spike (Medium); https://www.civo.com/docs/kubernetes/advanced/managing-node-pools (Large, Small) | high (Medium measured); medium (Large, Small) |
| LoadBalancer annotations | `kubernetes.civo.com/firewall-id`, `loadbalancer-algorithm` (round_robin, least_connections), `loadbalancer-enable-proxy-protocol` (send-proxy, send-proxy-v2; when set, status carries hostname not IP), `ipv4-address` (reserved IP), `protocol` (http, tcp), `max-concurrent-requests` (10000–50000; change causes brief downtime), `server-timeout`, `client-timeout`. Status annotations `cluster-id`, `loadbalancer-id`, `loadbalancer-name`. DNS entry `<id>.lb.civo.com`. LB deleted with the Service. **CIVO-020 measured: `status.loadBalancer.ingress[0]` carries BOTH `hostname` and `ip`, plus `ipMode: VIP`; the LB is available 31 s after Service creation; and the CCM writes back `loadbalancer-algorithm: round_robin` itself, settling the underscore-vs-hyphen conflict in favour of the UNDERSCORE form** | https://github.com/civo/civo-cloud-controller-manager | high |
| Health checks | Defaults: interval 10 s, timeout 5 s, unhealthy 3, healthy 2; HTTP or TCP | https://www.civo.com/docs/networking/load-balancers/health-checks | high |
| Reserved IP | Assignable to a Kubernetes LB by annotation `kubernetes.civo.com/ipv4-address` (CCM source; the docs page's `civo.com/reserved-ip` is stale); region-specific; stays in the account when released. **CIVO-020 verified the annotation end to end: the LB comes up on an EPHEMERAL IP first and switches to the reserved IP ~11 s after the annotation is applied** (the CCM assigns it in `updateLBConfig`, not at create). **Price remains unobtainable:** `/v2/charges` proves it is billed as its own `reserved-ip` line item but reports hours, never money, and `/v2/pricing`, `/v2/prices`, `/v2/billing/pricing`, `/v2/account/pricing` all return 404. Read the rate from the dashboard invoice. **Civo publishes no reserved-IP price on any public-cloud page.** Civo's own charges API says so by design: it "doesn't track how much to charge for any particular product" and only reports hours per instance, IP address and snapshot. The only Civo-published IP figure anywhere is **£2.25 per IP address** in the G-Cloud 14 commercial listing — GBP, **no billing period stated**, filed under sales-mediated add-ons and "requires approval from Civo", so it is probably not the self-service SKU. **Charging stops on deletion, not detachment** (G-Cloud service definition: deleting clusters and associated resources including "IP address reservations" is when "these are no longer charged"), so a reserved IP bills while the lab is down | https://www.civo.com/docs/networking/reserved-ip, https://www.civo.com/api/charges, civo-cloud-controller-manager `loadbalancer.go`; CIVO-020 spike; G-Cloud 14 Civo price list | high (behaviour); price still unknown |
| Included vs extra IPs | **Confirmed by Civo:** "Public IP addresses can be assigned to the cluster control plane (ClusterIP) and to each Service of type LoadBalancer. **Public IPs beyond the cluster IP are charged separately.**" The price list likewise prices "IP addresses **in addition to those supplied as standard**". So the cluster's own IP is included, a managed LB's IP is presumably inside the 10.86 USD LB price, and **a reserved IP is an additional, separately-billed IP on top of the load balancer** | G-Cloud 14 Civo Kubernetes service definition; https://www.civo.com/api/instances | high |
| Private network cost | **Free.** Measured by CIVO-020: a custom `civo_network` and four firewalls existed for ten minutes and produced no line item at all in `/v2/charges`, while a 1 GB volume alive for five minutes was billed a full hour. Corroborated by Civo: "Monthly charges are based purely on the size of the instance and any additionally attached volumes", and networks appear on no price list. Networks do count against the account quota | CIVO-020 spike; G-Cloud 14 Civo Compute service definition; https://www.civo.com/docs/networking/private-networks | high |
| Storage | StorageClass `civo-volume`: provisioner `csi.civo.com`, reclaim `Delete`, `WaitForFirstConsumer`, `allowVolumeExpansion: true` (offline expansion: detach first). RWO shown. **CIVO-020 verified volume-object survival directly: after `civo kubernetes remove`, the volume moved `attached` → `available`, kept its size and network, and its charge line stayed OPEN until manual deletion.** Also measured: the StorageClass is owned by a k3s Addon (`objectset.rio.cattle.io/owner-name: csi`), so k3s reconciles it and **a patch to `Retain` would be reverted — a separate Retain StorageClass is required**. The `volumeHandle` is the raw Civo volume UUID with no prefix | https://www.civo.com/docs/kubernetes/config/kubernetes-volumes; CIVO-020 spike | high |
| VolumeSnapshot / clone | **Not supported.** `ControllerGetCapabilities` lists only `CREATE_DELETE_VOLUME`, `PUBLISH_UNPUBLISH_VOLUME`, `LIST_VOLUMES`, `GET_CAPACITY`, `EXPAND_VOLUME`; snapshot capabilities are commented out and `CreateSnapshot`/`DeleteSnapshot`/`ListSnapshots` return `Unimplemented`; no `CLONE_VOLUME` | https://github.com/civo/civo-csi/blob/master/pkg/driver/controller_server.go | high |
| Cluster autoscaler | Marketplace app (`civo-cluster-autoscaler`) or the upstream Helm chart with `cloudProvider: civo`, `autoscalingGroups` (min/max per pool name) and Secret `civo-api-access`; `--nodes=min:max:poolname`; min 1; account quota wins; Terraform must `ignore_changes` on `node_count`; scale-down is blocked by pods without PDBs in `kube-system`, by PDBs (CNPG creates one even for one instance), and by local storage unless flags/annotations are set | https://civo.com/docs/kubernetes/scaling-nodes, https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/charts/cluster-autoscaler/README.md#civo, https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md | high |
| API key | Static per-account key; regenerate only; no documented scopes or expiry; org accounts may have several keys | https://www.civo.com/docs/account/api-keys | high |
| Short-lived tokens | `POST /v2/auth/exchange` converts the API key to a JWT (access, refresh, id token); OAuth client apps (auth-code, client-credentials) registered through support. All paths still need the static key | https://www.civo.com/api | high |
| ServiceAccount OIDC issuer | **Measured by CIVO-020. Federation to AWS is impossible, for two independent reasons.** (1) The issuer is `https://kubernetes.default.svc.cluster.local` — cluster-internal, so AWS cannot fetch `<issuer>/.well-known/openid-configuration` to register an IAM OIDC provider. (2) Anonymous discovery returns **HTTP 401** on both `/.well-known/openid-configuration` and `/openid/v1/jwks`. The creation payload exposes no apiserver-args field, so the issuer cannot be changed. **IAM Roles Anywhere is therefore mandatory, not optional** | CIVO-020 spike | high |
| Pricing (USD/month, uniform across regions, no tax stated) | Standard: XS 5.43, S 10.86, Medium (2 vCPU/4 GB) 21.73, Large (4 vCPU/8 GB) 43.45. RAM-optimized Small (2 vCPU/16 GB) 78.21. LB 10.86 per 10 000 concurrent requests. Block storage 0.11 per GB. Egress and ingress free | https://www.civo.com/pricing | high |
| Object store | Sized in 500 GB increments, billed on allocated size, not usage: "You can size an object store in 500GB increments" and "the price ... will change depending on the size of the object store you create". About 5.43 USD/month at the 500 GB minimum. Rejected in favour of S3 | https://www.civo.com/docs/object-stores/create-an-object-store, https://www.civo.com/pricing | high |

## AWS

| Topic | Finding | Source | Confidence |
|---|---|---|---|
| Roles Anywhere trust anchor | Either AWS Private CA or an external CA certificate. Resources are regional and must share account and region. Trust boundary is the account unless role trust policies add conditions | https://docs.aws.amazon.com/rolesanywhere/latest/userguide/introduction.html | high |
| Certificate requirements | End-entity: X.509v3, `CA:false` if basic constraints present, key usage includes Digital Signature, SHA-256 or stronger. Trust anchor cert: `CA:true`, key usage Certificate Sign | https://docs.aws.amazon.com/rolesanywhere/latest/userguide/trust-model.html | high |
| Trust policy conditions | Principal tags `aws:PrincipalTag/x509Subject/CN`, `x509Issuer/*`, `x509SAN/DNS|URI|Name/*`; `aws:SourceArn` = trust anchor ARN; `sts:SourceIdentity` = `CN=<cn>`. Role must allow `sts:AssumeRole`, `sts:TagSession`, `sts:SetSourceIdentity` to `rolesanywhere.amazonaws.com` | same | high |
| Revocation | Only imported CRLs (`ImportCrl`); no OCSP/CDP callbacks. Disabling the trust anchor stops new sessions; issued sessions live until expiry | same | high |
| Credential helper | Version 1.8.5 (2026-08-24). Modes: `credential-process` (SDK `credential_process`), `update` (writes credentials file, refreshes), `serve` (localhost IMDSv2-compatible endpoint, default port 9911, refreshes 5 min before expiry; SDKs use `AWS_EC2_METADATA_SERVICE_ENDPOINT`). Since 1.2.0 long-running modes reload changed cert/key files. Since 1.8.3 `serve` handles SIGTERM. Session duration 900–43200 s. Official Linux binaries with SHA-256 and an official container image `public.ecr.aws/rolesanywhere/credential-helper` (amd64/arm64) | https://docs.aws.amazon.com/rolesanywhere/latest/userguide/credential-helper.html | high |
| Roles Anywhere price | No charge (launch announcement); quotas: 50 trust anchors, 250 profiles, 2 certificates per trust anchor (supports rotation bundles) | https://aws.amazon.com/about-aws/whats-new/2022/07/aws-identity-access-management-iam-roles-anywhere-workloads-outside-aws, https://docs.aws.amazon.com/general/latest/gr/rolesanywhere.html | high |
| AWS Private CA | 50 USD/month per CA in short-lived mode, 400 USD general purpose; rejected for cost | search result summary citing aws.amazon.com/private-ca/pricing | medium |
| ESO AWS auth | Controller pod credentials via the AWS SDK default chain (env, shared config, IMDS/container endpoint), IRSA `jwt`, static `secretRef`, `role`/`additionalRoles` chaining, EKS Pod Identity | https://external-secrets.io/latest/provider/aws-access/ | high |
| ExternalDNS AWS auth | AWS SDK for Go v2 default chain; static file, IRSA, Pod Identity, node role. Flags `--txt-owner-id`, `--domain-filter`, `--zone-id-filter`, `--policy` | https://kubernetes-sigs.github.io/external-dns/latest/docs/tutorials/aws/ | high |
| cert-manager Route53 | Ambient SDK chain or `secretRef`, or `serviceAccountRef` web identity. Not needed: HTTP-01 through Gateway API avoids AWS credentials | https://cert-manager.io/docs/configuration/acme/dns01/route53/ | high |
| CNPG physical backups | Barman runs in a sidecar the plugin injects into the instance pod; `instanceSidecarConfiguration` exposes environment variables and resources, and CNPG has no supported way to add a container of your own. Roles Anywhere therefore has nowhere to run, so physical backups from Civo would need a permanent AWS key. Recovery always creates a new cluster: "recovery is not performed in-place on an existing cluster" | https://cloudnative-pg.io/plugin-barman-cloud/docs/next/concepts/, https://cloudnative-pg.io/docs/devel/recovery/ | high |

## Cost model (USD/month, 2026-09-06 prices, no tax, region-uniform)

Civo, one fixed pool of three `g4s.kube.medium` nodes, one load balancer,
a 20 GiB CNPG volume and the observability volumes:

| Item | Quantity | Cost |
|---|---|---|
| Nodes | 3 × Medium at 21.73 | 65.19 |
| Load balancer | 1 | 10.86 |
| CNPG volume | 20 GiB at 0.11 | 2.20 |
| Observability volumes | 22 GiB at 0.11 (Prometheus 10, Loki 10, Grafana 1, Alertmanager 1) | 2.42 |
| **Civo total** | | **80.67** |

That sits at the top of the 60 to 80 USD target. The volume sizes are the
adjustment knob: halving the Prometheus and Loki claims saves 1.10 and
brings the total to 79.57. CIVO-175 measures real usage and revisits both
the volumes and the node size.

Retained AWS costs while Civo runs:

| Item | Cost |
|---|---|
| Route 53 hosted zone | 0.50 plus queries |
| KMS key | 1.00 |
| S3 backup bucket, about 5 GiB of dumps | 0.25 |
| SSM Advanced parameter for the TLS Secret | 0.05 |
| SSM Standard parameters, Roles Anywhere, GitHub OIDC | 0.00 |
| **AWS total** | **about 1.80** |

Allocatable memory: about 2.6 GiB per Medium node, 7.8 GiB across three.
A single pod cannot exceed 2.6 GiB, which constrains Prometheus.

AWS costs that disappear when Civo replaces EKS: control plane about 73,
NLB about 16 to 22, the system node about 25, Karpenter nodes variable,
EBS about 2 to 4.

Uncertainties. Civo still does not publish the reserved IP price. CIVO-020 showed that Civo bills
the IP, but found no rate anywhere. CIVO-020 also measured the allocatable memory: 2308 MiB per
Medium node. Three Medium nodes therefore give 6.76 GiB, not the 7.8 GiB assumed before. This
makes one earlier question harder, not easier: does the observability stack fit on three Medium
nodes at the planned limits? Civo also installs an `otel-collector` DaemonSet of its own, which
takes more of that memory. See "Spike results".

## Spike results (CIVO-020, run 2026-09-07)

The spike created one throwaway cluster in LON1: one `g4s.kube.medium` node, k3s `1.35.0-k3s1`.
Throwaway Terraform created it, with provider `civo/civo` v1.3.2. That Terraform stayed in a
scratch directory. It never went under `terraform/live/`. The CLI was `civo` v1.5.4.
The spike deleted every resource. The leak check found nothing.
Civo billed four line items at one hour each: the node, the load balancer, a 1 GB volume, and the
reserved IP. The total was about 0.05 USD, plus one hour of reserved IP at a price Civo does not
publish. The ceiling was 2 USD.

| Item | Command | Result | Date |
|---|---|---|---|
| Default app strings | `civo kubernetes applications ls --region LON1` | `traefik2-nodeport` (v2.9.4) and `metrics-server`, both lowercase. `traefik2-loadbalancer` is a separate non-default app | 2026-09-07 |
| App removal behaviour | `applications = "-traefik2-nodeport,-metrics-server"` then `kubectl get all -A` | **Traefik removed. `metrics-server` NOT removed** — it carries `built_in: true`, which the client libraries do not parse and the API honours. No error either way | 2026-09-07 |
| App removal reporting | `civo kubernetes show -o json`; Terraform `installed_applications` | Reports `null` / `[]` while metrics-server is running. **Not usable as a verification signal; use `kubectl`** | 2026-09-07 |
| k3s version | `civo kubernetes versions --region LON1` | `1.35.0-k3s1` was the only row both `stable` and `Default=true`. `1.36.0-k3s1` was `development`; `<= 1.34.2-k3s1` `deprecated` | 2026-09-07 |
| Node SKUs in LON1 | `civo kubernetes size --region LON1` | All four `g4s.kube.*` standard sizes `Selectable`, `g4s.kube.large` included. Medium = 2 CPU / 4096 MB / 50 GB | 2026-09-07 |
| Measured allocatable | `kubectl get node -o json` | capacity 3822196 Ki; **allocatable 2364020 Ki = 2308 MiB**; CPU 1880m. kube-system already requests 200m / 140Mi | 2026-09-07 |
| Cluster create time | `terraform apply` | firewall 4 s, cluster **2m28s** | 2026-09-07 |
| **Readiness trap** | `civo kubernetes show` vs `kubectl get nodes` | **API reported `status: ACTIVE`, `ready: true` with ZERO nodes and every kube-system pod `Pending`. Terraform returned at that point. The node became Ready 40 s later.** Gate on kubectl node readiness, never on the provider attribute | 2026-09-07 |
| StorageClass | `kubectl get sc civo-volume -o json` | `csi.civo.com`, reclaim `Delete`, `WaitForFirstConsumer`, expansion true, default class. **Owned by a k3s Addon, so k3s reverts edits — a separate Retain StorageClass is required** | 2026-09-07 |
| Snapshot CRDs | `kubectl api-resources \| grep -i snapshot` | Only `etcdsnapshotfiles`. No `VolumeSnapshot`/`VolumeSnapshotClass` at all | 2026-09-07 |
| Volume identity | `kubectl get pv -o jsonpath` + `civo volume ls` | `volumeHandle` is the raw Civo UUID, no prefix. `size_gb` reads `null` in the API listing | 2026-09-07 |
| **Volume survives deletion** | `civo volume ls` after `civo kubernetes remove` | **Survived: `attached` -> `available`, cluster/instance fields emptied, size and network kept, charge line stayed OPEN until manual deletion** | 2026-09-07 |
| LB status fields | `kubectl get svc -o json` | Carries **both** `hostname` (`<lb-uuid>.lb.civo.com`) and `ip`, plus `ipMode: VIP`. Available 31 s after Service creation | 2026-09-07 |
| LB algorithm form | CCM write-back | The CCM writes `loadbalancer-algorithm: round_robin` — **underscore** | 2026-09-07 |
| Reserved IP annotation | `kubectl annotate svc ... kubernetes.civo.com/ipv4-address=<ip>` | Works. LB came up on an ephemeral IP, switched to the reserved IP **11 s** after the annotation. `curl` through it returned HTTP 200 | 2026-09-07 |
| **LB firewall is wide open** | `civo firewall rule ls default-civo020-spike` | Civo auto-created an LB firewall allowing **all TCP and all UDP, 1-65535, from 0.0.0.0/0, ingress and egress**, despite our own firewall setting `create_default_rules = false` and the Service carrying no `firewall-id`. **Envoy's Service must set `kubernetes.civo.com/firewall-id` explicitly** | 2026-09-07 |
| Firewall sprawl | `civo firewall ls` | One cluster + one LB produced **four** firewalls, three unrequested | 2026-09-07 |
| **LB reaped with cluster** | `civo loadbalancer ls` after cluster delete | **Deleted server-side with the cluster; no orphan.** Charges show the LB and node stopping at the same instant. Observed once and undocumented — keep the delete-Services-first ordering as defence | 2026-09-07 |
| Cluster delete time | `civo kubernetes remove <name> -y` | API returns in **2 s**; the node and LB actually stop ~23 s later. A warning naming attached volumes is printed first | 2026-09-07 |
| OIDC issuer | `kubectl get --raw /.well-known/openid-configuration` | `issuer: https://kubernetes.default.svc.cluster.local` — cluster-internal | 2026-09-07 |
| OIDC anonymous | `curl -sk https://<api>:6443/.well-known/openid-configuration` | **HTTP 401**, same for `/openid/v1/jwks` | 2026-09-07 |
| Reserved IP price | `/v2/charges` + probes of four pricing paths | **Could not test.** Billed as its own `reserved-ip` line item, but the charges API reports hours only and every pricing path 404s. Read the rate from the dashboard invoice | 2026-09-07 |
| Billing shape | `/v2/charges` | Hourly, **rounded up**: every line item billed 1 h for 2-10 minutes of runtime. While a line is open, `num_hours` reports hours left in the day, not hours used | 2026-09-07 |
| Network and firewall cost | `/v2/charges` over the whole spike window | **No line item was produced for the custom network or for any of the four firewalls.** Only `kube-node-*`, `volume`, `loadbalancer` and `reserved-ip` appeared | 2026-09-07 |
| Leak check | `civo {kubernetes,loadbalancer,volume,ip,instance} ls` | All empty. `network ls` and `firewall ls` left only Civo's account-default `default` / `default-default` | 2026-09-07 |
| Token at rest | `civo region current LON1` | **Writes the plaintext API token into `~/.civo.json` under `apikeys.tempKey`.** `CIVO_TOKEN` is loaded as `tempKey` and any config-saving command persists it. Scrub with `jq 'del(.apikeys.tempKey)'`; the region default survives and read commands do not re-add it | 2026-09-07 |
| CLI verbs | `civo --help` | It is `civo kubernetes versions` and `civo kubernetes size` — **no `ls`**. `civo ip`, never `civo reservedip`. Non-interactive flag is the root `-y`, not `--force`. No `charges` verb exists | 2026-09-07 |
| Region default | `civo region ls` | Account default was **NYC1**. `CIVO_TOKEN` seeds the key only, never the region — pass `--region LON1` or set it once | 2026-09-07 |
| Injected components | `kubectl -n kube-system get ds` | Civo injects an **`otel-collector` DaemonSet** not mentioned in any spec. It competes with CIVO-160 for node resources | 2026-09-07 |

### Not tested, deliberately

The spike did not test the **static PV rebind** across clusters. It also did not test the **data**
on a surviving volume. The table above shows that the volume *object* survives. It does not show
that the ext4 filesystem and its contents come back when a new cluster binds the volume. The table
records the `volumeHandle` format that such a test needs. CIVO-120 and CIVO-150 both depend on
this second half. Treat it as an open experiment.

## Later experiments (bounded, not run in planning)

1. ~~CIVO-020: create one Medium k3s cluster with a PVC; delete the cluster; check the account for the volume.~~ **RUN 2026-09-07 — see "Spike results".** The static PV rebind half was NOT run and remains open: create a cluster, bind a retained volume by `volumeHandle`, and verify the data.
2. ~~CIVO-020: read `/.well-known/openid-configuration` and `/openid/v1/jwks`.~~ **RUN 2026-09-07 — see "Spike results". Federation is impossible; Roles Anywhere is mandatory.**
3. CIVO-090: from a pod with a cert-manager-issued certificate, run `aws_signing_helper serve`, call `aws sts get-caller-identity`, then repeat with a certificate whose CN does not match the role's trust policy (expect denial).
4. CIVO-070: issue one Let's Encrypt staging certificate via HTTP-01 through the Gateway; then destroy and recreate the cluster and confirm the re-imported Secret is reused without a new order.
