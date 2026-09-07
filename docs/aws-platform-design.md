# AWS platform design (as implemented)

How the AWS/EKS target works today, stage by stage, with the files that
implement each part. This is the current-state companion to
`docs/architecture.md` (target state) and the baseline the Civo target
(`docs/civo-high-level-design.md`) reuses.

Baseline: branch `main`, commit `cfbb59bd340b6356bad3fb2493b41fa3a337efe5`, 2026-09-06.
Pinned versions: Terraform 1.15.9, AWS provider 6.60.0, Terragrunt 1.1.3,
Helm 4.1.4, Kubernetes 1.36, `terraform-aws-modules/eks` 21.25.0, Argo CD
chart 10.4.0, Go 1.26.

## 1. Operator surface

```
make account-up      # once per AWS account
make bootstrap-up    # once per project: state bucket, Route 53 zone, ACM
make persistent-up   # VPC, SSM secrets
make cluster-up      # EKS + Pod Identity roles
make argo-up         # Argo CD + root Application, waits for Synced/Healthy
make down            # argo-down + cluster-down
```

Composites: `up` = cluster-up + argo-up; `platform-up` adds persistent-up;
`full-up` adds bootstrap-up. `account-up` is in no composite. Every target
runs `clear-cache` first (`Makefile:23-53`). Variables: `PROJECT_NAME`
(default `vk-lab-platform`), `SUBDOMAIN` (default `lab`); the region is a
constant `eu-west-1` declared once per layer (ADR 0024).

Every script configures its own kubeconfig; nothing depends on a prior
`make kubeconfig` (`Makefile:132-139`).

## 2. Stages and what they own

### Account (shared, `terraform/live/account/`)

Applied in fixed order by `scripts/account-up.sh`: `kms` (`alias/lab-secrets`,
rotation on) → `github-oidc` (provider for `token.actions.githubusercontent.com`)
→ `eks-access-identity` and `eks-test-identity` (roles with no AWS policy;
Kubernetes access only, ADR 0022) → `lab-role` (the single CI role, ~30
statements, `terraform/modules/lab-role/main.tf`) → `root-domain` (decrypts
`secrets/root-domain.enc`, writes `/account/root_domain` to SSM). Ends with
`gh variable set AWS_ROLE_ARN`. State bucket: `<owner>-account-state`.

### Bootstrap (`terraform/live/bootstrap/`)

`scripts/bootstrap-up.sh`: `state-up` (creates `${PROJECT_NAME}-tf-state`
with a temporary local backend then migrates) → `generate-secrets` →
`require-persistent-secrets` → `require-unique-subdomain` → `terragrunt run
--all apply`. Units: `route53` (zone `lab.<root-domain>`, NS delegation in
the parent zone, SSM `fqdn`/`subdomain`) and `acm` (cert for the zone and
wildcard, DNS validated, SSM `certificate_arn`).

### Persistent (`terraform/live/persistent/`)

`vpc` (two public subnets, no NAT, ADR 0020) and `secrets` (decrypts
`secrets/<project>/*.enc`, writes SSM `SecureString` parameters for the
Postgres app password and Grafana admin password, plain `String` for the
Argo admin bcrypt). `scripts/persistent-down.sh` refuses while `cluster/`
state is non-empty, then also deletes retained EBS volumes and Postgres
snapshots by tag.

### Cluster (`terraform/live/cluster/`)

`eks` (managed control plane, `authentication_mode = API`, two access
entries, `vpc-cni` with prefix delegation, `eks-pod-identity-agent`, one
system node group `t4g.medium` labeled `node-type=system`) plus five Pod
Identity units: `karpenter`, `ebs-csi-pod-identity`,
`aws-lb-controller-pod-identity`, `external-dns-pod-identity`,
`external-secrets-pod-identity`. Cross-stack reads (`persistent/vpc`,
`bootstrap/route53`) use absolute `get_repo_root()` paths so
`run --all destroy` never crosses stacks. `scripts/cluster-down.sh` refuses
while the root Application exists, destroys, then sweeps EC2/EBS/ELB leaks
by tag.

