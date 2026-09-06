# Civo target: architecture, coupling inventory, and change map

Companion to `docs/civo-high-level-design.md` (decisions) and
`docs/aws-platform-design.md` (current AWS state). Baseline: `main` at
`cfbb59bd340b6356bad3fb2493b41fa3a337efe5`, 2026-09-06. Paths marked
*(proposed)* do not exist yet.

## 1. Current AWS flow (condensed)

```
make bootstrap-up  → state bucket, Route 53 lab zone, ACM            (terraform/live/bootstrap)
make persistent-up → VPC, SSM secrets                                (terraform/live/persistent)
make cluster-up    → EKS + 5 Pod Identity units                      (terraform/live/cluster)
make argo-up       → SSM read → kubeconfig → snapshot discovery
                   → helm argocd → helm root-application(target=aws) (scripts/argo-up.sh)
Argo root          → 12 child Applications + raw resources           (gitops/templates/platform/aws/**)
make argo-down     → CNPG snapshot → DNS wait → LB wait → cascade    (scripts/argo-down.sh)
make cluster-down  → terragrunt destroy → leak sweep                 (scripts/cluster-down.sh)
```

## 2. AWS coupling inventory

Classification: **shared** = as-is; **shared/refactor** = shared after a bounded
values/gating change; **provider** = provider-specific implementation;
**n/a** = not applicable on Civo.

