---
id: "HETZ-045"
title: "argo-up and argo-down Hetzner branches: hcloud Secret, CCM helm install, taint wait, LB and DNS waits"
status: "READY"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "L"
recommended_model_tier: "strongest"
model_rationale: "A new bootstrap-ordering step (CCM before Argo CD) with a deadlock if done wrong, plus teardown ordering where a leaked LB or volume keeps billing"
effort_estimate: "One to two sessions (6–10 h) plus two real up/down cycles"
estimate_confidence: "medium"
depends_on: ["HETZ-016", "HETZ-040", "HETZ-050"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-11"
completed: ""
---

# HETZ-045 — Argo scripts on Hetzner

## 1. Outcome and rationale

`PROVIDER=hetzner make argo-up` installs the Hetzner cloud controller
manager (CCM), waits until every node is initialised, installs Argo CD and
the root Application with `target=hetzner`, and waits for health.
`argo-down` removes the LB while the CCM still runs, then cascades. The
CCM step is new: on a self-managed k3s cluster every node carries
`node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` until the CCM
sets its `providerID`, and k3s's bundled CoreDNS does not tolerate that
taint. Without DNS, Argo CD cannot reach its repo-server or GitHub, so
Argo CD cannot be the CCM installer. `argo-up` installs the CCM the same
way it installs Argo CD: one helm release outside Argo's ownership.

## 2. Scope and non-goals

In scope: the hetzner seams in `scripts/argo-up.sh`, `scripts/argo-down.sh`,
`scripts/lib/provider.sh`, and the root-application relay in
`gitops/bootstrap/`. Not in scope: the CA Secret content (HETZ-085 adds
consumers; `ensure_ca_secret` itself is generalised by HETZ-016), TLS
Secret import (HETZ-070), the dump/restore Jobs (HETZ-120), the CSI
Application (HETZ-050).

## 3. Current state / evidence

- `argo-up.sh:80-135` `civo_resolve_inputs`: a 10-name SSM batch at the `get-parameters` cap. `:177-193` `civo_wait_for_lb_ip` compares the Service IP with the reserved IP. `:195-216` `civo_wait_for_dns`. `:217` `ensure_ca_secret`. `:336-382` `install_argocd` drops spot affinity when `PROVIDER != civo`. `:403-424` `civo_install_root_application` passes `reservedIp` and `firewallId`.
- `argo-down.sh:45-48` calls `civo_backup` and `civo_export_tls_secret`; `:149` skips the EBS prune; `:167-173` filters `TERMINATING_KINDS`; `:310-322` waits for `cnpg-system` PVCs.
- After HETZ-016 these branches read `[ "$PROVIDER" != aws ]` and the functions carry no `civo_` prefix; the SSM TLS path is `/${project}/persistent/${PROVIDER}/tls/platform-public`.
- k3s `manifests/coredns.yaml` tolerates only `CriticalAddonsOnly` and `node-role.kubernetes.io/control-plane` (verified 2026-09-11). The CCM chart `hcloud/hcloud-cloud-controller-manager` tolerates the uninitialized taint and, with `networking.enabled`, runs `hostNetwork: true` with `dnsPolicy: Default` (chart `deployment.yaml`).
- HETZ-030 starts k3s with `--disable-cloud-controller --kubelet-arg cloud-provider=external --disable servicelb,traefik,local-storage --flannel-iface <private nic>` and pod CIDR `10.42.0.0/16`.

## 4. Design and contracts

- Inputs. `hetzner_resolve_inputs()` reads two SSM batches. Batch 1: `bootstrap/route53/{fqdn,zone_id}`, `persistent/argocd/admin_password_bcrypt`, `persistent-hetzner/network/network_id`, `cluster-hetzner/k8s/control_plane_ip`. Batch 2: `bootstrap/rolesanywhere/{trust_anchor_arn,profile_arn}`, `bootstrap/rolesanywhere/role_arn/{eso,external-dns,cert-manager,pgbackup}`. Two calls keep each under the 10-name cap and leave room. The TLS parameter is read by the generalised import function, not here. Then `configure_kubeconfig`.
- `ensure_hcloud_ccm()` runs before `ensure_ca_secret` and before the fast path, so re-runs repair it. It creates or updates `kube-system/hcloud` with keys `token=$HCLOUD_TOKEN` and `network=<network_id>` through `kubectl create secret generic --dry-run=client -o yaml | kubectl apply -f -` (pipe, no temp file, never echoed). It runs `helm repo add hcloud https://charts.hetzner.cloud` once and `helm upgrade --install hccm hcloud/hcloud-cloud-controller-manager -n kube-system --version <pinned> --set networking.enabled=true --set networking.clusterCIDR=10.42.0.0/16 --set env.HCLOUD_NETWORK_ROUTES_ENABLED.value=\"false\" --set env.HCLOUD_LOAD_BALANCERS_LOCATION.value=$HCLOUD_LOCATION --set env.HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP.value=\"true\" --set env.HCLOUD_LOAD_BALANCERS_DISABLE_IPV6.value=\"true\" --wait`. Routes stay off because flannel runs vxlan. Then `wait_for_nodes_initialized()`: poll until no node has the taint and every node has `spec.providerID` starting with `hcloud://`, bounded by `HETZNER_ARGO_UP_CCM_WATCH_SECONDS` (default 180). Then confirm `coredns` in `kube-system` is Available.
- `install_argocd()` on hetzner: same as civo (no spot affinity). No toleration is needed, because the taint is gone.
- Root install: `--set target=hetzner`, project, repo, revision, `postgres.storageSize`, `envoyGateway.fqdn`, `envoyGateway.location=$HCLOUD_LOCATION`, `externalDns.txtOwnerId=$PROJECT_NAME`, the four role ARNs, trust anchor, profile, `tls.issuer`, `tls.acmeEmail`, `tls.hostedZoneId`. No `reservedIp`, no `firewallId`. `gitops/bootstrap/values.yaml` and `root-application.yaml` relay `envoyGateway.location`.
- `wait_for_lb_ip()` (generalised): succeed when `status.loadBalancer.ingress[0].ip` is non-empty. On civo it additionally equals the reserved IP; on hetzner any IP passes. `wait_for_dns()` compares `dig +short argo.$FQDN` with that discovered IP; bounded, non-fatal, as on civo. `WATCH_SECONDS` keeps the civo shortening until root health is proven on hetzner (HETZ-115 adds the first CNPG health signal).
- `argo-down.sh` on hetzner: existence proof with `cluster_exists`; dump gate from HETZ-016/120; TLS export; disarm automated sync; delete the `platform-gateway` Gateway and the Envoy Service first and wait until `hcloud load-balancer list -l project=$PROJECT_NAME` is empty — this must happen while the CCM runs, and the CCM is not in the cascade, so ordering is guaranteed; then the Route 53 wait (unchanged, AWS credentials present); then the cascade; then the PVC wait (`cnpg-system` and `observability`). `argo-down` never uninstalls the CCM release; `cluster-down` destroys the servers under it. `TERMINATING_KINDS` filtering already covers kinds absent on hetzner.

## 5. Files/components affected

`scripts/argo-up.sh`, `scripts/argo-down.sh`, `scripts/lib/provider.sh`,
`gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`,
`gitops/values.yaml` (`envoyGateway.location`). Pin the CCM chart version
in `scripts/lib/versions.sh` or the script header, next to the Argo CD
chart version.

## 6. Implementation steps

1. Add `hetzner_resolve_inputs`, `ensure_hcloud_ccm`, `wait_for_nodes_initialized`. Run `argo-up` up to the Argo CD install on the HETZ-040 cluster. Confirm the taint clears and CoreDNS becomes Available.
2. Add the root install and the generalised waits. Run `PROVIDER=hetzner make argo-up` with the HETZ-050 baseline. Every child Application reaches `Synced/Healthy`.
3. Run `argo-up` again: fast path, Secret unchanged, CCM release unchanged (`helm history hccm` shows one revision).
4. Add the `argo-down` branch. Run it. Confirm the LB disappears before the cascade and the PVC wait ends.
5. Record redacted `set -x` traces for aws and civo fast paths before and after.

## 7. Dependencies and blockers

HETZ-016 (generalised branches and SSM path), HETZ-040 (kubeconfig,
existence proof, token), HETZ-050 (`target: hetzner` renders the CSI
Application and baseline).

## 8. Acceptance criteria

- On a fresh cluster `argo-up` reaches Argo CD install only after all nodes have `providerID` and no uninitialized taint; CoreDNS is Available before Argo CD starts.
- `argo-up` is idempotent; the second run hits the fast path.
- `root` reaches `Synced` and every child Application reaches `Synced/Healthy` on the HETZ-050 baseline.
- `argo-down` deletes the hcloud LB before the cascade; `hcloud load-balancer list` is empty; no PVC remains; `helm status hccm -n kube-system` still reports deployed after `argo-down` (until `cluster-down`).
- The scripts print no token, no bcrypt hash, no SSH key.

## 9. Validation

Offline: `shellcheck` against the baseline, `bash -n`, `make gitops-check`.
Real cloud: two Hetzner up/down cycles (about 0.30 EUR including LB
hours). AWS: fast-path run and one full `argo-down`/`argo-up`. Civo: one
full cycle, because the shared functions change.

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
- The `hcloud` Secret holds a read-write project token in-cluster (ADR 0030 amendment). Any Secret reader in `kube-system` owns the Hetzner project. HETZ-085's ESO ClusterRole caveat (CIVO-205) applies here too.
- LB status could switch to `hostname` if `load-balancer.hetzner.cloud/hostname` were ever set (HETZ-190); the wait reads `.ip` only.
- The Envoy Service may be recreated by Argo during the `argo-down` LB wait if automated sync is not disarmed first; keep the disarm step before the delete.
- Argo CD's own Helm chart version and the CCM chart version are two untracked pins now; list both in the fast-path log line.

## 13. Definition of done

- [ ] Evidence for hetzner, aws and civo recorded
- [ ] CCM ordering proven on a fresh cluster
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
