---
id: "HETZ-045"
title: "argo-up Hetzner branch: hcloud Secret, CCM helm install, taint wait, root Application, LB/DNS waits"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "A new bootstrap-ordering step (CCM before Argo CD) with a deadlock if done wrong; a wrong wait gate blocks every child Application, not just one"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["HETZ-016", "HETZ-037", "HETZ-050"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-19"
completed: ""
---

# HETZ-045 — argo-up on Hetzner

## 1. Outcome and rationale

`PROVIDER=hetzner make argo-up` installs the Hetzner cloud controller
manager (CCM), waits until every node is initialised and CoreDNS is
Available, installs Argo CD and the root Application with
`target=hetzner`, and waits for the LB and DNS. On the kubeadm cluster
HETZ-035 builds and HETZ-037 hands over Ready with Cilium already
running, every node still carries
`node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` until the CCM
sets its `providerID`, and kubeadm's own CoreDNS Deployment does not
tolerate that taint. Without DNS, Argo CD cannot reach its repo-server or
GitHub, so Argo CD cannot be the CCM's installer; `argo-up` installs the
CCM the same way it installs Argo CD itself: one helm release outside
Argo's ownership. Teardown for this target belongs to HETZ-047, not this
spec.

## 2. Scope and non-goals

In scope: the hetzner seams in `scripts/argo-up.sh`,
`scripts/lib/provider.sh`, and the root-application relay in
`gitops/bootstrap/`. Not in scope: `argo-down` on hetzner. HETZ-047 (not
yet written) owns that design whole — the LB-before-cascade ordering, the
PVC wait, and the acceptance criterion that used to live here move there
entirely, and this spec no longer touches `scripts/argo-down.sh` at all.
Also not in scope: the CA Secret content (HETZ-085 adds consumers;
`ensure_ca_secret` itself is generalised by HETZ-016), TLS Secret import
(HETZ-070), the dump/restore Jobs (HETZ-120), the CSI Application
(HETZ-050), and `ensure_autoscaler_secret()` (HETZ-165, not yet written,
which runs immediately after `wait_for_nodes_initialized` in the same
script).

## 3. Current state / evidence

- `argo-up.sh:80-135` `civo_resolve_inputs`: a 10-name SSM batch at the `get-parameters` cap. `:177-193` `civo_wait_for_lb_ip` compares the Service IP with the reserved IP. `:195-216` `civo_wait_for_dns`. `:217` `ensure_ca_secret`. `:336-382` `install_argocd` drops spot affinity when `PROVIDER != civo`. `:403-424` `civo_install_root_application` passes `reservedIp` and `firewallId`.
- After HETZ-016 these branches read `[ "$PROVIDER" != aws ]` and the functions carry no `civo_` prefix; the SSM TLS path is `/${project}/persistent/${PROVIDER}/tls/platform-public`.
- kubeadm's own CoreDNS Deployment tolerates `CriticalAddonsOnly` and the control-plane taint only, not `uninitialized`; Cilium's DaemonSet (HETZ-037) tolerates every taint; the CCM chart `hcloud/hcloud-cloud-controller-manager` tolerates `uninitialized`/`not-ready` and, with `networking.enabled`, runs `hostNetwork: true` with `dnsPolicy: Default` (chart `deployment.yaml`), so CoreDNS turns `Running` the moment the CCM clears the taint — this ordering carries no chicken-and-egg deadlock on this bootstrap path. https://kubernetes.io/blog/2025/02/14/cloud-controller-manager-chicken-egg-problem/
- HETZ-035 initialises the control plane with `cloud-provider: external` and pod CIDR `10.244.0.0/16`; HETZ-037 installs Cilium in VXLAN mode right after. By the time `argo-up` starts, every node is `Ready` and still carries `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule`.

## 4. Design and contracts

- Inputs. `hetzner_resolve_inputs()` reads two SSM batches. Batch 1: `bootstrap/route53/{fqdn,zone_id}`, `persistent/argocd/admin_password_bcrypt`, `persistent-hetzner/network/network_id`, `cluster-hetzner/k8s/control_plane_ip`, `cluster-hetzner/k8s/control_plane_private_ip`, `cluster-hetzner/k8s/worker_ips`. Batch 2: `bootstrap/rolesanywhere/{trust_anchor_arn,profile_arn}`, `bootstrap/rolesanywhere/role_arn/{eso,external-dns,cert-manager,pgbackup}`. Batch 1 grows from five names to seven, still under the 10-name `get-parameters` cap. Neither addition is read by any function this spec adds — `control_plane_private_ip` and `worker_ips` exist for HETZ-165's `ensure_autoscaler_secret()`, which runs right after `wait_for_nodes_initialized()` below, not for anything this spec's own code consumes. The TLS parameter is read by the generalised import function, not here. Then `configure_kubeconfig`.
- `ensure_hcloud_ccm()` runs before `ensure_ca_secret` and before the fast path, so re-runs repair it. `argo-up` fails fast when `cluster_exists` (HETZ-040, reached transitively through HETZ-037 → HETZ-035 → HETZ-040) is false — there is nothing to install the CCM into. It creates or updates `kube-system/hcloud` with keys `token=$HCLOUD_TOKEN` and `network=<network_id>` through `kubectl create secret generic --dry-run=client -o yaml | kubectl apply -f -` (pipe, no temp file, never echoed). It runs `helm repo add hcloud https://charts.hetzner.cloud` once and `helm upgrade --install hccm hcloud/hcloud-cloud-controller-manager -n kube-system --version "$HCCM_CHART_VERSION" --set networking.enabled=true --set networking.clusterCIDR=10.244.0.0/16 --set env.HCLOUD_NETWORK_ROUTES_ENABLED.value="false" --set env.HCLOUD_LOAD_BALANCERS_LOCATION.value=$HCLOUD_LOCATION --set env.HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP.value="true" --set env.HCLOUD_LOAD_BALANCERS_DISABLE_IPV6.value="true" --wait`. Routes stay off because Cilium runs its own VXLAN datapath, not the CCM's route controller. https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/docs/guides/private-network-setup.md
- `wait_for_nodes_initialized()`: poll until no node has the `uninitialized` taint and every node has `spec.providerID` starting with `hcloud://`, bounded by `HETZNER_ARGO_UP_CCM_WATCH_SECONDS` (default 180). Then confirm `coredns` in `kube-system` is Available. HETZ-165's `ensure_autoscaler_secret()` (not yet written) runs immediately after this call, before the fast path returns, and is the consumer of the `worker_ips`/`control_plane_private_ip` batch-1 reads above.
- `install_argocd()` on hetzner: same as civo (no spot affinity). No toleration is needed, because the taint is gone.
- Root install: `--set target=hetzner`, project, repo, revision, `postgres.storageSize`, `envoyGateway.fqdn`, `envoyGateway.location=$HCLOUD_LOCATION`, `externalDns.txtOwnerId=$PROJECT_NAME`, the four role ARNs, trust anchor, profile, `tls.issuer`, `tls.acmeEmail`, `tls.hostedZoneId`. No `reservedIp`, no `firewallId`. `gitops/bootstrap/values.yaml` and `root-application.yaml` relay `envoyGateway.location`.
- `wait_for_lb_ip()` (generalised): succeed when `status.loadBalancer.ingress[0].ip` is non-empty. On civo it additionally equals the reserved IP; on hetzner any IP passes. `wait_for_dns()` compares `dig +short argo.$FQDN` with that discovered IP; bounded, non-fatal, as on civo. `WATCH_SECONDS` keeps the civo shortening until root health is proven on hetzner (HETZ-115 adds the first CNPG health signal).

## 5. Files/components affected

`scripts/argo-up.sh`, `scripts/lib/provider.sh`,
`gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`,
`gitops/values.yaml` (`envoyGateway.location`). Pin the CCM chart version
in `scripts/lib/versions.sh`, next to the Argo CD and Cilium chart
versions.

## 6. Implementation steps

1. Add `hetzner_resolve_inputs`, `ensure_hcloud_ccm`, `wait_for_nodes_initialized`. Run `argo-up` up to the Argo CD install on the HETZ-037 cluster. Confirm the taint clears and CoreDNS becomes Available — this is the re-check of the spike answer.
2. Add the root install and the generalised waits. Run `PROVIDER=hetzner make argo-up` with the HETZ-050 baseline. Every child Application reaches `Synced/Healthy`.
3. Run `argo-up` again: fast path, Secret unchanged, CCM release unchanged (`helm history hccm` shows one revision).
4. Record redacted `set -x` traces for aws and civo fast paths before and after.

## 7. Dependencies and blockers

HETZ-016 (generalised branches and SSM path). HETZ-037 supplies the
Ready-but-tainted, Cilium-networked cluster and the kubeconfig contract
this spec's `configure_kubeconfig` call reuses unchanged; HETZ-040's
`cluster_exists` and `hcloud_token`, which `ensure_hcloud_ccm()` calls,
arrive transitively through HETZ-037 → HETZ-035 → HETZ-040 rather than as
a direct dependency of this spec. HETZ-050 (`target: hetzner` renders the
CSI Application and baseline).

## 8. Acceptance criteria

- On a fresh cluster `argo-up` reaches Argo CD install only after all nodes have `providerID` and no uninitialized taint; CoreDNS is Available before Argo CD starts.
- `argo-up` is idempotent; the second run hits the fast path.
- `root` reaches `Synced` and every child Application reaches `Synced/Healthy` on the HETZ-050 baseline.
- The scripts print no token, no bcrypt hash, no SSH key.

## 9. Validation

Offline: `shellcheck` against the baseline, `bash -n`, `make gitops-check`.
Real cloud: two Hetzner `argo-up` runs, fresh then fast path (about 0.10
EUR including LB hours). AWS: fast-path run and one full
`argo-down`/`argo-up`. Civo: one full cycle, because the shared functions
change.

## 10. AWS regression protection

The aws and civo paths keep their behaviour. Gate: recorded AWS `argo-up`
fast path and one AWS `argo-down`/`argo-up`, plus one Civo
`argo-down`/`argo-up`, both diffed as redacted `set -x` traces against
the pre-change traces. `wait_for_lb_ip` on civo still requires the
reserved IP. `make gitops-check` golden diff for aws stays empty.

## 11. Rollout and rollback/recovery

Revert the scripts. The CCM release can be removed with `helm uninstall
hccm -n kube-system`; nodes re-taint only on kubelet restart. Data risk:
none beyond the dump gate, which fails closed.

## 12. Risks and unresolved questions

- If the CCM cannot reach `api.hetzner.cloud` (token wrong, IPv4 egress missing), the taint never clears and `argo-up` times out at the CCM gate with a clear message, not at Argo CD health. Test the wrong-token case once.
- The `hcloud` Secret holds a read-write project token in-cluster (ADR 0030 amendment). Any Secret reader in `kube-system` owns the Hetzner project. Deleting the Hetzner API token in the console breaks the running cluster — the CCM, the CSI driver and the autoscaler all read it — so rotation is re-encrypt then `argo-up`, never delete-first (ADR 0030 amendment). HETZ-085's ESO ClusterRole caveat (CIVO-205) applies here too.
- LB status could switch to `hostname` if `load-balancer.hetzner.cloud/hostname` were ever set (HETZ-190); the wait reads `.ip` only.
- Argo CD's own Helm chart version, the CCM chart version, and now Cilium's chart version (HETZ-037) are three untracked helm pins; list all three in the fast-path log line, and keep all three in `scripts/lib/versions.sh`.
- Until HETZ-047 lands, a teardown can leave an hcloud LB behind; HETZ-040's label-based sweep on `cluster-down` deletes it and reports it as a leak rather than a clean shutdown.

## 13. Definition of done

- [ ] Evidence for hetzner, aws and civo recorded
- [ ] CCM ordering proven on the HETZ-037 cluster
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — rewritten for kubeadm: CoreDNS evidence from kubeadm
  manifests; `argo-down` moved to HETZ-047; depends on HETZ-037.