| Component | Existing implementation and evidence | AWS coupling | Classification | Civo equivalent / omission | Required change | Owning spec IDs |
|---|---|---|---|---|---|---|
| Make surface | `Makefile:10-17` vars; `:23-53` composites; `:107,125` `cd terraform/live/{persistent,cluster}`; `:140-143,159-162` kubeconfig | `aws eks update-kubeconfig`, fixed stack dirs | shared/refactor | `PROVIDER ?= aws`; civo defaults `PROJECT_NAME=vk-civo-lab`, `SUBDOMAIN=civo`; stack dir and kubeconfig dispatch | add dispatch, keep AWS path byte-identical | 010 |
| State backend | `terraform/live/root.hcl:72-85` S3 + lockfile; bucket from `PROJECT_NAME` | S3 | shared | Civo project gets `vk-civo-lab-tf-state` via unchanged `state-up` | none | 010, 025 |
| Provider generation | `root.hcl:51-68` single `provider "aws"` + `default_tags` | AWS provider only | shared/refactor | add `provider "civo"` when `path_parts[0]` ∈ {`persistent-civo`,`cluster-civo`}; Civo region constant | small HCL change | 025, 030 |
| Lifecycle mapping | `root.hcl:48` lookup | prefixes `account`, `cluster` | shared/refactor | add `persistent-civo`→persistent, `cluster-civo`→disposable | lookup entries | 025, 030 |
| Region constant | `root.hcl:12`, `scripts/lib/region.sh:5`, `gitops/values.yaml:7`, `Makefile:14`, `lab.yml` | `eu-west-1` | shared | AWS region unchanged (Route 53/SSM/Roles Anywhere stay in eu-west-1); new `LON1` constant for Civo declared in `root.hcl` and `scripts/lib/region.sh` | add Civo constant | 030 |
| Account layer | `terraform/live/account/*`, `scripts/account-up.sh` | all AWS | shared | unchanged; `lab-role` gains scoped `rolesanywhere:*`, IAM role names for consumers, SSM `/<project>/cluster-civo/*` | `lab-role` policy additions | 082 |
| Bootstrap route53 | `terraform/live/bootstrap/route53`, `modules/route53-zone` | Route 53 | shared | zone `civo.<root-domain>` for the civo project | none | 025 |
| Bootstrap acm | `terraform/live/bootstrap/acm` | ACM | n/a | excluded for civo project (`--queue-exclude-dir`) | Make exclusion | 025 |
| Roles Anywhere | — | — | provider (AWS side) | *(proposed)* `terraform/live/bootstrap/rolesanywhere`, `modules/rolesanywhere` guarded by `fileexists()` on the CA cert | new unit | 080, 082 |
| Persistent vpc | `terraform/live/persistent/vpc` | VPC | n/a | excluded for civo project | Make exclusion | 025 |
| Persistent secrets | `terraform/live/persistent/secrets`, `modules/persistent-secrets` | KMS decrypt → SSM | shared | same, under the civo project prefix | none | 025 |
| Civo network / reserved IP | — | — | provider | *(proposed)* `terraform/live/persistent-civo/{network,reserved-ip}` | new stack | 025 |
| Cluster | `terraform/live/cluster/eks`, `modules/eks` | EKS, access entries, addons | provider | *(proposed)* `terraform/live/cluster-civo/{network,k8s}`, `modules/civo-network`, `modules/civo-k8s` | new stack | 030 |
| Capacity | `modules/karpenter-pod-identity`, `gitops/.../karpenter/*` | Karpenter, EC2NodeClass, spot label | provider | one Large pool + Civo autoscaler 1:3; labels `kubernetes.civo.com/node-pool` | new units; values toggles for spot affinity | 030, 170, 050 |
| Storage | `gitops/.../ebs-csi/*` (driver, `ebs-delete`, `ebs-retain`, VolumeSnapshotClass) | EBS CSI, gp3, tags | provider | `civo-volume` (CSI preinstalled); `VolumeSnapshotClass csi.civo.com` Retain if spike passes | civo StorageClass/SnapshotClass files; `storage.className` value at 5 sites | 050, 120 |
| Snapshot controller | `ebs-csi/snapshot-controller.yaml` (CRDs v8.6.0 + controller) | none | shared/refactor | hoist to shared | move file, keep waves | 050 |
| Load balancing | `gitops/.../aws-load-balancer-controller/*`, `envoy-gateway/webhook-ready-probe.yaml` | ALB controller, NLB annotations | n/a | Civo CCM built in; probe Job deleted for civo | gate out | 050, 060 |
| Envoy Gateway chart | `envoy-gateway/application.yaml` | none | shared/refactor | hoist | move | 050 |
| EnvoyProxy Service | `envoy-gateway/gateway.yaml:2-44` | 6 NLB annotations, proxy protocol | provider | Civo annotations (`firewall-id`, `ipv4-address`) | values-driven annotations | 060 |
| Gateway listener | `gateway.yaml:61-80` HTTP:443 (TLS at NLB) | architecture | provider | HTTP:80 + HTTPS:443 with cert-manager Secret | values-driven listeners | 060, 070 |
| ClientTrafficPolicy | `gateway.yaml:84-97` proxy protocol | paired with NLB annotation | provider | off in M1; P3 | toggle | 060, 190 |
| TLS | ACM cert on NLB (ADR 0011) | ACM | provider | cert-manager + Let's Encrypt HTTP-01 at Envoy; Secret persisted via SSM across down/up | new component | 065, 070 |
| DNS | `external-dns/application.yaml` (`provider aws`, Pod Identity, `txtOwnerId={{project}}`) | Pod Identity | shared/refactor | same chart; sidecar auth; `txtOwnerId=vk-civo-lab`; zone `civo.<root-domain>` | civo `application.yaml` branch | 110 |
| Secrets (ESO) | `external-secrets/application.yaml`, `secretstore.yaml` (no `auth`) | controller Pod Identity | shared/refactor | store/ExternalSecrets hoist verbatim; chart gets `extraContainers` sidecar on civo | civo `application.yaml` branch | 050, 100 |
| Workload identity | 5 Pod Identity modules | EKS Pod Identity | provider | Roles Anywhere: CA, trust anchor, roles, cert-manager CA issuer, helper sidecar | new chain | 080, 082, 085, 090 |
| PostgreSQL | `postgres/application.yaml`, `cluster.yaml`, `recovered-snapshot.yaml`, `priorityclass.yaml` | `ebs-delete`, nodeSelector, EBS snapshot handle | shared/refactor | operator hoisted; Cluster values-driven; recovery via Civo snapshot or retained volume | values + civo recovery template | 050, 120 |
| Observability | `observability/*` | `ebs-delete`, spot affinity, EKS scrape workarounds, Karpenter dashboards | shared/refactor | same charts on civo storage; k3s scrape targets; Karpenter assets gated | values + gating | 160 |
| Argo CD install | `scripts/argo-up.sh:201-223` | spot anti-affinity `:221-222` | shared/refactor | drop affinity on civo | branch | 045 |
| Argo inputs | `argo-up.sh:34-78` (Terragrunt output, SSM batch, kubeconfig) | EKS | shared/refactor | Civo: `civo kubernetes config`, same SSM read minus ACM/VPC/subnet | branch | 045 |
| Postgres recovery | `argo-up.sh:167-197`, `argo-down.sh:54-113` | EBS snapshots | provider | Civo snapshot discovery/prune via `civo` CLI, or retained volume | branch | 045, 120 |
| Teardown gates | `argo-down.sh:169-230` | Route 53 poll, LB Service poll | shared/refactor | Route 53 poll unchanged (needs AWS creds, present); LB poll unchanged (CCM deletes LB) | branch for cluster existence proof | 045 |
| Cluster down | `scripts/cluster-down.sh` | EKS describe, tag sweeps | provider | `civo kubernetes show`; sweep volumes/LBs/firewalls by name via `civo` CLI | branch | 040 |
| Guards | `bootstrap-down.sh:31`, `persistent-down.sh:74,116`, `status.sh:26,59`, `state-down.sh:30` | S3 prefixes | shared/refactor | add `cluster-civo`, `persistent-civo` prefixes; fix `disposable`→`cluster` bug | edits | 040 |
| `require-persistent.sh:36` | `aws iam get-role eks-access-identity` | EKS identity | shared/refactor | skip on civo | branch | 040 |
| Tests | `tests/e2e/**`, `Makefile:159-172` | `aws eks update-kubeconfig`, EKS access entry group | shared/refactor | SA token context; `Environment` reused | Make dispatch, RBAC manifest | 130 |
| CI | `.github/workflows/lab.yml` | OIDC role; region literal | shared/refactor | `provider` input; token decrypt + mask; concurrency; cleanup | workflow edits | 140 |
| Civo token | — | — | provider | `secrets/civo-token.enc` + `scripts/lib/civo-token.sh` *(proposed)* | new helper | 010, 040 |
| Tagging §16 | `default_tags`, StorageClass tags | AWS tags | provider | Civo `tags` string on cluster/network; documented best-effort | ADR variant | 015, 030 |
| Kafka/Debezium | deferred (ADR 0017) | — | n/a | out of scope | none | — |

