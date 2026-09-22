---
id: "HETZ-045"
title: "argo-up Hetzner branch: hcloud Secret, CCM helm install, taint wait, root Application, LB/DNS waits"
status: "IN_REVIEW"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "strongest"
model_rationale: "A new bootstrap-ordering step (CCM before Argo CD) with a deadlock if done wrong; a wrong wait gate blocks every child Application, not just one"
effort_estimate: "One session (4–6 h)"
estimate_confidence: "medium"
depends_on: ["HETZ-016", "HETZ-040", "HETZ-050"]
blocked_by: []
supersedes: []
created: "2026-09-11"
updated: "2026-09-22"
completed: ""
---

# HETZ-045 — argo-up on Hetzner

## 1. Outcome and rationale

`PROVIDER=hetzner make argo-up` installs the Hetzner cloud controller
manager (CCM), waits until every node is initialised and CoreDNS is
Available, installs Argo CD and the root Application with
`target=hetzner`, and waits for the LB and DNS. On the k3s cluster
HETZ-030 boots and HETZ-040 hands over Ready with flannel already
running, every node still carries
`node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` until the CCM
sets its `providerID`, and k3s's bundled CoreDNS does not
tolerate that taint. Without DNS, Argo CD cannot reach its repo-server or
GitHub, so Argo CD cannot be the CCM's installer; `argo-up` installs the
CCM the same way it installs Argo CD itself: one helm release outside
Argo's ownership. Teardown for this target belongs to HETZ-047, not this
spec.

## 2. Scope and non-goals

In scope: the hetzner seams in `scripts/argo-up.sh`,
`scripts/lib/provider.sh`, and the root-application relay in
`gitops/bootstrap/`. Not in scope: `argo-down` on hetzner. HETZ-047 owns that design whole — the LB-before-cascade ordering, the
PVC wait, and the acceptance criterion that used to live here move there
entirely, and this spec no longer touches `scripts/argo-down.sh` at all.
Also not in scope: the CA Secret content (HETZ-085 adds consumers;
`ensure_ca_secret` itself is generalised by HETZ-016), TLS Secret import
(HETZ-070), the dump/restore Jobs (HETZ-120), the CSI Application
(HETZ-050), and the autoscaler's own Secrets (HETZ-170,
which run immediately after `wait_for_nodes_initialized` in the same
script).

## 3. Current state / evidence

- `argo-up.sh:80-135` `civo_resolve_inputs`: a 10-name SSM batch at the `get-parameters` cap. `:177-193` `civo_wait_for_lb_ip` compares the Service IP with the reserved IP. `:195-216` `civo_wait_for_dns`. `:217` `ensure_ca_secret`. `:336-382` `install_argocd` drops spot affinity when `PROVIDER != civo`. `:403-424` `civo_install_root_application` passes `reservedIp` and `firewallId`.
- After HETZ-016 these branches read `[ "$PROVIDER" != aws ]` and the functions carry no `civo_` prefix; the SSM TLS path is `/${project}/persistent/${PROVIDER}/tls/platform-public`.
- k3s's bundled CoreDNS tolerates `CriticalAddonsOnly` and the control-plane taint only, not `uninitialized`; flannel is part of the k3s process and needs no scheduling at all; the CCM chart `hcloud/hcloud-cloud-controller-manager` tolerates `uninitialized`/`not-ready` and, with `networking.enabled`, runs `hostNetwork: true` with `dnsPolicy: Default` (chart `deployment.yaml`), so CoreDNS turns `Running` the moment the CCM clears the taint — this ordering carries no chicken-and-egg deadlock on this bootstrap path. https://kubernetes.io/blog/2025/02/14/cloud-controller-manager-chicken-egg-problem/
- HETZ-030's cloud-init starts every node with `--kubelet-arg=cloud-provider=external` and k3s's default pod CIDR `10.42.0.0/16`, with flannel on the private NIC; HETZ-040 waits for every node Ready. By the time `argo-up` starts, every node is `Ready` and still carries `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule`.

## 4. Design and contracts

