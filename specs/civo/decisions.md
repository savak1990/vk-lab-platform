# Decisions

## 1. Accepted starting constraints (from the user, 2026-09-06)

See `docs/civo-high-level-design.md` §2 for the full table. In short:
`PROVIDER=aws|civo` on existing targets; Civo project `vk-civo-lab` with
subdomain `civo`; identical stage model; 60–80 USD idle target (soft);
one Large pool with autoscaler 1–3; Roles Anywhere with a single offline
CA; Civo token KMS-encrypted in repo; Route 53 kept; TLS at Envoy via
HTTP-01; LON1; full observability in M1; AWS behavior unchanged.

## 2. Proposed ADRs and amendments (not accepted until merged)

| ADR | Title | Conflict it resolves | Rationale | Reversibility |
|---|---|---|---|---|
| 0025 | Civo as a second disposable execution target under a separate project | architecture §10a (two targets), constitution §3/§18 scope, spec 027 `TARGET` naming | separate project keeps state, DNS, and secrets isolated; `PROVIDER` selects stack dirs and defaults | high: delete the stacks |
| 0026 | Envoy-terminated TLS with cert-manager on the Civo target | ADR 0011 ("no cert-manager, no Let's Encrypt"), invariant 10, constitution §14 ACM wording | Civo has no ACM/NLB; HTTP-01 through Gateway API needs no AWS creds; rate limit handled by persisting the TLS Secret across down/up and using staging in CI; ADR 0011 unchanged for AWS | medium |
| 0027 | IAM Roles Anywhere with an offline CA for AWS access from Civo workloads | constitution §5 "EKS Pod Identity or equivalent", ADR 0023 (SSM reachable only with AWS creds) | free; external CA accepted; blast radius: `lab-role` `kms:*` and `CIVO_TOKEN` transitively reach the CA key, so every role is reachable from a token compromise; mitigations: 24 h certs, CN-conditioned trust policies, disable-trust-anchor runbook, intermediate CA later | medium |
| 0028 | Civo static API token handling | constitution invariant 4 principle (no long-lived credentials in CI), spec 027 Open Question 1 | token is not an AWS credential (text of invariant 4 holds) but is long-lived; stored KMS-encrypted like every other secret, decrypted at run time, masked in CI, rotated by re-encrypt-and-commit; JWT exchange still needs the key; the cluster autoscaler needs an API key in-cluster, so a dedicated second key with its own ciphertext is used there | high |
| Constitution §20 | Civo target variant | §3 lifecycle scope, §8 traffic path, §14 ACM, §16 tagging, §19 fork steps | per-section variant, not a §18-style exemption: Civo cluster is Disposable; §4/§7/§17 hold | high |
| architecture §10a | three execution targets | text says two | add Civo column | high |
| ADR 0002 note | ExternalDNS ownership per project | §14 overlap rule | separate zones per project (`lab.` vs `civo.`), distinct `txtOwnerId` | high |
| ADR 0013 note | snapshot mechanism per provider | EBS-specific | Civo snapshot or retained volume; decided by CIVO-020 | medium |
| ADR 0019 note | spot avoidance only on AWS | label absent on Civo | values toggle | high |
| ADR 0022 note | Kubernetes access on Civo | EKS access entries | kubeconfig from Civo API; test identity via ServiceAccount token | medium |
| ADR 0024 note | Civo region constant | single-region rule | `LON1` declared once per layer; AWS region unchanged | high |
| Spec 027 | mark superseded by this package | — | keeps history | — |

## 3. Open decisions

| Decision | Options | Recommendation | Trade-offs | Reversible | Affected specs | Blocks READY |
|---|---|---|---|---|---|---|
| Persistence mechanism on Civo | (a) CSI VolumeSnapshot; (b) retained volume rebind; (c) barman backups to object store | **Decided 2026-09-06: (c).** `csi.civo.com` advertises no snapshot or clone capability (https://github.com/civo/civo-csi/blob/master/pkg/driver/controller_server.go), so (a) is impossible and CNPG's PVC-datasource recovery (which clones) is too | (c) needs static object-store keys (state exposure accepted, or manual encrypt) and a 500 GB minimum bucket | medium | 120, 150, 180 | no |
| Default application removal names | `-traefik2-nodeport`, `-metrics-server` vs Terraform `applications` semantics | confirm in spike | wrong names silently leave Traefik installed on 80/443 | high | 030 | yes (030) |
| Proxy protocol / client IP | on (hostname-only status, external-dns CNAME) vs off | off in M1 | client IP lost at Envoy in M1 | high | 060, 190 | no |
| ESO/external-dns sidecar injection | chart `extraContainers` vs Kustomize patch vs wrapper chart | `extraContainers` if the pinned charts support it | if unsupported, a small wrapper is needed | high | 090, 100, 110 | no (validated in 090) |
| Reserved IP | use (stable DNS) vs rely on LB IP | use | small monthly cost, price unverified | high | 025, 060 | no |
| Object-store credential source | Terraform `civo_object_store_credential` (keys in state) vs manual creation + `secret-encrypt.sh` | Terraform, state exposure accepted for the lab | manual path avoids state exposure at the cost of a ceremony | high | 180 | no |
| Object-store minimum size | accept 500 GB (~5.43 USD/month) vs no backups | accept | only persistence option on Civo | high | 180 | no |
| CI provider runs | enable `PROVIDER=civo` in `lab.yml` now vs later | now, guarded by an environment and concurrency group | token exposure surface in CI | high | 140 | no |
| Intermediate CA | M1 vs later | later (CIVO-200) | time-bounded blast radius vs extra issuance step | medium | 200 | no |

## 4. Rejected alternatives

- `make civo-up` command family: violates constitution §17.
- One project with provider-suffixed state keys: guard changes in every script; DNS ownership conflicts; more risk than a second project.
- AWS Private CA: 50 USD/month minimum.
- Static AWS access keys for controllers: forbidden by constitution §5.
- DNS-01 with Route 53 for Let's Encrypt: adds an AWS credential consumer for no benefit.
- Civo DNS: Route 53 already exists and is cheap.
- RAM-optimized Small nodes in M1: 78 USD per node.
- Deferring observability: Large pool has headroom.
