# Local provider: architecture, coupling inventory, and change map

Baseline: branch `civo-115-cnpg-cluster-on-civo`, commit `db35b73`,
2026-09-11. Line numbers refer to that commit.

## 1. Goal

A developer with a running local cluster (minikube today; kind, k3d, or
Docker Desktop equally) runs `PROVIDER=local make up`, gets Argo CD, Envoy
Gateway, CNPG Postgres, and the observability stack installed into it,
opens `http://argo.localhost:8080` / `http://grafana.localhost:8080`
through `make local-forward`, and runs `make test` against it.
`make down` removes everything the platform installed; Postgres data
survives on the node in a `local-retain` volume; `make up` brings it back
with the data. The platform never creates or deletes the cluster. The
only cloud call is `aws kms decrypt` of the committed secret ciphertext. A
GitHub Actions job creates a kind cluster itself, then runs the same
commands.

## 2. Cloud coupling inventory and local replacement

The gitops layer already accepts `target=local`
(`gitops/templates/_helpers.tpl:7`) and `scripts/gitops-render-check.sh:59-83`
already enforces a `local` render contract — but that contract is the
inverse of the goal: it forbids `Gateway`, `EnvoyProxy`, `Cluster`,
`StorageClass`, and the observability Applications, and requires the
External Secrets Application. Today's `target=local` render is operators
without their custom resources, plus one dangling `HTTPRoute`. LOCAL-030
inverts that contract.

### 2.1 Lifecycle and command surface

| Today | Where | Local |
|---|---|---|
| `PROVIDER` allowlist `aws\|civo` | `Makefile:10-12`, `scripts/lib/provider.sh:8-10` | add `local`; `PROJECT_NAME=vk-local-lab`, no `SUBDOMAIN` |
| `state-up`, `bootstrap-up` (Terragrunt) | `Makefile`, `scripts/bootstrap-up.sh` | no-op with a one-line message |
| `persistent-up` (Terragrunt, secrets to SSM) | `Makefile:128-136` | no-op; in CI only, generate `secrets/<project>/` if missing (LOCAL-090) |
| `persistent-down` | `scripts/persistent-down.sh` | no-op that prints where the data lives on the node |
| `require-persistent.sh` reads S3 state keys | `scripts/require-persistent.sh:14-31` | skip on local |
| `cluster-up` (Terragrunt EKS/Civo) | `Makefile:152-160` | **context guard only**: current kubectl context must match `LOCAL_CONTEXT_PATTERN` and answer; never creates a cluster |
| `cluster-down` (`terragrunt destroy` + AWS leak sweep) | `scripts/cluster-down.sh:46,95-206` | no-op ("cluster is developer-owned") |
| `cluster_exists` / `configure_kubeconfig` | `scripts/lib/provider.sh:61-95` | the same guard / no-op |
| `kubeconfig`, `test-kubeconfig` | `Makefile:181-188,204-213` | no-op; the developer's current context is used |
| `status` | `scripts/status.sh` | current context, Argo root health, `local-retain` PVs |
| — | — | `make local-forward` (new, convenience): foreground `kubectl port-forward` to Envoy on `LOCAL_HOST_PORT` |

### 2.2 `argo-up.sh` / `argo-down.sh`

Every non-civo branch assumes AWS. Each needs a `local` case.