- Inputs. `hetzner_resolve_inputs()` reads two SSM batches. Batch 1: `bootstrap/route53/{fqdn,zone_id}`, `persistent/argocd/admin_password_bcrypt`, `persistent-hetzner/network/network_id`, `cluster-hetzner/k8s/control_plane_ip`, `cluster-hetzner/k8s/control_plane_private_ip`, `cluster-hetzner/k8s/worker_ips`, `cluster-hetzner/firewall/firewall_id`, `persistent-hetzner/ssh-key/ssh_key_id`. Batch 2: `bootstrap/rolesanywhere/{trust_anchor_arn,profile_arn}`, `bootstrap/rolesanywhere/role_arn/{eso,external-dns,cert-manager,pgbackup}`. Batch 1 grows from five names to nine, still under the 10-name `get-parameters` cap; `control_plane_private_ip`, `worker_ips`, `firewall_id` and `ssh_key_id` are the four additions, the last two feeding HETZ-170's autoscaler env. The TLS parameter is read by the generalised import function, not here. Then `configure_kubeconfig`.
- `ensure_hcloud_ccm()` runs before `ensure_ca_secret` and before the fast path, so re-runs repair it. `argo-up` fails fast when `cluster_exists` (HETZ-040) is false — there is nothing to install the CCM into. It creates or updates `kube-system/hcloud` with keys `token=$HCLOUD_TOKEN` and `network=<network_id>` through `kubectl create secret generic --dry-run=client -o yaml | kubectl apply -f -` (pipe, no temp file, never echoed). It runs `helm repo add hcloud https://charts.hetzner.cloud` once and `helm upgrade --install hccm hcloud/hcloud-cloud-controller-manager -n kube-system --version "$HCCM_CHART_VERSION" --set networking.enabled=true --set networking.clusterCIDR=10.42.0.0/16 --set env.HCLOUD_NETWORK_ROUTES_ENABLED.value="false" --set env.HCLOUD_LOAD_BALANCERS_LOCATION.value=$HCLOUD_LOCATION --set env.HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP.value="true" --set env.HCLOUD_LOAD_BALANCERS_DISABLE_IPV6.value="true" --wait`. Routes stay off because flannel runs its own VXLAN datapath, not the CCM's route controller. https://github.com/hetznercloud/hcloud-cloud-controller-manager/blob/main/docs/guides/private-network-setup.md
- `wait_for_nodes_initialized()`: poll until no node has the `uninitialized` taint and every node has `spec.providerID` starting with `hcloud://`, bounded by `HETZNER_ARGO_UP_CCM_WATCH_SECONDS` (default 180). Then confirm `coredns` in `kube-system` is Available. HETZ-170's autoscaler Secrets are created immediately after this call, before the fast path returns, and are the consumer of the `worker_ips`/`control_plane_private_ip` batch-1 reads above.
- `install_argocd()` on hetzner: same as civo (no spot affinity). No toleration is needed, because the taint is gone.
- Root install: `--set target=hetzner`, project, repo, revision, `postgres.storageSize`, `envoyGateway.fqdn`, `envoyGateway.location=$HCLOUD_LOCATION`, `externalDns.txtOwnerId=$PROJECT_NAME`, the four role ARNs, trust anchor, profile, `tls.issuer`, `tls.acmeEmail`, `tls.hostedZoneId`, `autoscaler.firewallId=$FIREWALL_ID`, `autoscaler.sshKeyId=$SSH_KEY_ID`. No `reservedIp`. `gitops/bootstrap/values.yaml` and `root-application.yaml` relay `envoyGateway.location`, `autoscaler.firewallId` and `autoscaler.sshKeyId`.
- `wait_for_lb_ip()` (generalised): succeed when `status.loadBalancer.ingress[0].ip` is non-empty. On civo it additionally equals the reserved IP; on hetzner any IP passes. `wait_for_dns()` compares `dig +short argo.$FQDN` with that discovered IP; bounded, non-fatal, as on civo. `WATCH_SECONDS` keeps the civo shortening until root health is proven on hetzner (HETZ-115 adds the first CNPG health signal).

## 5. Files/components affected

`scripts/argo-up.sh`, `scripts/lib/provider.sh`,
`gitops/bootstrap/values.yaml`, `gitops/bootstrap/templates/root-application.yaml`,
`gitops/values.yaml` (`envoyGateway.location`, `autoscaler.firewallId`,
`autoscaler.sshKeyId`). Pin the CCM chart version
in `scripts/lib/versions.sh`, next to the Argo CD chart version.

## 6. Implementation steps

