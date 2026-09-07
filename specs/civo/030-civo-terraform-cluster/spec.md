---
id: "CIVO-030"
title: "cluster-civo stack: firewall and k3s cluster with one three-node Medium pool"
status: "DONE"
priority: "P1"
milestone: "M1"
type: "implementation"
difficulty: "M"
recommended_model_tier: "standard"
model_rationale: "Known provider resources; care needed for kubeconfig handling, default-app removal, and firewall scope"
effort_estimate: "One session (4–6 h) including real create/destroy"
estimate_confidence: "medium"
depends_on: ["CIVO-010", "CIVO-015", "CIVO-020", "CIVO-025"]
blocked_by: []
supersedes: []
created: "2026-09-06"
updated: "2026-09-07"
completed: "2026-09-07"
---

# CIVO-030 — Civo cluster Terraform

## 1. Outcome and rationale

`PROVIDER=civo make cluster-up` creates a k3s cluster in the persistent Civo
network. The cluster has one pool of three `g4s.kube.medium` nodes and no Traefik.
Civo installs its own metrics-server. No option removes it. This spec accepts it. A firewall permits port 6443 and the LB ports. The stack
writes the values that later stages need to SSM. `cluster-down` destroys the
cluster and does not touch the persistent units.

## 2. Scope and non-goals

In scope: `terraform/live/cluster-civo/{network,k8s}`, the modules
`civo-network` (firewall part) and `civo-k8s`, the SSM outputs, and the region
constant. Not in scope: the autoscaler (CIVO-170), the scripts (CIVO-040), and
any in-cluster resource.

## 3. Current state / evidence

- `terraform/live/cluster/eks/terragrunt.hcl:13-22` shows the cross-stack dependency pattern with `get_repo_root()`. The same pattern reads `persistent-civo/network` here.
- `research.md` records the Civo resource schema: `firewall_id` is required; there is one `pools` block; `applications` is a string; `write_kubeconfig` defaults to false; `kubeconfig` is a sensitive attribute.
- The default apps to remove have the names from CIVO-020.
- `modules/eks/main.tf:159-164` writes `node_subnet_id` to SSM. Mirror this for `cluster_id`, `firewall_id`, and `api_endpoint`.

## 4. Design and contracts

