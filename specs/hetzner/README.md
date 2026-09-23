# Hetzner provider planning package

This folder holds the planning and specification documents for adding Hetzner
Cloud as a third execution target next to AWS/EKS and Civo. Unlike Civo,
Hetzner has no managed Kubernetes: the platform bootstraps Kubernetes with
k3s on `hcloud_server`s (every server installs k3s from its own cloud-init at
first boot — the control plane with embedded etcd, workers joining over the
private network with a Terraform-generated token; `cluster-up` only fetches the
kubeconfig over SSH and waits for every node to report Ready); `argo-up`
helm-installs the Hetzner cloud controller
manager before Argo CD (nothing schedules on a node the CCM has not
initialised), and Argo CD installs the CSI driver. Implementation code does
not live here. It lands in the
normal repository locations that each spec names.

ADR 0036 made Hetzner a target and chose kubeadm; ADR 0037 replaced the
bootstrap with k3s on 2026-09-20, and HETZ-017 carries that rewrite. Four specs
are `SUPERSEDED` by it and remain in the folder as the record of a design the
package no longer follows.

`docs/hetzner-high-level-design.md` explains why the platform adds
Hetzner, what changed in Hetzner's pricing, and why a self-bootstrapped
control plane is materially harder than Civo's managed offering.
`docs/civo-high-level-design.md` remains the design for the shared
non-EKS model (stage model, identity chain, persistence flow); this
package's `architecture.md` records only what Hetzner changes.
Baseline inspected: branch `civo-115-cnpg-cluster-on-civo`, 2026-09-11.

## Reading order

1. `docs/hetzner-high-level-design.md` — why Hetzner, pricing reality, why it is harder than Civo.
2. `docs/civo-high-level-design.md` — the shared non-EKS model this package extends.
3. `architecture.md` — what Hetzner changes, coupling inventory, target design, provider contract.
4. `research.md` — verified capabilities, prices, uncertainties (2026-09-11).
5. `decisions.md` — accepted constraints, proposed ADRs, open decisions.
6. `roadmap.md` — milestones, dependency graph, first PRs.
7. The spec you were asked to implement, plus its `depends_on` specs.

## Relationship to the Civo package

Most Civo work is reused, not repeated. Three kinds of reuse appear in the
index:

- **Cross-package dependency.** A `depends_on` entry of the form `CIVO-NNN`
  means the Civo spec must be `DONE` and its output is consumed as-is
  (identity chain, backup jobs, hoisted GitOps components).
- **Generalisation.** HETZ-016 and HETZ-018 turn the `= civo` branches and
  the `civo`-named identity objects into non-AWS or per-provider forms while
  keeping Civo byte-identical. Every later Hetzner spec assumes those two.
- **Mirror.** A spec with the same number as a Civo spec (025, 030, 040,
  045, 050, 060, 115, 120, 130, 140, 150, 160, 170, 175, 190) covers the same ground
  for Hetzner. Read the Civo spec first; the Hetzner spec records only the
  differences and the Hetzner-specific evidence.

Civo specs 180, 185, 186, 200, 205 and 210 are provider-neutral. Hetzner
depends on them and adds no spec of its own.

## Format note

Specs in this folder use the same YAML front matter and 14-section body as
`specs/civo/`. The folder name is `NNN-X-title`, where `X` is the status
letter (see `../README.md`). The number and the `id` field are the stable
identifiers. Never renumber them. Numbers step by ten and mirror the
Civo numbers where a mirror exists. Insert later work into the gaps without
renumbering.

## Status protocol

Identical to `specs/civo/README.md` (status table, flow, priority,
difficulty, model tier). One addition: a Hetzner spec whose `depends_on`
names a `CIVO-NNN` spec checks that spec's status in
`specs/civo/README.md`.

## Implementation-session protocol

Identical to `specs/civo/README.md` §Implementation-session protocol, with
two additions:

- Step 4 also runs the **Civo regression gate** the spec names. AWS and
  Civo behaviour must both stay unchanged; the golden render diff now covers
  three targets.
- Step 8 also updates `specs/civo/README.md` when a Hetzner spec changes a
  Civo spec's status or dependencies (HETZ-016, HETZ-018, HETZ-182 do).

## Index