### Argo (`scripts/argo-up.sh`, `scripts/argo-down.sh`)

See `docs/argocd-design.md`. Inputs come from one batched SSM read
(certificate ARN, VPC id, node subnet id, FQDN, Argo admin bcrypt) and a
Terragrunt output (`cluster_name`).

## 3. Runtime architecture

```
client → Route 53 (ExternalDNS, txtOwnerId=<project>)
       → NLB (AWS Load Balancer Controller; TLS listener with ACM cert; proxy protocol)
       → Envoy Gateway Service (Gateway listener HTTP:443, no cert on Envoy)
       → HTTPRoutes (argo.<fqdn>, grafana.<fqdn>) → Services
```

Compute: system node group for controllers; Karpenter `spot` and
`on-demand` NodePools (arm64, cpu limits from `argo-up.sh` env), workloads
avoid spot via anti-affinity (ADR 0019); Postgres pins to
`workload-type: on-demand`.

Storage: EBS CSI via Argo (ADR 0008), StorageClasses `ebs-delete` (used) and
`ebs-retain` (reserved), `VolumeSnapshotClass ebs-postgres-snapshot` with
`Retain`. Postgres persistence is a snapshot taken at `argo-down` and
restored at `argo-up` (ADR 0013).

Secrets: ESO `ClusterSecretStore aws-parameter-store` with no `auth` block
(controller Pod Identity), two `ExternalSecret`s (Postgres app password,
Grafana admin). Identity per controller via Pod Identity associations.

Observability: kube-prometheus-stack (7d retention, EKS control-plane
scrapes disabled), Loki single-binary on filesystem, Alloy DaemonSet,
metrics-server with `--kubelet-insecure-tls`. Tempo/OTel deferred (ADR 0018).

## 4. Secrets and configuration flow

```
secrets/root-domain.enc ──KMS──> /account/root_domain ──> route53 unit ──> /<project>/bootstrap/route53/fqdn
secrets/<project>/*.enc ──KMS──> persistent/secrets ──> /<project>/persistent/{postgres,grafana,argocd}/...
argo-up.sh ──ssm get-parameters──> helm --set ... ──> root Application parameters ──> gitops values
ESO ──Pod Identity──> SSM SecureString ──> Kubernetes Secrets
```

Rules: no plaintext in Git; one ciphertext file per value; KMS key is
account-global; SSM paths `/<project>/<layer>/<unit>/<key>`.

## 5. Teardown ordering

`make down` = `argo-down` then `cluster-down`. `argo-down`: prove the
cluster exists via the EKS API → CNPG `Backup` (volumeSnapshot) and wait →
prune old snapshots → disable auto-sync on all Applications → delete
HTTPRoutes → poll Route 53 until ExternalDNS records are gone → delete the
Gateway → poll until the LoadBalancer Service is gone → foreground-cascade
delete the root Application (reverse waves) → `helm uninstall` root and
Argo CD. Then `cluster-down` destroys Terraform and sweeps leaks.

## 6. CI

One workflow, `.github/workflows/lab.yml`, `workflow_dispatch` only, assumes
`vars.AWS_ROLE_ARN` via OIDC, runs `make <target>`, then `make test` on
`up`-like targets. No fork-PR path, no concurrency group, no
cleanup-on-failure (documented gaps).

## 7. Tests

Ginkgo suite under `tests/e2e/` with an `Environment` interface
(`framework/environment.go`); AWS implementation resolves service URLs from
`HTTPRoute`s and Postgres via port-forward. Zero AWS SDK calls. Context
supplied by `make test-kubeconfig` using `eks-test-identity`, mapped to the
`e2e-test-readonly` group by an EKS access entry.

## 8. Known gaps

- `scripts/state-down.sh` guards prefix `disposable`, real prefix is `cluster`.
- `terraform/live/ci/` referenced in `root.hcl`, not present.
- `local` target (spec 022) and kind CI (spec 024) not implemented.
- `README.md` and `docs/architecture.md` still list Kafka as running; see `docs/architecture-review-2026-09-06.md`.