| Function | Where | AWS behaviour | Local |
|---|---|---|---|
| `aws_resolve_inputs` | `scripts/argo-up.sh:53-78,131-135` | SSM + `terragrunt output` | `fqdn=localhost`; bcrypt read from `secrets/<project>/argocd-admin-password.bcrypt`; no SSM |
| `ensure_ca_secret` precedent | `scripts/argo-up.sh:217-230` | civo only | reuse the shape: create namespaces, then `lab-postgres-app` (`cnpg-system`, `basic-auth`, username `vkdb`) and `grafana-admin-credentials` (`observability`, `admin-user`/`admin-password`) from `scripts/secret-decrypt.sh`, labelled `managed-by=argo-up` |
| `aws_resolve_snapshot` | `scripts/argo-up.sh:296-334` | `ec2 describe-snapshots`, aborts on failure | skip; recovery handle empty (as civo) |
| `install_argocd` | `scripts/argo-up.sh:336-370` | spot anti-affinity unless civo | extend the guard to local; everything else unchanged |
| `aws_install_root_application` | `scripts/argo-up.sh:427-431` | `--set target=aws` + ARNs | `--set target=local`, `envoyGateway.fqdn=localhost`, `capacity.spotAvoidance=false`, `storage.className=local-retain`, `targetRevision=<current branch>` |
| readiness | `scripts/argo-up.sh:471-517` | root Synced/Healthy then NLB-vs-Route53 `dig` | root Synced/Healthy then a temporary port-forward to Envoy and `curl --resolve argo.localhost:<port>:127.0.0.1 http://argo.localhost:<port>/healthz` |
| `cluster_exists` gate | `scripts/argo-down.sh:30-33` | `aws eks describe-cluster` | the context guard |
| `aws_cnpg_backup_and_prune` | `scripts/argo-down.sh:118,149-151` | `volumeSnapshot` Backup, `exit 1` if it never completes | skip; data stays in the `Retain` volume on the node |
| Route 53 record wait | `scripts/argo-down.sh:214-245` | unconditional `aws route53` | skip |
| cascade + Secret cleanup | `scripts/argo-down.sh` | delete root Application, wait | unchanged; then delete the two `managed-by=argo-up` Secrets; optionally delete `Released` `local-retain` PVs (LOCAL-040) |

### 2.3 gitops components

| Component | Where | aws | civo | Local |
|---|---|---|---|---|
| Argo CD | `scripts/argo-up.sh:336-370`, `gitops/argocd/values.yaml` | Helm 10.4.0, ClusterIP | same | same |
| Envoy Gateway chart | `gitops/templates/platform/shared/envoy-gateway/application.yaml` | installs Gateway API CRDs | same | same, un-gated |
| `EnvoyProxy` Service | `shared/envoy-gateway/gateway.yaml:18-62,100-130` | NLB + ACM annotations | Civo LB annotations | `type: ClusterIP`, no annotations; reached by port-forward |
| Gateway listeners | `gateway.yaml:74-82,149-159` | HTTP on 443 (NLB terminates TLS) | HTTPS with `platform-public-tls` | one HTTP listener on 80 |
| HTTPRoutes | `shared/envoy-gateway/httproutes.yaml:15,19,25,41,43` | `sectionName: https`, hostnames `argo.<fqdn>`, `grafana.<fqdn>` (grafana aws-gated) | same | `sectionName` templated per target; grafana route gated `aws\|local`; hostnames become `argo.localhost`, `grafana.localhost` |
| Envoy policies | `aws/envoy-gateway/policies.yaml` | rate limit / timeout | — | keep aws-gated |
| cert-manager | `aws/cert-manager/`, `civo/cert-manager/` | LBC webhook cert | Let's Encrypt | none |
| ExternalDNS | `shared/external-dns/application.yaml` | Route 53 via Pod Identity | Route 53 via Roles Anywhere sidecar | none (already `ne target "local"`) |
| External Secrets | `shared/external-secrets/application.yaml` (ungated), `secretstore.yaml:1` | SSM via Pod Identity | SSM via sidecar | none — gate the Application off; Secrets come from `argo-up` |
| EBS CSI, snapshot controller, `ebs-*` StorageClasses, `VolumeSnapshotClass` | `aws/ebs-csi/*` | EBS | — (`civo-volume` built in) | none; platform-owned `local-path-provisioner` Application + `local-retain` StorageClass (`nodePath /var/lib/vk-local-lab`, `pathPattern ns/pvc`, Retain) |
| Karpenter, NodePools | `aws/karpenter/*` | EC2 | — | none |
| AWS Load Balancer Controller + webhook probe | `aws/aws-load-balancer-controller/*`, `aws/envoy-gateway/webhook-ready-probe.yaml` | NLB | — | none |
| CNPG operator | `shared/postgres/application.yaml` | wave -1 | same | same |
| CNPG `Cluster` | `shared/postgres/cluster.yaml:1,15-24,30,47-63` | nodeSelector, `volumeSnapshot` backup, snapshot recovery | `enablePDB: false`, `initdb`, no backup | as civo, plus `storageClass: local-retain`, `storageSize: 2Gi`, small `resources` |
| Observability (kube-prometheus-stack, Loki, Alloy, metrics-server, alerts, dashboards, monitors) | `aws/observability/*` | aws-gated; `storage.className` raw; `spotAvoidance` affinity | — (CIVO-160 pending) | un-gate for local; `retention: 2d`, PVCs 2Gi, `alertmanager.enabled: false`, Grafana no persistence; `grafana-admin-secret.yaml` (ExternalSecret) gated off |
| PriorityClass, RBAC | `shared/postgres/priorityclass.yaml`, `shared/rbac/*` | — | — | unchanged |