## 3. Target architecture

See `docs/civo-high-level-design.md` §3–§5 for stage model, diagrams, and
provider contract. Summary of what changes per layer:

- **Make/scripts**: `PROVIDER` dispatch; `scripts/lib/provider.sh` *(proposed)* exporting `PROVIDER`, project/subdomain defaults, stack dir names, and `civo_token()`; branches in `argo-up.sh`, `argo-down.sh`, `cluster-down.sh`, `status.sh`, guards.
- **Terraform**: three new stack directories (`bootstrap/rolesanywhere` unit, `persistent-civo/`, `cluster-civo/`), three new modules, `root.hcl` provider generation and lifecycle lookup, `lab-role` additions. No moved resources.
- **GitOps**: `gitops/templates/platform/shared/` *(proposed)* for hoisted components; `gitops/templates/platform/civo/` *(proposed)* for provider files; new values keys (`storage.className`, `capacity.spotAvoidance`, `postgres.nodeSelector`, `envoyGateway.service.annotations`, `envoyGateway.tls.mode`, `certManager.enabled`, `awsIdentity.mode`, `externalDns.txtOwnerId`, `observability.k3s`).
- **Identity**: CA ceremony script, `secrets/<project>/civo-ca-cert.pem` + `civo-ca-key.enc`, Roles Anywhere unit, cert-manager CA ClusterIssuer Secret at `argo-up`, per-consumer Certificates, helper sidecar image workflow.
- **Tests/CI**: `CivoEnvironment` shim (reuse), SA-token context, `lab.yml` provider input.

## 4. Provider contract (inputs and outputs)