| ID | Folder | Title | Status | Pri | Diff | Tier | Depends on | Milestone |
|---|---|---|---|---|---|---|---|---|
| HETZ-010 | [010-D-provider-command-surface](010-D-provider-command-surface/spec.md) | `PROVIDER=hetzner` operator input, defaults, token helper | DONE | P1 | S | standard | — | M0 |
| HETZ-015 | [015-D-governance-adrs-constitution](015-D-governance-adrs-constitution/spec.md) | ADR 0036, ADR 0029/0030/0024/0002/0022 amendments, constitution §20 per-provider, architecture §10a | DONE | P0 | M | strongest | — | M0 |
| HETZ-016 | [016-D-non-aws-generalisation](016-D-non-aws-generalisation/spec.md) | `= civo` script branches and `eq "civo"` gates become non-AWS; Civo behaviour unchanged | DONE | P0 | M | strongest | 010 | M0 |
| HETZ-017 | [017-D-k3s-bootstrap-governance](017-D-k3s-bootstrap-governance/spec.md) | k3s replaces kubeadm: ADR 0037, a note on ADR 0036, four specs retired, the package rewritten | DONE | P0 | M | strongest | 015 | M0 |
| HETZ-018 | [018-D-identity-chain-provider-naming](018-D-identity-chain-provider-naming/spec.md) | Roles Anywhere chain names parametrized by provider; Civo names unchanged | DONE | P0 | M | strongest | 010, 016 | M0 |
| HETZ-020 | [020-D-hetzner-feasibility-spike](020-D-hetzner-feasibility-spike/spec.md) | Feasibility spike: volume survival, LB lifecycle and orphaning, account limits, invoice | DONE | P0 | S | standard | 017 | M0 |
| HETZ-025 | [025-D-hetzner-persistent-stack](025-D-hetzner-persistent-stack/spec.md) | `persistent-hetzner` network, subnet, SSH key | DONE | P1 | S | standard | 010, 015, 080 | M1 |
| HETZ-030 | [030-D-hetzner-terraform-k3s-nodes](030-D-hetzner-terraform-k3s-nodes/spec.md) | `cluster-hetzner` firewall and `NODE_COUNT` `cx33` servers that install k3s from their own cloud-init | DONE | P1 | M | strongest | 010, 015, 017, 025 | M1 |
| HETZ-035 | [035-Z-hetzner-kubeadm-bootstrap](035-Z-hetzner-kubeadm-bootstrap/spec.md) | `kubeadm join` over SSH from `cluster-up`, `admin.conf` kubeconfig, idempotent re-run | SUPERSEDED | P1 | M | strongest | 030, 040, 020 | M1 |
| HETZ-037 | [037-Z-hetzner-cilium-cni](037-Z-hetzner-cilium-cni/spec.md) | Cilium from the control plane's cloud-init; `cluster-up` ends when every node is Ready | SUPERSEDED | P1 | M | standard | 030, 035 | M1 |
| HETZ-040 | [040-D-hetzner-cluster-scripts](040-D-hetzner-cluster-scripts/spec.md) | Cluster scripts: `hcloud` helpers, SSH kubeconfig, node-Ready wait, `cluster_exists`, `node-ssh`, label-based leak sweep | DONE | P1 | M | standard | 017, 030 | M1 |
| HETZ-045 | [045-D-argo-scripts-hetzner-branches](045-D-argo-scripts-hetzner-branches/spec.md) | `argo-up` Hetzner branch: `hcloud` Secret, CCM helm install, taint wait, root Application, LB/DNS waits | DONE | P1 | M | strongest | 016, 040, 050 | M1 |
| HETZ-047 | [047-D-argo-down-teardown-ordering](047-D-argo-down-teardown-ordering/spec.md) | `argo-down` teardown ordering: the load balancer confirmed gone, and the CSI driver kept alive through the cascade | DONE | P1 | S | standard | 045, 020 | M1 |
| HETZ-050 | [050-D-gitops-hetzner-target-baseline](050-D-gitops-hetzner-target-baseline/spec.md) | `target: hetzner` tree: CSI Application, storage class, render check, golden diffs | DONE | P1 | M | standard | 016, CIVO-050 | M1 |
| HETZ-060 | [060-D-hetzner-ingress-envoy-lb](060-D-hetzner-ingress-envoy-lb/spec.md) | hcloud LB11 via Envoy Service annotations, private-IP targets, dynamic address | DONE | P1 | M | standard | 045, 050 | M1 |
| HETZ-070 | [070-D-tls-and-dns-on-hetzner](070-D-tls-and-dns-on-hetzner/spec.md) | Wildcard DNS-01 TLS, ExternalDNS with a dynamic LB address, TLS Secret persistence | DONE | P1 | M | standard | 060, 085, CIVO-075, CIVO-110 | M1 |
| HETZ-080 | [080-D-ca-ceremony-and-rolesanywhere-hetzner](080-D-ca-ceremony-and-rolesanywhere-hetzner/spec.md) | CA ceremony and `bootstrap/rolesanywhere` for the Hetzner project, before its first `bootstrap-up` | DONE | P0 | S | strongest | 018, CIVO-080, CIVO-082 | M1 |
| HETZ-085 | [085-D-workload-identity-on-hetzner](085-D-workload-identity-on-hetzner/spec.md) | CA issuer Secret, per-consumer Certificates, credential-helper sidecars for ESO and ExternalDNS | DONE | P0 | M | strongest | 045, 050, 080, CIVO-085, CIVO-090, CIVO-100 | M1 |
| HETZ-115 | [115-P-cnpg-cluster-on-hetzner](115-P-cnpg-cluster-on-hetzner/spec.md) | CNPG Cluster on `hcloud-volumes`, data disposable | READY | P1 | S | standard | 050, 085, CIVO-115 | M1 |
| HETZ-120 | [120-P-cnpg-on-hetzner-persistence](120-P-cnpg-on-hetzner-persistence/spec.md) | CNPG persistence through the barman-cloud plugin | DRAFT | P1 | M | standard | 115, CIVO-120, CIVO-180 | M1 |
| HETZ-130 | [130-P-e2e-tests-hetzner](130-P-e2e-tests-hetzner/spec.md) | E2E suite on Hetzner via ServiceAccount token | READY | P1 | S | standard | 045, 060, CIVO-130 | M1 |
| HETZ-140 | [140-P-ci-workflow-hetzner](140-P-ci-workflow-hetzner/spec.md) | `lab.yml` third provider value, `hcloud` CLI, token mask, label sweep in cleanup | READY | P1 | M | standard | 015, 045, CIVO-140, 047 | M1 |
| HETZ-150 | [150-P-teardown-recreate-validation](150-P-teardown-recreate-validation/spec.md) | Full lifecycle validation on Hetzner with the Hetzner resource classification | READY | P1 | M | strongest | 070, 120, 130, 047 | M1 |
| HETZ-160 | [160-P-observability-on-hetzner](160-P-observability-on-hetzner/spec.md) | Observability on Hetzner: control-plane scrapes on, x86 images, 10 GiB volume floor | READY | P1 | M | standard | 045, 050, 085, CIVO-160 | M1 |
| HETZ-165 | [165-Z-kubeadm-join-credential](165-Z-kubeadm-join-credential/spec.md) | `argo-up` creates the long-lived bootstrap token, CA hash and rendered join cloud-init in `kube-system/hcloud-autoscaler` | SUPERSEDED | P1 | S | standard | 037, 045 | M1 |
| HETZ-170 | [170-P-hetzner-cluster-autoscaler](170-P-hetzner-cluster-autoscaler/spec.md) | Cluster autoscaler `cloudProvider: hetzner`, 0–2 `cx33` workers that boot the same worker cloud-init | READY | P1 | M | strongest | 030, 045 | M1 |
| HETZ-175 | [175-P-sku-fallback-and-right-size](175-P-sku-fallback-and-right-size/spec.md) | Stock-aware SKU fallback (CX → CPX) and right-sizing on measured data | READY | P2 | S | standard | 160, CIVO-175 | M2 |
| HETZ-177 | [177-P-hetzner-arm-node-types](177-P-hetzner-arm-node-types/spec.md) | ARM node types (CAX) in the Hetzner catalogue, verified end to end | BLOCKED | P1 | M | standard | 040, 045, 182 | M2 |
| HETZ-182 | [182-P-multi-arch-images](182-P-multi-arch-images/spec.md) | Repo-built images published for `linux/arm64` as well as `linux/amd64` | DRAFT | P0 | S | fast | CIVO-180 | M2 |
| HETZ-185 | [185-Z-kubeadm-operations-runbook](185-Z-kubeadm-operations-runbook/spec.md) | CKA practice runbook: kubeadm upgrade 1.36 → 1.37, stacked etcd snapshot/restore, certificate checks | SUPERSEDED | P2 | M | standard | 037, 040 | M1 |
| HETZ-190 | [190-P-proxy-protocol-client-ip](190-P-proxy-protocol-client-ip/spec.md) | Proxy protocol on the hcloud LB and client IP at Envoy | READY | P3 | S | fast | 060, CIVO-190 | M2 |

The headers in each `spec.md` are the source of truth. Keep this table in sync.
