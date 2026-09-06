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
| Default cluster apps | Marketplace manifests name them `traefik2-nodeport` and `metrics-server`; the CLI removes by that `name`; Terraform `applications` accepts `-name` entries (case-sensitive). Spike confirms the strings | https://github.com/civo/kubernetes-marketplace, civo/cli README, provider kubernetes_cluster.md | medium |
| Node labels | Auto labels `kubernetes.civo.com/node-pool`, `kubernetes.civo.com/node-size` | https://www.civo.com/docs/kubernetes/advanced/managing-node-pools | high |
| Allocatable memory | Medium 4 GiB → ~2672 MiB allocatable (35% reserved); Large 8 GiB → ~5949 MiB (27%); Small 2 GiB → ~1336 MiB | same | high |
| LoadBalancer annotations | `kubernetes.civo.com/firewall-id`, `loadbalancer-algorithm` (round_robin, least_connections), `loadbalancer-enable-proxy-protocol` (send-proxy, send-proxy-v2; when set, status carries hostname not IP), `ipv4-address` (reserved IP), `protocol` (http, tcp), `max-concurrent-requests` (10000–50000; change causes brief downtime), `server-timeout`, `client-timeout`. Status annotations `cluster-id`, `loadbalancer-id`, `loadbalancer-name`. DNS entry `<id>.lb.civo.com`. LB deleted with the Service | https://github.com/civo/civo-cloud-controller-manager | high |
| Health checks | Defaults: interval 10 s, timeout 5 s, unhealthy 3, healthy 2; HTTP or TCP | https://www.civo.com/docs/networking/load-balancers/health-checks | high |
| Reserved IP | Assignable to a Kubernetes LB by annotation `kubernetes.civo.com/ipv4-address` (CCM source; the docs page's `civo.com/reserved-ip` is stale); region-specific; stays in the account when released; chargeable; price not published on fetched pages | https://www.civo.com/docs/networking/reserved-ip, civo-cloud-controller-manager `loadbalancer.go` | medium (price unknown) |
| Storage | StorageClass `civo-volume`: provisioner `csi.civo.com`, reclaim `Delete`, `WaitForFirstConsumer`, `allowVolumeExpansion: true` (offline expansion: detach first). RWO shown. Volumes persist across node deletion and are **not** removed on cluster deletion (billed until deleted) | https://www.civo.com/docs/kubernetes/config/kubernetes-volumes | high |
| VolumeSnapshot / clone | **Not supported.** `ControllerGetCapabilities` lists only `CREATE_DELETE_VOLUME`, `PUBLISH_UNPUBLISH_VOLUME`, `LIST_VOLUMES`, `GET_CAPACITY`, `EXPAND_VOLUME`; snapshot capabilities are commented out and `CreateSnapshot`/`DeleteSnapshot`/`ListSnapshots` return `Unimplemented`; no `CLONE_VOLUME` | https://github.com/civo/civo-csi/blob/master/pkg/driver/controller_server.go | high |
| Cluster autoscaler | Marketplace app (`civo-cluster-autoscaler`) or the upstream Helm chart with `cloudProvider: civo`, `autoscalingGroups` (min/max per pool name) and Secret `civo-api-access`; `--nodes=min:max:poolname`; min 1; account quota wins; Terraform must `ignore_changes` on `node_count`; scale-down is blocked by pods without PDBs in `kube-system`, by PDBs (CNPG creates one even for one instance), and by local storage unless flags/annotations are set | https://civo.com/docs/kubernetes/scaling-nodes, https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/charts/cluster-autoscaler/README.md#civo, https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/FAQ.md | high |
| API key | Static per-account key; regenerate only; no documented scopes or expiry; org accounts may have several keys | https://www.civo.com/docs/account/api-keys | high |
| Short-lived tokens | `POST /v2/auth/exchange` converts the API key to a JWT (access, refresh, id token); OAuth client apps (auth-code, client-credentials) registered through support. All paths still need the static key | https://www.civo.com/api | high |
| ServiceAccount OIDC issuer | No documentation of a public or configurable issuer/JWKS for managed k3s. Web-identity federation to AWS unverified | negative search | low — spike recheck |
| Pricing (USD/month, uniform across regions, no tax stated) | Standard: XS 5.43, S 10.86, Medium (2 vCPU/4 GB) 21.73, Large (4 vCPU/8 GB) 43.45. RAM-optimized Small (2 vCPU/16 GB) 78.21. LB 10.86 per 10 000 concurrent requests. Block storage 0.11 per GB. Egress and ingress free | https://www.civo.com/pricing | high |
| Object store | Sized in 500 GB increments, hourly billing; 0.01086 USD/GB/month → ~5.43 USD/month at the 500 GB minimum | https://www.civo.com/pricing, https://www.civo.com/docs/object-stores | medium |

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
| CNPG barman plugin | `ObjectStore` with `s3Credentials` secret refs; recovery via `bootstrap.recovery.source` + `externalClusters[].plugin`. CNPG's only PVC-source recovery (`volumeSnapshots.storage.kind: PersistentVolumeClaim`) sets `DataSource` on a new PVC, i.e. a CSI clone, which Civo lacks; no documented adoption of a pre-existing PVC | https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/, https://github.com/cloudnative-pg/cloudnative-pg/blob/main/config/crd/bases/postgresql.cnpg.io_clusters.yaml | high |

## Cost model (USD/month, 2026-09-06 prices, no tax, region-uniform)

Civo, one Large pool, autoscaler 1–3, LB, 20 GB CNPG volume:

| Nodes running | Nodes | LB | Volume | Total |
|---|---|---|---|---|
| 1 (expected idle) | 43.45 | 10.86 | 2.20 | 56.51 |
| 2 | 86.90 | 10.86 | 2.20 | 99.96 |
| 3 (burst) | 130.35 | 10.86 | 2.20 | 143.41 |

Observability volumes on Civo (Prometheus 10 Gi, Alertmanager 1 Gi, Grafana 1 Gi, Loki 10 Gi) add ~2.42. Reserved IP: price unknown, expected a few USD. Civo snapshots: priced as storage, expected < 3 for two retained 20 GB snapshots.

Retained AWS while Civo runs: Route 53 zone ~0.50 plus queries; SSM standard parameters free; KMS key ~1.00; S3 state cents; Roles Anywhere free. GitHub OIDC free.

AWS costs that disappear when running Civo instead of EKS: EKS control plane ~73, NLB ~16–22, EC2 system node ~25, Karpenter nodes variable, EBS ~2–4.

Uncertainties: reserved IP price; object store price; whether allocatable memory on Large matches the documented ~5.9 GiB after CCM/CSI pods; whether idle really holds at 1 node with observability enabled (measured in CIVO-175).

## Later experiments (bounded, not run in planning)

1. CIVO-020: create one Medium k3s cluster with a 5 GB PVC; delete the cluster; check the account for the volume; create a second cluster in the same network; try a static PV rebind by volume ID (experiment only). Record default-app names, allocatable memory, LB status, and object-store pricing. Expected cost under 2 USD.
2. CIVO-020: read `/.well-known/openid-configuration` and `/openid/v1/jwks` from the API server with the kubeconfig; note whether unauthenticated access exists.
3. CIVO-090: from a pod with a cert-manager-issued certificate, run `aws_signing_helper serve`, call `aws sts get-caller-identity`, then repeat with a certificate whose CN does not match the role's trust policy (expect denial).
4. CIVO-070: issue one Let's Encrypt staging certificate via HTTP-01 through the Gateway; then destroy and recreate the cluster and confirm the re-imported Secret is reused without a new order.