1. Add `hetzner_resolve_inputs`, `ensure_hcloud_ccm`, `wait_for_nodes_initialized`. Run `argo-up` up to the Argo CD install on the HETZ-040 cluster. Confirm the taint clears and CoreDNS becomes Available — this is the re-check of the spike answer.
2. Add the root install and the generalised waits. Run `PROVIDER=hetzner make argo-up` with the HETZ-050 baseline. Every child Application reaches `Synced/Healthy`.
3. Run `argo-up` again: fast path, Secret unchanged, CCM release unchanged (`helm history hccm` shows one revision).
4. Record redacted `set -x` traces for aws and civo fast paths before and after.

## 7. Dependencies and blockers

HETZ-016 (generalised branches and SSM path). HETZ-040 supplies the
Ready-but-tainted, flannel-networked cluster, `cluster_exists`,
`hcloud_token` and the `configure_kubeconfig` this spec reuses unchanged,
and is therefore a direct dependency. HETZ-050 (`target: hetzner` renders the
CSI Application and baseline).

## 8. Acceptance criteria

- On a fresh cluster `argo-up` reaches Argo CD install only after all nodes have `providerID` and no uninitialized taint; CoreDNS is Available before Argo CD starts.
- `argo-up` is idempotent; the second run hits the fast path.
- `root` reaches `Synced` and every child Application reaches `Synced/Healthy` on the HETZ-050 baseline.
- A second `argo-up` takes the fast path and `helm history hccm -n kube-system` shows one revision.
- With a wrong Hetzner token in `kube-system/hcloud`, `wait_for_nodes_initialized` times out within `HETZNER_ARGO_UP_CCM_WATCH_SECONDS` and prints which nodes still carry the taint (tested once, then the token is corrected and `argo-up` re-run).
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
- Argo CD's own Helm chart version and the CCM chart version are two untracked helm pins; list both in the fast-path log line, and keep both in `scripts/lib/versions.sh`.
- Until HETZ-047 lands, a teardown can leave an hcloud LB behind; HETZ-040's label-based sweep on `cluster-down` deletes it and reports it as a leak rather than a clean shutdown.

## 13. Definition of done

- [ ] Evidence for hetzner, aws and civo recorded
- [ ] CCM ordering proven on the HETZ-040 cluster
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-11 — created as DRAFT.
- 2026-09-11 — reviewed and approved by the user; promoted to READY.
- 2026-09-19 — rewritten for kubeadm: CoreDNS evidence from kubeadm
  manifests; `argo-down` moved to HETZ-047; depends on HETZ-037.
- 2026-09-20 — review fix: §3 credits the control-plane cloud-init
  (HETZ-030) with the init and the Cilium install, HETZ-035 with the
  worker joins and HETZ-037 with the Ready wait.
- 2026-09-20 — k3s (HETZ-017, ADR 0037). The CCM ordering and its reason are
  unchanged: k3s's bundled CoreDNS tolerates the `uninitialized` taint no
  better than kubeadm's did. What changes is the upstream: the Ready cluster
  now arrives from HETZ-040 rather than HETZ-037, so `depends_on` names 040
  directly; `clusterCIDR` is k3s's `10.42.0.0/16`; routes stay off for
  flannel's VXLAN rather than Cilium's; the Cilium chart pin is gone; and the
  autoscaler Secrets that follow `wait_for_nodes_initialized` belong to
  HETZ-170 now that HETZ-165 is retired.