| Name | Type | Source of truth | Default | Validation | Secret | Owner | Reaches Argo/Helm via |
|---|---|---|---|---|---|---|---|
| `PROVIDER` | enum aws\|civo | operator/CI input | `aws` | Makefile guard | no | Make | `--set target` |
| `PROJECT_NAME` | string | operator input | `vk-lab-platform` (aws) / `vk-civo-lab` (civo) | `require-*` scripts | no | Make | `--set project` |
| `SUBDOMAIN` | string | operator input | `lab` / `civo` | `require-unique-subdomain` | no | Make | via SSM `fqdn` |
| `CIVO_TOKEN` | string | `secrets/civo-token.enc` | — | non-empty | yes | scripts | never; Terraform/CLI env only |
| Civo region | constant | `root.hcl`, `scripts/lib/region.sh` | `LON1` | none | no | repo | not templated |
| `fqdn` | string | SSM `/<project>/bootstrap/route53/fqdn` | — | non-empty | hygiene | route53 unit | `envoyGateway.fqdn` |
| `reservedIp` | string | SSM `/<project>/persistent-civo/reserved-ip/address` *(proposed)* | — | IPv4 | no | persistent-civo | `envoyGateway.service.annotations` |
| `firewallId` | string | SSM `/<project>/cluster-civo/network/firewall_id` *(proposed)* | — | non-empty | no | cluster-civo | `envoyGateway.service.annotations` |
| `rolesAnywhere.{trustAnchorArn,profileArn,roleArns}` | strings | SSM `/<project>/bootstrap/rolesanywhere/*` *(proposed)* | — | ARN | no | bootstrap | sidecar args via values |
| `storage.className` | string | values per target | `ebs-delete` / `civo-volume` | exists in cluster | no | gitops | direct |
| `postgres.recoverySnapshotHandle` | string | discovered at argo-up | `""` | provider-specific | no | scripts | `--set` |
| `certManager.enabled` | bool | values per target | false / true | — | no | gitops | direct |
| `awsIdentity.mode` | enum podIdentity\|rolesAnywhere | values per target | podIdentity / rolesAnywhere | enum | no | gitops | direct |

Provider-specific configuration (EC2NodeClass, EBS parameters, NLB or Civo
annotations) never leaves the `aws/` or `civo/` subtree.

## 5. State, lifecycle, ownership

- Terraform owns Civo network, firewall, cluster, node pool, reserved IP, and all AWS resources. Argo CD owns everything in-cluster after `argo-up`. Terraform never touches Kubernetes objects; `argo-up` creates exactly one untracked Secret (the CA key) and one optional re-imported TLS Secret, both outside Argo's ownership and never pruned.
- State: separate buckets per project; separate stack directories per lifecycle; `run --all` scoping prevents cross-stack discovery. Deleting the Civo cluster (`cluster-civo/`) cannot reach `bootstrap/`, `persistent/`, `persistent-civo/`, or any AWS project.
- Sensitive outputs: kubeconfig never in state (`write_kubeconfig=false`); CA key never in state; Civo token never in state or tfvars.
- Concurrency: S3 lockfiles per unit; CI concurrency group `<project>-<provider>`.

## 6. Decision areas A–I (mapping to specs)

| Area | Decision summary | Specs |
|---|---|---|
| A repository boundary/state/contract | separate project + stack dirs; contract table above | 010, 025, 030, 050 |
| B lifecycle and Argo | same stage model; script branches; ordering identical; explicit LB/DNS gates | 040, 045, 050 |
| C cluster/networking/ingress | firewall 6443 + LB ports; Civo LB TCP; Envoy TLS; HTTP-01 | 030, 060, 065, 070 |
| D storage/CNPG | civo-volume; snapshot or retained volume; 1 instance, 20 Gi | 020, 120, 180 |
| E capacity | Large pool; autoscaler 1:3; right-sizing later | 030, 170, 175 |
| F identity/secrets | Roles Anywhere chain; ESO + ExternalDNS consumers; token in KMS | 080, 082, 085, 090, 100, 110 |
| G destruction/recovery | classification table in each spec; full-cycle validation | 040, 045, 150 |
| H tests/CI/cost | Ginkgo reuse; lab.yml; cost model in research.md | 130, 140, 175 |
| I future compatibility | no mandatory dependencies added; NetworkPolicy/quota hooks noted in 050 | 050 |