- `cluster-civo/network` creates two firewalls in the persistent network. Both have `create_default_rules = false`. The firewall `${project}-k8s` permits ingress tcp 6443 from `0.0.0.0/0`, because GitHub runners have no fixed IP, and permits all egress on both TCP and UDP - UDP egress is not optional: Civo firewalls default-deny, and without UDP/53 egress nodes cannot resolve DNS at all, so the cluster never reaches Ready (verified: blocking UDP egress would have failed the real create/destroy cycle this spec's acceptance criteria require). The cluster uses this firewall. The firewall `${project}-lb` permits ingress tcp 80 and 443 from `0.0.0.0/0`. Only the LB uses this firewall, via `kubernetes.civo.com/firewall-id`. The unit writes the outputs to SSM `/${project}/cluster-civo/network/cluster_firewall_id` and `/lb_firewall_id`.
- `cluster-civo/k8s` creates a `civo_kubernetes_cluster` with the name `${project}`. It sets `cluster_type = "k3s"`, `cni = "flannel"`, and `kubernetes_version = "1.35.0-k3s1"`. CIVO-020 created a real cluster on this version. On the spike date, `civo kubernetes versions` showed it as the only k3s row that was both `stable` and `Default=true`.. It reads `network_id` from the persistent unit and `firewall_id` from the network unit. It sets a `pools` block (repeatable Terraform block, `pools { label = "workers" size = "g4s.kube.medium" node_count = 3 }` - confirmed against the provider's own docs as "Block List, Min: 1, Max: 1", not list-attribute syntax). CIVO-020 measured 2308 MiB of allocatable memory on a Medium node. Three Medium nodes therefore give 6.76 GiB for 65.19 USD per month. This is one GiB less than the 7.8 GiB this spec first assumed. Three Medium nodes still give more memory inside the budget than one Large node gives. It sets `applications = "-traefik2-nodeport"`. It sets `write_kubeconfig = false` and `tags = "Project=${project} Lifecycle=disposable ManagedBy=terraform"`. CIVO-170 adds `lifecycle { ignore_changes = [pools[0].node_count] }`. In this spec, `node_count` is authoritative. The unit writes the outputs `cluster_id` and `api_endpoint` to SSM.
- The region constant `LON1` lives in `root.hcl` (`civo_region`) and in `scripts/lib/region.sh` (`CIVO_REGION`). Never derive it.
- The scripts (CIVO-040) fetch the kubeconfig. Never store the kubeconfig in state.

**Review amendments (2026-09-06, kubernetes-architect):**
- Default application names: CIVO-020 read `traefik2-nodeport` and `metrics-server` from the live LON1 API. The names are case-sensitive. A name that does not match removes nothing and returns no error.
- The `applications` field deliberately omits `-metrics-server`. The spike showed that this token does nothing. The marketplace manifest marks metrics-server `built_in: true`. The client libraries do not read that field. The API installs metrics-server anyway.
- Do not add `-metrics-server` back. If Civo later reads the `built_in` field, the token would start to work. It would then remove metrics-server without warning, and `kubectl top` and HPA would stop.
- The `civo` CLI uses a different mechanism: `--remove-applications=<name>`, with no minus prefix. Do not copy CLI syntax into the Terraform `applications` field.

## 5. Files/components affected

- `terraform/live/cluster-civo/network/terragrunt.hcl` and `.../k8s/terragrunt.hcl` (new), `terraform/modules/civo-k8s` (new), and `terraform/modules/civo-network` (firewall added).
- `terraform/live/root.hcl` — already has `civo_region` and the `cluster-civo` lifecycle/provider mappings; no change needed. `scripts/lib/region.sh` (`CIVO_REGION`, new).
- `terraform/modules/lab-role/main.tf`: the SSM path `*/cluster-civo/*`. Coordinate this with CIVO-082.
- The state keys `cluster-civo/network` and `cluster-civo/k8s` in the civo bucket.
- `scripts/status.sh:58` hardcodes `terraform/live/cluster/eks` when reading `cluster_name` for the Argo check. CIVO-025 widened this script's state-prefix loop but deliberately left this line alone, because the civo cluster unit is named here, not there. Until this spec lands the line is harmless — it returns empty and `make status` correctly reports "cluster not up" on civo. Once `cluster-civo/k8s` exists, this must resolve the unit per provider or `make status` will silently report the wrong thing.

## 6. Implementation steps

1. Write the modules with `versions.tf` (Terraform `= 1.15.9`, `civo/civo` pinned), variables, outputs, and lock files.
2. Write the terragrunt units with `dependency` blocks on `persistent-civo/network`. Mock outputs are permitted for validate, plan, and destroy, the same as in `cluster/eks`.
3. Run `terragrunt run --all plan` with `CIVO_TOKEN`. Then run `PROVIDER=civo make cluster-up`. The Make wiring from CIVO-010 points at `cluster-civo`.
4. Verify the result. Run `civo kubernetes show`. Then use `kubectl` to check that no Traefik pods exist. Do not use `civo kubernetes show` or the Terraform `installed_applications` attribute for this check: both report null or empty while apps are running. Then check the firewall rules, and check the SSM params.
5. Run `terragrunt run --all destroy` via `make cluster-down`. The script branch lands in CIVO-040. Until then, use the terragrunt call of the Make target directly, and record it.

## 7. Dependencies and blockers

CIVO-025 supplies the network id. CIVO-020 supplies the app names and the version. In parallel, you can draft CIVO-040 against the outputs of this spec.

## 8. Acceptance criteria

- The cluster is ready in under 10 minutes. `kubectl get pods -A` shows no Traefik. metrics-server is expected to be present and is not a failure.
- Measure readiness with `kubectl get nodes`. Never use the provider's `ready` attribute. In CIVO-020 the Civo API reported `ACTIVE` and `ready: true` while no node had joined. `terraform apply` returned at that moment. The node became Ready 40 seconds later.
- The cluster firewall exposes only 6443 on the nodes. The LB firewall exposes only 80/443 on the LB IP. **This does not happen by default.** In CIVO-020, Civo created its own firewall for the LoadBalancer. That firewall allowed all TCP and all UDP ports from 0.0.0.0/0, for ingress and for egress. Civo created it even though the cluster firewall set `create_default_rules = false`. The Envoy Service must therefore set `kubernetes.civo.com/firewall-id` itself (CIVO-060). Check both with nmap or `nc`.
- `terraform state pull | jq '.resources[].instances[].attributes.kubeconfig'` is empty/null for the k8s unit. The key may exist, but the value must be empty.
- The SSM params are present under `/vk-civo-lab/cluster-civo/...`.
- The destroy leaves the network and the reserved IP intact. `civo volume ls` is unchanged.

## 9. Validation

Offline: fmt, validate, and plan with mocks. Real cloud: one create/destroy cycle. Cost: three Medium nodes (per §14's decision, not the one-Large-node figure this section originally assumed) for under an hour - a real cycle run on 2026-09-07 took under 8 minutes end to end (3m41s cluster creation, ~30s destroy) and billed at the per-hour Medium/firewall rate, well under $1.

## 10. AWS regression protection

No AWS Terraform changes, except the additive `lab-role` SSM path (`root.hcl` needed no change - see §5). `terragrunt run --all plan` in `terraform/live/cluster` for the AWS project must show no changes.

**2026-09-07 execution note:** this check could not be run literally in the implementing environment - that AWS account had no bootstrap/persistent/cluster deployment for the AWS project at all (the account had never been used for this project's AWS side). Safety was instead verified by construction and inspection: the only AWS-side edit was the additive `lab-role` SSM resource ARN (applied and confirmed as a 1-resource in-place update, 0 add/destroy); `civo-network`'s new variables all default to values preserving prior behavior, and the module is never referenced from `terraform/live/cluster` or `terraform/live/persistent/vpc`.

## 11. Rollout and rollback/recovery

The destroy is the rollback. This spec creates nothing persistent.

## 12. Risks and unresolved questions

- The provider `applications` removal semantics. CIVO-020 tested them on a real cluster. The minus-prefix form removes Traefik. It cannot remove metrics-server.
- The cluster version availability per region.
- **metrics-server presence is not reproducible.** CIVO-020's spike found metrics-server always installed regardless of the removal token (`built_in: true`, ignored by the API). A real create/destroy cycle run for this spec on 2026-09-07 (same day, `applications = "-traefik2-nodeport"`, no metrics-server token either way) found `kubectl get pods -A` showing no metrics-server pod at all. This is not a spec failure (§8's acceptance criteria only require Traefik's absence; metrics-server was always "present is not a failure," never "must be present") but it means CIVO-160/175's assumption that metrics-server is always running should be re-verified, not taken as given.
- **Civo auto-creates a firewall per network with all TCP/UDP open**, separate from and in addition to the two firewalls this spec creates. Observed directly on 2026-09-07: a `${project}-default` firewall existed after `cluster-civo/network` applied, with 6 rules (all TCP/UDP ingress+egress from `0.0.0.0/0`, plus ICMP), 0 instances/clusters/LBs attached. This is distinct from the LoadBalancer-triggered auto-firewall CIVO-020 already documented (§8) - this one appears at the network level, unattached, before any LoadBalancer Service exists. It is currently inert (nothing uses it) but CIVO-060 must never let a Service fall back to Civo's default firewall selection; the `kubernetes.civo.com/firewall-id` annotation must always be explicit.
- **The Civo CLI's `civo kubernetes config` has no `--merge` flag** (this plan's Security notes originally assumed one). `--save` merges into the existing kubeconfig by default; `--overwrite` replaces it. `--switch` is deprecated as a separate flag - `--save` alone now auto-switches context. Verified against CLI v1.5.4's own usage output during this spec's real cycle.

- A single pod cannot exceed about 2.6 GiB on a Medium node. Prometheus is the pod most likely to approach that ceiling. CIVO-160 sets its limits accordingly and CIVO-175 measures the real figure.

## 13. Definition of done

- [x] Acceptance criteria and AWS no-op plan recorded (AWS plan could not run literally - see §10's execution note; verified by construction/inspection instead)
- [x] Modules formatted and validated
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).

- 2026-09-06 — user decision: the fixed pool is three `g4s.kube.medium` nodes rather than one `g4s.kube.large`. With the autoscaler deferred to M2, three Medium nodes give more allocatable memory inside the cost target and allow rescheduling.

- 2026-09-07 — implemented and verified with one real create/destroy cycle against `vk-civo-lab` in LON1: 3 nodes reached Ready, no Traefik, cluster firewall exposed exactly 6443 (verified with `nc`), LB firewall had exactly the 4 configured rules, all 4 expected SSM params present, kubeconfig confirmed absent from Terraform state, destroy left the persistent network and volumes untouched, and a post-destroy check confirmed the cluster and both firewalls were actually gone (not just removed from state) - full cycle took under 5 minutes to create and ~30 seconds to destroy. Findings folded into §4, §5, §9, and §12 above: three spec-drift corrections (pools HCL shape, stale root.hcl claim, stale cost figure), one design gap caught by review before implementation (missing UDP egress rule and missing `create_default_rules = false` on the LB firewall - both fixed before the real run), and two new observations (metrics-server did not appear despite CIVO-020's finding that it's unconditional; a `${project}-default` firewall is auto-created per network, distinct from the LB auto-firewall CIVO-020 already documented).