### 2.4 Secrets

The KMS key `alias/lab-secrets` is account-global
(`scripts/secret-encrypt.sh:14`, `terraform/modules/kms/main.tf:7-8`). KMS
ciphertext carries no encryption context (`scripts/secret-encrypt.sh:33-38`),
so a `.enc` file is portable between `secrets/<project>/` directories.

| File | AWS consumer | Local consumer |
|---|---|---|
| `secrets/<project>/postgres-app-password.enc` | Terraform → SSM → ESO | `argo-up` → `lab-postgres-app` Secret |
| `secrets/<project>/grafana-admin-password.enc` | Terraform → SSM → ESO | `argo-up` → `grafana-admin-credentials` Secret |
| `secrets/<project>/argocd-admin-password.bcrypt` | Terraform → SSM → `argo-up` | `argo-up` reads the file |
| `secrets/root-domain.enc`, `secrets/civo-token.enc` | account-global | unused |

`secrets/vk-local-lab/` is created by byte-copying the three
`secrets/vk-lab-platform/` files (user decision, 2026-09-11). For CI, see
`decisions.md` §3.

### 2.5 Tests

`tests/e2e/framework/environment.go:20-31` defines `Environment` with
`ServiceURL` and `PostgresDSN`; `suite_test.go:38` constructs
`NewAWSEnvironment` unconditionally. `Config.HTTPClient()`
(`framework/config.go:46`) builds the HTTP client outside the environment,
so a local dial override needs the client moved behind the interface.
`PostgresDSN` already port-forwards to the `-rw` pod
(`environment.go:78-115`); the local environment opens a second forward of
the same kind to the Envoy Service and dials it for every HTTP request.

### 2.6 CI

`.github/workflows/lifecycle-test.yml` runs five `validate-*` jobs, then
`up`, `test`, `down` as three separate jobs on three runners
(`:255,:299,:323`). A kind cluster does not cross a job boundary. Neither
workflow sets `PROVIDER`. `make gitops-check` (which renders `target=local`)
is wired into no workflow. The lab OIDC role already holds `kms:*` on the
`alias/lab-secrets` key (`terraform/modules/lab-role/main.tf:378-379`).
The workflow, not the Makefile, creates the kind cluster.

## 3. Target design

```
developer-owned cluster (minikube / kind / k3d / Docker Desktop; CI: kind via helm/kind-action)
│   kubectl context matches LOCAL_CONTEXT_PATTERN  ← the only thing cluster-up checks
├── Argo CD (helm, ClusterIP, bcrypt admin from secrets/)
│   └── root Application  --set target=local
│       ├── local-path-provisioner + local-retain StorageClass  (wave -1; /var/lib/vk-local-lab/<ns>/<pvc>, Retain)
│       ├── envoy-gateway  (EnvoyProxy ClusterIP, Gateway :80, HTTPRoutes *.localhost)
│       ├── cnpg-operator + Cluster lab-postgres  (1 instance, 2Gi, local-retain)
│       ├── kube-prometheus-stack, Loki, Alloy, metrics-server  (trimmed)
│       └── priorityclass, rbac
└── Secrets created by argo-up before root:  lab-postgres-app, grafana-admin-credentials

developer → make local-forward → 127.0.0.1:8080 → Envoy Service :80 → HTTPRoute by hostname → Argo CD / Grafana
e2e suite → its own SPDY port-forward to Envoy (and to Postgres, as today)
```

