# Research: verified capabilities and uncertainties

Sources checked 2026-09-11. Items marked **spike** are answered by LOCAL-020,
not by reading.

## Local cluster tool

| Question | Finding | Source |
|---|---|---|
| kind vs minikube vs k3d | The platform no longer chooses: it installs into whatever local cluster the developer has (decided 2026-09-11). For CI, kind via `helm/kind-action` is the standard. Facts kept for LOCAL-110: kind boots ~30 s, multi-arch `kindest/node`; minikube is driver-dependent on macOS; k3d bundles Traefik/servicelb/local-path | kind.sigs.k8s.io/docs/user/configuration; hub.docker.com/r/kindest/node; k3d-io/k3d discussion 821 |
| LoadBalancer on kind | `cloud-provider-kind` is a separate sudo binary, self-described alpha, assigns ephemeral host ports on macOS. Not suitable for a scripted flow | github.com/kubernetes-sigs/cloud-provider-kind |
| Host directory mount on Docker Desktop macOS | `extraMounts.hostPath` must be under a shared path (Docker Desktop → Resources → File Sharing). virtiofs (Docker Desktop 4.6+) honours `chown`/`0700` inside bind mounts; the historical `initdb: could not change permissions` failure was osxfs/gRPC-FUSE. **spike** on the actual laptop | kind configuration docs; Docker Desktop release notes |

## Storage

| Question | Finding | Source |
|---|---|---|
| Deterministic directory per PVC | `rancher/local-path-provisioner` StorageClass parameters `nodePath` and `pathPattern` (Go template; default `{{ .PVName }}_{{ .PVC.Namespace }}_{{ .PVC.Name }}`). Setting `pathPattern: "{{ .PVC.Namespace }}/{{ .PVC.Name }}"` makes a recreated PVC land in the same directory | github.com/rancher/local-path-provisioner README |
| Bundled provisioners differ | kind: `rancher.io/local-path` at `/var/local-path-provisioner`, version varies by kind release. minikube: `storage-provisioner` (hostpath) at `/tmp/hostpath-provisioner/<ns>/<pvc>`. The platform installs its own pinned local-path-provisioner so the path pattern and node path are identical everywhere (LOCAL-040) |
| Retain + non-empty directory | The provisioner's setup script runs `mkdir -m 0777 -p` over an existing directory and does not fail; PGDATA is a `0700` subdirectory owned by uid 26 | local-path-provisioner helper script |
| CNPG on an existing PGDATA | CNPG's init job checks for `PG_VERSION` under PGDATA and logs "PGData already exists, no need to init" instead of running `initdb`. A fresh `Cluster` with `bootstrap.initdb` therefore adopts a populated directory when the PVC lands on it. Password drift is avoided by using the same KMS-decrypted password. **spike** | cloudnative-pg.io/docs storage; CNPG source `pkg/management/postgres/initdb.go` |
| `walStorage` | Optional; once added it cannot be removed. Omit locally | cloudnative-pg.io/docs/devel/storage |

## Ingress

| Question | Finding | Source |
|---|---|---|
| Exposure | `kubectl port-forward` to the Envoy Service is what the Envoy Gateway quickstart documents and works on every local cluster tool with no configuration. NodePort + kind `extraPortMappings` and `cloud-provider-kind` were rejected as tool-specific (decided 2026-09-11) | gateway.envoyproxy.io/docs/tasks/quickstart |
| Port in `:authority` | Gateway API hostname matching ignores the port; Envoy Gateway strips the port from `:authority` before matching. **spike** on v1.2.1 with `Host: argo.localhost:8080` through a port-forward | gateway-api.sigs.k8s.io HTTPRoute hostname semantics |
| `*.localhost` resolution | Chrome and Firefox resolve `*.localhost` to loopback natively (RFC 6761 §6.3). macOS `getaddrinfo` and Go's resolver do not. Safari does not. Command-line and Go tests need `curl --resolve` or a `DialContext` override | RFC 6761; Go `net` package behaviour |
| TLS | Plain HTTP is the common dev-lab choice. If parity is later wanted: cert-manager `SelfSigned` → CA `ClusterIssuer`, or mkcert's root as the CA Secret | dischord.org 2024-05-18 |

## Argo CD

| Question | Finding | Source |
|---|---|---|
| Source revision | `scripts/argo-up.sh:13-14` syncs `main` from GitHub. Argo cannot read an unpushed working tree; the developer pushes a branch and `argo-up` uses it as `targetRevision`. Gitea-in-cluster (CNOE idpbuilder pattern) was considered and rejected as too heavy for M1 | cnoe.io/docs/idpbuilder |
| Resource footprint | Argo CD ~600 MB, Envoy ~200 MB, CNPG ~300 MB, trimmed observability 2–3 GB. Plan 6 GB Docker Desktop minimum | oneuptime 2026-02-26; devopscube Loki guide |

## Observability trims

Loki is already `SingleBinary` with filesystem storage (ADR 0018). Trims for
local: `chunksCache`/`resultsCache` disabled (default chunks cache requests
multi-GB), Prometheus `retention: 2d` and `retentionSize`, Alertmanager off,
Grafana without persistence, PVCs 2Gi. Control-plane scrapes
(`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`) stay disabled — on
kind those components bind `127.0.0.1` and are unreachable anyway.

## GitHub Actions

| Question | Finding | Source |
|---|---|---|
| Runner size | Public-repo `ubuntu-latest`: 4 vCPU, 16 GB RAM, 14 GB SSD. Disk is the tight limit; prune `/usr/share/dotnet`, `/opt/ghc`, `/usr/local/lib/android` before pulling images | docs.github.com hosted runners reference |
| kind action | `helm/kind-action` (kind v0.33, kubectl v1.37 defaults; inputs `config`, `cluster_name`, `wait`) creates the cluster; the platform then installs into context `kind-<name>` | github.com/helm/kind-action |
| Timing | kind create ~1 min; Argo bootstrap to Healthy for a stack this size 6–10 min (CNOE reference platform reports ~6 min) | cnoe.io/docs/reference-implementation/local |
| Job boundaries | A kind cluster lives in the runner's Docker daemon and does not survive between jobs; local `up → test → down` must be one job with `if: always()` teardown steps | GitHub Actions job isolation |

## Reference projects

- CNOE idpbuilder — kind + Argo CD + Gitea, one binary, stacks overlaid on a base.
- GitOps Bridge — cluster-Secret labels drive ApplicationSets; same repo for kind and EKS.
- AWS EKS Blueprints Argo CD pattern — the cloud half of GitOps Bridge.

None were adopted wholesale; this repo already has a `target`-gated umbrella
chart, which is the simpler equivalent for three targets.
