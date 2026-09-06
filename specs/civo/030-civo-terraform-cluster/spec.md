---
id: "CIVO-030"
title: "cluster-civo stack: firewall and k3s cluster with one Large pool"
status: "READY"
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
updated: "2026-09-06"
completed: null
---

# CIVO-030 — Civo cluster Terraform

## 1. Outcome and rationale

`PROVIDER=civo make cluster-up` creates a k3s cluster in the persistent Civo
network with one `g4s.kube.large` pool, no Traefik, no Civo metrics-server,
a firewall allowing 6443 and LB ports, and writes the values later stages
need to SSM. `cluster-down` destroys it without touching persistent units.

## 2. Scope and non-goals

In scope: `terraform/live/cluster-civo/{network,k8s}`, modules
`civo-network` (firewall part) and `civo-k8s`, SSM outputs, region
constant. Not in scope: autoscaler (CIVO-170), scripts (CIVO-040), any
in-cluster resource.

## 3. Current state / evidence

- `terraform/live/cluster/eks/terragrunt.hcl:13-22` shows the cross-stack dependency pattern with `get_repo_root()`; the same pattern reads `persistent-civo/network` here.
- Civo resource schema in `research.md`: `firewall_id` required; one `pools` block; `applications` string; `write_kubeconfig` default false; `kubeconfig` sensitive attribute.
- Default apps to remove: names from CIVO-020.
- `modules/eks/main.tf:159-164` writes `node_subnet_id` to SSM; mirror for `cluster_id`, `firewall_id`, `api_endpoint`.

## 4. Design and contracts

- `cluster-civo/network`: `civo_firewall` `${project}-k8s` in the persistent network, `create_default_rules = false`; ingress tcp 6443 from `0.0.0.0/0` (GitHub runners have no fixed IP; accepted, documented), tcp 80 and 443 from `0.0.0.0/0` for the LB firewall reuse, egress all. Output `firewall_id` to SSM `/${project}/cluster-civo/network/firewall_id`.
- `cluster-civo/k8s`: `civo_kubernetes_cluster` name `${project}`, `cluster_type = "k3s"`, `cni = "flannel"`, `kubernetes_version` pinned to a version verified in the spike, `network_id` from persistent, `firewall_id` from network unit, `pools = [{ label = "workers", size = "g4s.kube.large", node_count = 1 }]`, `applications = "-<traefik-name>,-<metrics-server-name>"`, `write_kubeconfig = false`, `tags = "Project=${project} Lifecycle=disposable ManagedBy=terraform"`. `lifecycle { ignore_changes = [pools[0].node_count] }` is added by CIVO-170; here `node_count` is authoritative. Outputs `cluster_id`, `api_endpoint` to SSM.
- Region constant `LON1` in `root.hcl` (`civo_region`) and `scripts/lib/region.sh` (`CIVO_REGION`); never derived.
- Kubeconfig is fetched by scripts (CIVO-040), never stored in state.

## 5. Files/components affected

- `terraform/live/cluster-civo/network/terragrunt.hcl`, `.../k8s/terragrunt.hcl` (new), `terraform/modules/civo-k8s` (new), `terraform/modules/civo-network` (firewall added).
- `terraform/live/root.hcl` (`civo_region`), `scripts/lib/region.sh` (`CIVO_REGION`).
- `terraform/modules/lab-role/main.tf`: SSM `*/cluster-civo/*` (coordinate with CIVO-082).
- State keys `cluster-civo/network`, `cluster-civo/k8s` in the civo bucket.

## 6. Implementation steps

1. Write modules with `versions.tf` (Terraform `= 1.15.9`, `civo/civo` pinned), variables, outputs, lock files.
2. Write terragrunt units with `dependency` blocks on `persistent-civo/network` (mock outputs allowed for validate/plan/destroy, same as `cluster/eks`).
3. `terragrunt run --all plan` with `CIVO_TOKEN`; then `PROVIDER=civo make cluster-up` (Make wiring from CIVO-010 points at `cluster-civo`).
4. Verify: `civo kubernetes show`, no Traefik/metrics-server pods, firewall rules, SSM params.
5. `terragrunt run --all destroy` via `make cluster-down` (script branch lands in CIVO-040; until then, use the Make target's terragrunt call directly and record it).

## 7. Dependencies and blockers

CIVO-025 network id; CIVO-020 app names and version. Parallel: CIVO-040 can be drafted against this spec's outputs.

## 8. Acceptance criteria

- Cluster ready in under 10 minutes; `kubectl get pods -A` shows no Traefik and no metrics-server.
- Firewall attached; port 6443 reachable; ports other than 80/443/6443 closed from the Internet (nmap or `nc` check).
- `terraform state pull | grep -c kubeconfig` = 0 for the k8s unit.
- SSM params present under `/vk-civo-lab/cluster-civo/...`.
- Destroy leaves the network and reserved IP intact; `civo volume ls` unchanged.

## 9. Validation

Offline: fmt, validate, plan with mocks. Real cloud: one create/destroy cycle; cost: Large node for under an hour (~0.06 USD).

## 10. AWS regression protection

No AWS Terraform changed except `root.hcl` additive locals and `lab-role` SSM path; `terragrunt run --all plan` in `terraform/live/cluster` for the AWS project must show no changes.

## 11. Rollout and rollback/recovery

Destroy is the rollback. Nothing persistent is created here.

## 12. Risks and unresolved questions

- Provider `applications` removal semantics; verified in spike.
- Cluster version availability per region.

## 13. Definition of done

- [ ] Acceptance criteria and AWS no-op plan recorded
- [ ] Modules formatted and validated
- [ ] Index updated; status `DONE`

## 14. Execution evidence and status history

- 2026-09-06 — created as DRAFT.
- 2026-09-06 — approved for development by the user; promoted to READY (dependencies still gate the start).