Lifecycle-class mapping (ADR 0032, LOCAL-015):

| Class | AWS | Local |
|---|---|---|
| (cluster) | Disposable (EKS) | outside the classes — developer-owned |
| Bootstrap | state bucket, OIDC, IAM, KMS | nothing — the KMS key is account-global and already exists |
| Persistent | VPC, Route 53, ACM, SSM secrets, retained EBS | the `local-retain` volume directories on the node |
| Disposable | Argo CD, NLB, workloads | Argo CD and every Argo-managed resource, plus the two `argo-up` Secrets |

No TLS. Chrome and Firefox resolve `*.localhost` to loopback; Safari and
command-line tools need `/etc/hosts` entries or `curl --resolve`.

## 4. Provider contract

Inputs the local provider reads: `PROJECT_NAME` (default `vk-local-lab`),
`PROVIDER=local`, `TARGET_REVISION` (default: current git branch),
`LOCAL_CONTEXT_PATTERN` (default matches `kind-`, `minikube`, `k3d-`,
`docker-desktop`, `rancher-desktop`, `orbstack`), `LOCAL_HOST_PORT`
(default `8080`, `local-forward` only), `ARGO_UP_*`/`ARGO_DOWN_*` timeouts.

Outputs: the platform installed into the current context;
`http://argo.localhost:<port>` and `http://grafana.localhost:<port>` while
`make local-forward` runs; data under `/var/lib/vk-local-lab/` on the node.

## 5. State, lifecycle, ownership

No Terraform, no Terragrunt, no remote state, no cluster tooling. Argo CD
owns every Kubernetes resource after bootstrap (constitution §2); the two
`argo-up` Secrets are the same exception the civo CA Secret already is.
The cluster is the developer's. The node data directory is created by the
platform's provisioner and never deleted by the platform; deleting the
cluster deletes it.

## 6. Change map (spec → files)

| Spec | Files |
|---|---|
| 010 | `Makefile`, `scripts/lib/provider.sh`, `scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/cluster-down.sh`, `scripts/require-persistent.sh`, `scripts/status.sh`, `scripts/persistent-down.sh`, `scripts/bootstrap-up.sh`, `secrets/vk-local-lab/` |
| 015 | `docs/adr/0032-local-third-provider.md` (new), `docs/adr/0006-*.md`, `specs/000-constitution/spec.md`, `docs/architecture.md`, delete `specs/022-*`, `specs/024-*`, cross-references |
| 020 | report in `research.md` only |
| 030 | `gitops/templates/_helpers.tpl`, `gitops/values.yaml`, `shared/external-secrets/application.yaml`, `shared/envoy-gateway/httproutes.yaml`, `scripts/gitops-render-check.sh` |
| 040 | `gitops/templates/platform/local/storage/{application,storageclass}.yaml` (new), `shared/postgres/cluster.yaml`, `scripts/argo-down.sh` (PV cleanup) |
| 050 | `shared/envoy-gateway/gateway.yaml`, `httproutes.yaml`, `scripts/argo-up.sh` readiness, `scripts/lib/provider.sh`, `Makefile` (`local-forward`) |
| 070 | `aws/observability/*` gates and values |
| 080 | `tests/e2e/framework/*`, `tests/e2e/suite_test.go`, `Makefile` test targets |
| 090 | `.github/workflows/lifecycle-test.yml`, `persistent-up` generate-secrets branch, `secrets/vk-local-ci/` |
| 110 | `README.md`, `docs/` |