- 2026-09-22 — implemented offline; status `IN_REVIEW`, folder renamed to
  `045-A-argo-scripts-hetzner-branches`. **The live cycle has not run**, so §13
  stays open: this entry records the code, not its acceptance.
  - **§3's central claim is false.** It asserts that after HETZ-016 the
    non-aws branches read `[ "$PROVIDER" != aws ]` and the functions carry no
    `civo_` prefix. Neither happened. The guards are named-provider by
    deliberate choice — `argo-up.sh:194-198` and `:322-329` both carry a
    comment explaining that `local` must not inherit the AWS call — and
    `civo_resolve_inputs`, `civo_wait_for_lb_ip`, `civo_wait_for_dns` and
    `civo_install_root_application` all still carry the prefix. This spec was
    therefore written against a generalised surface that does not exist. The
    implementation follows the shape actually in the tree: `hetzner_*`
    siblings plus a named arm in each `case`.
  - **Every §3 and §4 line citation was stale**, by 50 to 85 lines. HETZ-016
    and four later merges moved them.
  - **Four dispatch points, not the two §4 implies.** `PROVIDER=hetzner` hit a
    `*)` arm and exited 1 at the input resolver, the fast-path DNS wait, the
    root Application installer and the final DNS wait.
    `tests/scripts/argo-up-dispatch-test.sh` now pins the invariant, and run
    against the pre-merge script it reports exactly those four.
  - **No `wait_for_lb_ip` and no DNS wait, deliberately.** §4 asks for a
    generalised `wait_for_lb_ip`, but
    `gitops/templates/platform/shared/envoy-gateway/gateway.yaml:17` gates
    `EnvoyProxy` and `Gateway` on `aws|civo|local`, so this target renders a
    `GatewayClass` and nothing else: no Service to carry a load balancer
    address and no record to resolve. A wait against an object that does not
    render passes vacuously, which is the defect HETZ-050 had just removed
    from `REQUIRED_OBJECTS_HETZNER`. Both switches get an arm that says so and
    returns 0. §2 already assigns the load balancer to HETZ-060, which is
    where the wait belongs, together with the hetzner arms of
    `platform.envoyServiceSpec` and `platform.envoyListeners`.
  - **`scripts/lib/versions.sh` does not exist**, so §5's instruction to pin
    the CCM chart "next to the Argo CD chart version" resolves to
    `argo-up.sh:18`, inline, beside `ARGOCD_CHART_VERSION`. One constant does
    not earn a new file.
  - **The chart's defaults already satisfy two of §4's `--set` values**:
    `env.HCLOUD_TOKEN` reads Secret `hcloud` key `token` and
    `networking.network` reads key `network`. Only `networking.enabled`,
    `clusterCIDR` and `HCLOUD_NETWORK_ROUTES_ENABLED` are set. `clusterCIDR`
    is `10.42.0.0/16` because the control plane passes no `--cluster-cidr`
    (`control-plane.yaml.tftpl:37-51`) and so takes k3s's own default, not the
    chart's Flannel-oriented `10.244.0.0/16` — the chart default would have
    been silently wrong.
  - **A latent failure at the last step of every hetzner run.**
    `backup_publish_server_name` ran for every target but `local`, and calls
    `put-parameter --value "$BACKUP_SERVER_NAME"`. This target mints no server
    name, and SSM rejects an empty value, so a bring-up that had otherwise
    fully succeeded would have exited non-zero at its final statement. The
    guard is now keyed on a non-empty `BACKUP_BUCKET`, which is the condition
    that actually decides whether there is anything to record or prune.
    Behavior for aws, civo and local is unchanged. (An earlier reading of this
    defect blamed an empty `BACKUP_SSM_LAYER`; that was wrong —
    `provider.sh:36` gives hetzner the layer `persistent`, and the empty one at
    `:27` belongs to `local`.)
  - **Nine SSM names plus the network id is exactly ten**, the
    `get-parameters` cap, so `hetzner_resolve_inputs` makes one call and reuses
    the aws-side `ssm_output` lookup rather than copying civo's batching loop.
    A comment records the ceiling: an eleventh name needs that loop, and
    HETZ-060 and HETZ-170 will each add one.
  - **`firewall_id`, `ssh_key_id` and `envoyGateway.location` are not read or
    passed**, though §4 lists them. Each would cost a default in
    `gitops/bootstrap/values.yaml`, an unconditional `| quote`'d entry in
    `root-application.yaml` and a key in `gitops/values.yaml`, to carry a value
    nothing consumes until HETZ-060 and HETZ-170.
  - **Backups are off on this target** (`postgres.backup.enabled=false`). There
    is no `persistent-hetzner/backups` unit; HETZ-115 and HETZ-120 own it.
  - Verified offline: `bash -n` clean; `shellcheck` findings byte-identical to
    `origin/main` (no new warnings); `make -n argo-up` and `make -n status`
    identical to `origin/main` for aws, civo and local; `make gitops-check` and
    `make specs-check` green; the new dispatch test passes and was proved to
    fail both with a hetzner arm removed and against the pre-merge script.
  - Not touched, recorded here so it is not mistaken for an oversight:
    `scripts/lib/argo-watch.sh` gates its per-node and load-balancer progress
    reporting on `civo` at six places (`:70,175,195,219,228,261`), so hetzner
    gets degraded watch output. Cosmetic, and a separate diff. `argo-down.sh`
    is HETZ-047's.
