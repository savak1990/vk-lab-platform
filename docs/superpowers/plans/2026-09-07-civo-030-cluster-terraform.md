# CIVO-030 Civo Cluster Terraform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `PROVIDER=civo make cluster-up` creates a disposable k3s cluster (one pool of
three `g4s.kube.medium` nodes, no Traefik) inside the existing persistent Civo network,
protected by two default-deny firewalls, with `cluster-down` destroying it and leaving
the persistent network/reserved IP untouched.

**Architecture:** Two new disposable-lifecycle Terragrunt units,
`terraform/live/cluster-civo/{network,k8s}`. The `network` unit extends the existing
`civo-network` module (currently used only by `persistent-civo/network`) with an
optional firewall-creation mode, so the same module creates the persistent
`civo_network` in one place and, gated by a boolean, two disposable `civo_firewall`
resources in the other. The `k8s` unit is a new `civo-k8s` module wrapping
`civo_kubernetes_cluster`. Both units write their outputs to SSM, mirroring the
`terraform/modules/eks` pattern.

**Tech Stack:** Terraform 1.15.9, Terragrunt, `civo/civo` provider 1.3.2, `hashicorp/aws`
6.60.0 (for the SSM writes), AWS SSM Parameter Store.

**Spec:** `specs/civo/030-civo-terraform-cluster/spec.md`

## Global Constraints

- Region is a hardcoded constant, never derived: `civo_region = "LON1"` (`terraform/live/root.hcl:52`, unchanged).
- Kubeconfig MUST NEVER be written to Terraform state: `write_kubeconfig = false` on the cluster resource; acceptance criteria checks this via `terraform state pull`.
- No new AWS IAM policy grants beyond the one SSM path addition this plan makes explicit (spec §3: `eks:DescribeCluster`-equivalent isn't needed here — this is Civo, not AWS — the only AWS-side touch is SSM parameter writes).
- No Traefik running post-create (`applications = "-traefik2-nodeport"`); do **not** add `-metrics-server` — it is inert and silently doing nothing is safer than it becoming active without warning if Civo ever starts honoring the `built_in` field (spec §4 review amendment).
- Node readiness MUST be measured via `kubectl get nodes`, never the provider's `ready`/`status` attributes — CIVO-020 measured the API reporting `ready: true` with zero nodes joined.
- Every new resource this plan can tag gets `Project=<project> Scope=platform Lifecycle=disposable ManagedBy=terraform` (spec §4's own tag string omits `Scope=platform`; this plan adds it for consistency with the constitution's tagging convention even though Civo resources aren't contractually bound by the AWS-resource-specific tagging rule).
- `terragrunt run --all plan` against `terraform/live/cluster` (the **AWS** stack) must show zero changes after every task in this plan (spec §10, AWS regression protection).

---

## Security notes (answers "am I exposing my cluster")

Verified before writing any firewall HCL, because getting this wrong silently defeats the point of a firewall:

1. **Civo firewalls default-deny.** Civo's own firewall docs state explicitly: "the default for a new firewall is to deny everything, so you only need to open the ports/port ranges needed." With `create_default_rules = false` and a single `tcp/6443` ingress rule, everything else — kubelet's `10250`, the NodePort range, anything else a pod might expose — is blocked by default, not left open. This is not the same as Civo's separate, pre-existing **named "Default" firewall** (a distinct object, documented as having all ports open) — this plan never attaches that one.
2. **`public_ip_node_pool`'s default is undocumented by Civo.** The provider schema lists the field but states no default. This plan does not set it explicitly (matching spec §4, which is silent on it) and instead treats "does the node get a public IP" as a fact to observe from the real `terraform apply` in Task 8 — but it does **not change the exposure answer either way**, because the default-deny firewall in fact 1 applies to the node regardless of whether its IP is public or private-only-with-a-public-facing-attachment. The port surface is bounded by the firewall, not by whether the IP is publicly routable.
3. **The actual residual risk is the kubeconfig itself, not the open port.** Unlike EKS (where `argo-up.sh`'s kubeconfig bakes in a `--role-arn` exec plugin that mints short-lived STS tokens on every `kubectl` call — nothing long-lived ever touches disk), Civo's `civo kubernetes config` returns a **static client certificate with no rotation or revocation path short of destroying the cluster**. Whoever holds that file holds cluster-admin until `cluster-down`. This plan's own verification steps (Task 8) fetch that kubeconfig to a scratch path only, never commit it, and rely on the cluster being short-lived (disposable lifecycle, destroyed at the end of the session).
4. **Egress is wide open by design** (`0.0.0.0/0`, all ports, on the cluster firewall) — spec §4's explicit design, not a gap this plan fixes. Documented residual risk: ADR 0029/0030 already note `CIVO_TOKEN` transitively reaches the Roles-Anywhere CA key, so a compromised node has a wide blast radius regardless of this firewall's egress rule. Out of scope for CIVO-030 to narrow.
5. **The LB firewall (80/443) has no consumer yet.** CIVO-060 (Envoy Gateway's Service) is what actually binds a Service to it via `kubernetes.civo.com/firewall-id`. Until then, Civo has nothing listening as a LoadBalancer at all, so Task 8's verification of this firewall is rule-inspection only (`civo firewall show` / Terraform state), not a live network probe — there is no IP to point `nmap` at yet.

**Kubectl access, scoped for this plan only:** Building a real `make eks-kubeconfig` civo branch (`Makefile:173-176`'s stub) is CIVO-040's job — spec §2 explicitly excludes "the scripts (CIVO-040)" from this spec's scope, and the Makefile already reserves that exact target name (not a separate `civo-kubeconfig` target) for both providers, branching on `PROVIDER`. This plan's Task 8 verification instead uses the CLI directly, ad hoc, to a scratch path:

```bash
civo kubernetes config "$PROJECT_NAME" --region LON1 --save --merge --switch
```

(verified flags: `--save`/`-s` writes to `~/.kube/config`, `--merge` merges rather than overwriting, `--switch` sets the current context, `--region` selects LON1 — source: Civo CLI docs/`civo/cli`.) No Make target, no script file, added by this plan.

---

## File Structure

- **Modify** `terraform/modules/civo-network/{main.tf,variables.tf,outputs.tf}` — add an optional firewall-creation mode (two new booleans, two new `civo_firewall` resources, two new outputs), used by the new `cluster-civo/network` unit while leaving `persistent-civo/network`'s existing behavior byte-identical.
- **Create** `terraform/live/cluster-civo/network/terragrunt.hcl` — depends on `persistent-civo/network` for `network_id`.
- **Create** `terraform/modules/civo-k8s/{main.tf,variables.tf,outputs.tf,versions.tf}` — wraps `civo_kubernetes_cluster`.
- **Create** `terraform/live/cluster-civo/k8s/terragrunt.hcl` — depends on `persistent-civo/network` (network_id) and `cluster-civo/network` (cluster firewall id).
- **Modify** `terraform/modules/lab-role/main.tf` — add the missing `*/cluster-civo/*` SSM resource ARN.
- **Modify** `scripts/lib/region.sh` — add `CIVO_REGION`.
- **Modify** `scripts/status.sh` — resolve the disposable-cluster Terragrunt unit per `$PROVIDER` instead of hardcoding the AWS path.
- **Modify** `specs/civo/030-civo-terraform-cluster/spec.md` — correct three drifted statements found during planning (root.hcl claim, stale cost figure, `pools` HCL shape).

---

## Task 1: Extend `civo-network` module with an optional firewall mode

**Files:**
- Modify: `terraform/modules/civo-network/variables.tf`
- Modify: `terraform/modules/civo-network/main.tf`
- Modify: `terraform/modules/civo-network/outputs.tf`

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: `civo_firewall_id`, `lb_firewall_id` outputs (null unless `create_firewalls = true`) — consumed by Task 3 (`cluster-civo/k8s` reads `civo_firewall_id`).

- [ ] **Step 1: Add the new variables**

```hcl
# terraform/modules/civo-network/variables.tf
variable "project" {
  description = "PROJECT_NAME - used to build this project's SSM parameter path."
  type        = string
}

variable "create_network" {
  description = "Create the civo_network resource. False when this unit only adds firewalls to an existing network (see network_id)."
  type        = bool
  default     = true
}

variable "create_firewalls" {
  description = "Create the disposable cluster/LB firewalls. False for the persistent network unit."
  type        = bool
  default     = false
}

variable "network_id" {
  description = "An existing network's ID, required when create_network = false."
  type        = string
  default     = null
}
```

- [ ] **Step 2: Add the conditional network lookup and the two firewalls**

```hcl
# terraform/modules/civo-network/main.tf
# The Civo provider exposes no tags argument on the civo_network resource,
# so the constitution's Project/Scope/Lifecycle/ManagedBy tags cannot be
# carried on it.
resource "civo_network" "this" {
  count = var.create_network ? 1 : 0
  label = var.project
}

# civo_network.this is a Persistent-lifecycle resource and Civo network
# assignment is permanent (decisions.md) - a plan that proposed destroy+
# recreate here instead of an address change would be expensive to undo.
# Pre-empt that rather than reacting to it after the fact.
moved {
  from = civo_network.this
  to   = civo_network.this[0]
}

locals {
  network_id = var.create_network ? civo_network.this[0].id : var.network_id
}

resource "aws_ssm_parameter" "network_id" {
  count       = var.create_network ? 1 : 0
  name        = "/${var.project}/persistent-civo/network/id"
  type        = "String"
  value       = local.network_id
  description = "This project's Civo network ID."
}

moved {
  from = aws_ssm_parameter.network_id
  to   = aws_ssm_parameter.network_id[0]
}

# Default-deny (Civo: "the default for a new firewall is to deny everything").
# Only 6443 is opened because GitHub Actions runners have no fixed IP to
# allowlist instead. All other ports (kubelet 10250, NodePort range, ...)
# stay blocked by the firewall default, not by anything in this file.
resource "civo_firewall" "cluster" {
  count                 = var.create_firewalls ? 1 : 0
  name                  = "${var.project}-k8s"
  network_id            = local.network_id
  create_default_rules  = false

  ingress_rule {
    label      = "k3s-api"
    protocol   = "tcp"
    port_range = "6443"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  # Both TCP and UDP egress are required, not just TCP: firewalls default-deny,
  # and without UDP/53 egress nodes cannot resolve DNS at all (no registry
  # pulls, no cluster bootstrap) - the whole cluster fails to reach Ready.
  egress_rule {
    label      = "all-egress-tcp"
    protocol   = "tcp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  egress_rule {
    label      = "all-egress-udp"
    protocol   = "udp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }
}

# Bound to nothing yet - CIVO-060's Envoy Service annotates
# kubernetes.civo.com/firewall-id to attach its LoadBalancer here. Without
# that annotation, Civo would otherwise auto-create its own firewall for any
# LoadBalancer Service, open to all TCP/UDP from 0.0.0.0/0 - CIVO-020 observed
# this happen even with this cluster firewall's create_default_rules = false.
resource "civo_firewall" "lb" {
  count                = var.create_firewalls ? 1 : 0
  name                 = "${var.project}-lb"
  network_id           = local.network_id
  create_default_rules = false

  ingress_rule {
    label      = "http"
    protocol   = "tcp"
    port_range = "80"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  ingress_rule {
    label      = "https"
    protocol   = "tcp"
    port_range = "443"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  egress_rule {
    label      = "all-egress-tcp"
    protocol   = "tcp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }

  egress_rule {
    label      = "all-egress-udp"
    protocol   = "udp"
    port_range = "1-65535"
    cidr       = ["0.0.0.0/0"]
    action     = "allow"
  }
}

resource "aws_ssm_parameter" "cluster_firewall_id" {
  count       = var.create_firewalls ? 1 : 0
  name        = "/${var.project}/cluster-civo/network/cluster_firewall_id"
  type        = "String"
  value       = civo_firewall.cluster[0].id
  description = "This disposable run's Civo cluster firewall ID."
}

resource "aws_ssm_parameter" "lb_firewall_id" {
  count       = var.create_firewalls ? 1 : 0
  name        = "/${var.project}/cluster-civo/network/lb_firewall_id"
  type        = "String"
  value       = civo_firewall.lb[0].id
  description = "This disposable run's Civo LB firewall ID, for CIVO-060's Envoy Service annotation."
}
```

- [ ] **Step 3: Add the new outputs**

```hcl
# terraform/modules/civo-network/outputs.tf
output "network_id" {
  value = local.network_id
}

output "cluster_firewall_id" {
  value = var.create_firewalls ? civo_firewall.cluster[0].id : null
}

output "lb_firewall_id" {
  value = var.create_firewalls ? civo_firewall.lb[0].id : null
}
```

- [ ] **Step 4: Validate persistent unit is unchanged**

```bash
cd terraform/live/persistent-civo/network && terragrunt run --all --non-interactive -- validate
cd terraform/live/persistent-civo/network && terragrunt run --all --non-interactive -- plan
```

Expected: **zero changes** — a pass/fail gate. The `moved` blocks written in Step 2 make this deterministic; if plan proposes anything other than "No changes," stop and fix the `moved` blocks before proceeding (this is a Persistent-lifecycle resource — do not let a destroy+recreate through).

- [ ] **Step 5: Commit**

```bash
git add terraform/modules/civo-network/
git commit -m "civo-030: add optional firewall mode to civo-network module"
```

---

## Task 2: Create the `cluster-civo/network` Terragrunt unit

**Files:**
- Create: `terraform/live/cluster-civo/network/terragrunt.hcl`

**Interfaces:**
- Consumes: `terraform/modules/civo-network` (Task 1) — `create_network`, `create_firewalls`, `network_id`, `project` inputs.
- Produces: SSM params `/${project}/cluster-civo/network/{cluster_firewall_id,lb_firewall_id}` — consumed by Task 4.

- [ ] **Step 1: Write the unit**

```hcl
# terraform/live/cluster-civo/network/terragrunt.hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/civo-network"
}

dependency "persistent_network" {
  config_path = "${get_repo_root()}/terraform/live/persistent-civo/network"

  mock_outputs = {
    network_id = "00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  project          = local.project
  create_network   = false
  create_firewalls = true
  network_id       = dependency.persistent_network.outputs.network_id
}
```

- [ ] **Step 2: Validate with mocks**

```bash
cd terraform/live/cluster-civo/network && terragrunt run --all --non-interactive -- validate
cd terraform/live/cluster-civo/network && terragrunt run --all --non-interactive -- plan
```

Expected: plan succeeds using the mocked `network_id`, proposing to create 2 `civo_firewall` resources + 2 `aws_ssm_parameter` resources.

- [ ] **Step 3: Commit**

```bash
git add terraform/live/cluster-civo/network/
git commit -m "civo-030: add cluster-civo/network Terragrunt unit"
```

---

## Task 3: Create the `civo-k8s` module

**Files:**
- Create: `terraform/modules/civo-k8s/versions.tf`
- Create: `terraform/modules/civo-k8s/variables.tf`
- Create: `terraform/modules/civo-k8s/main.tf`
- Create: `terraform/modules/civo-k8s/outputs.tf`

**Interfaces:**
- Consumes: `network_id`, `firewall_id`, `project` inputs — supplied by Task 4's terragrunt unit from Task 1/2's outputs.
- Produces: outputs `cluster_id`, `api_endpoint`, `cluster_name` — `cluster_name` consumed by Task 7 (`scripts/status.sh`).

- [ ] **Step 1: Pin versions to match `civo-network`**

```hcl
# terraform/modules/civo-k8s/versions.tf
terraform {
  required_version = "= 1.15.9"
  required_providers {
    aws  = { source = "hashicorp/aws", version = "= 6.60.0" }
    civo = { source = "civo/civo", version = "= 1.3.2" }
  }
}
```

- [ ] **Step 2: Write variables**

```hcl
# terraform/modules/civo-k8s/variables.tf
variable "project" {
  description = "PROJECT_NAME - used as the cluster name and to build this project's SSM parameter path."
  type        = string
}

variable "network_id" {
  description = "The persistent Civo network's ID (from persistent-civo/network)."
  type        = string
}

variable "firewall_id" {
  description = "The disposable cluster firewall's ID (from cluster-civo/network)."
  type        = string
}
```

- [ ] **Step 3: Verify `tags` is a real argument on `civo_kubernetes_cluster` before writing it**

`civo_firewall` turned out to have no `tags` argument at all (Task 1 no longer sets it). `civo_kubernetes_cluster`'s `tags` field was flagged by research as unconfirmed. Check `https://raw.githubusercontent.com/civo/terraform-provider-civo/master/docs/resources/kubernetes_cluster.md` directly before running `terraform validate`. If it doesn't exist, drop the `tags` line below — there is no other tagging mechanism on this resource.

- [ ] **Step 4: Write the cluster resource**

```hcl
# terraform/modules/civo-k8s/main.tf
# CIVO-020 verified on a live LON1 cluster: 1.35.0-k3s1 was the only k3s
# version both stable and Default=true on the spike date. Pin it explicitly
# rather than relying on the provider's own default, since that default
# tracks Civo's own "Default" flag and would silently change under us.
resource "civo_kubernetes_cluster" "this" {
  name               = var.project
  cluster_type       = "k3s"
  cni                = "flannel"
  kubernetes_version = "1.35.0-k3s1"
  network_id         = var.network_id
  firewall_id        = var.firewall_id

  # Traefik removed; metrics-server's "-metrics-server" token is deliberately
  # omitted - CIVO-020 verified it is inert (metrics-server is built_in:
  # true, which the API does not let this field remove), and a future Civo
  # change that made the token start working would then remove
  # metrics-server without warning and break kubectl top/HPA.
  applications = "-traefik2-nodeport"

  write_kubeconfig = false
  tags             = "Project=${var.project} Scope=platform Lifecycle=disposable ManagedBy=terraform"

  pools {
    label      = "workers"
    size       = "g4s.kube.medium"
    node_count = 3
  }
}

resource "aws_ssm_parameter" "cluster_id" {
  name        = "/${var.project}/cluster-civo/k8s/cluster_id"
  type        = "String"
  value       = civo_kubernetes_cluster.this.id
  description = "This disposable run's Civo Kubernetes cluster ID."
}

resource "aws_ssm_parameter" "api_endpoint" {
  name        = "/${var.project}/cluster-civo/k8s/api_endpoint"
  type        = "String"
  value       = civo_kubernetes_cluster.this.api_endpoint
  description = "This disposable run's Civo Kubernetes API endpoint."
}
```

- [ ] **Step 5: Write outputs**

```hcl
# terraform/modules/civo-k8s/outputs.tf
output "cluster_id" {
  value = civo_kubernetes_cluster.this.id
}

output "api_endpoint" {
  value = civo_kubernetes_cluster.this.api_endpoint
}

output "cluster_name" {
  value = civo_kubernetes_cluster.this.name
}
```

- [ ] **Step 6: Commit**

```bash
git add terraform/modules/civo-k8s/
git commit -m "civo-030: add civo-k8s module"
```

---

## Task 4: Create the `cluster-civo/k8s` Terragrunt unit

**Files:**
- Create: `terraform/live/cluster-civo/k8s/terragrunt.hcl`

**Interfaces:**
- Consumes: Task 1/2's `cluster-civo/network` outputs (`cluster_firewall_id`), `persistent-civo/network`'s `network_id`, Task 3's `civo-k8s` module.
- Produces: nothing further consumed inside this plan (this is the leaf unit `make cluster-up` applies).

- [ ] **Step 1: Write the unit**

```hcl
# terraform/live/cluster-civo/k8s/terragrunt.hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/terraform/modules/civo-k8s"
}

dependency "persistent_network" {
  config_path = "${get_repo_root()}/terraform/live/persistent-civo/network"

  mock_outputs = {
    network_id = "00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

dependency "cluster_network" {
  config_path = "${get_repo_root()}/terraform/live/cluster-civo/network"

  mock_outputs = {
    cluster_firewall_id = "00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
}

locals {
  project = get_env("PROJECT_NAME", "vk-lab-platform")
}

inputs = {
  project     = local.project
  network_id  = dependency.persistent_network.outputs.network_id
  firewall_id = dependency.cluster_network.outputs.cluster_firewall_id
}
```

- [ ] **Step 2: Validate with mocks**

```bash
cd terraform/live/cluster-civo/k8s && terragrunt run --all --non-interactive -- validate
cd terraform/live/cluster-civo/k8s && terragrunt run --all --non-interactive -- plan
```

- [ ] **Step 3: Commit**

```bash
git add terraform/live/cluster-civo/k8s/
git commit -m "civo-030: add cluster-civo/k8s Terragrunt unit"
```

---

## Task 5: Grant `lab-role` the missing SSM path

**Files:**
- Modify: `terraform/modules/lab-role/main.tf:262-275`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks — this is a standalone IAM grant.

**Note:** this change is untestable by this plan's own real create/destroy cycle — a local `PROVIDER=civo make cluster-up` runs under the operator's own AWS credentials, not `lab-role`, so a missing grant here would never surface locally. It only bites in CI (CIVO-140, not yet implemented). Verify by inspection; the acceptance criterion is "the statement exists," not "a run failed without it and now passes."

- [ ] **Step 1: Add the resource ARN**

```hcl
# terraform/modules/lab-role/main.tf, statement "PlatformConfigSsmParameters"
resources = [
  "arn:aws:ssm:*:${local.account}:parameter/*/bootstrap/*",
  "arn:aws:ssm:*:${local.account}:parameter/*/persistent/*",
  "arn:aws:ssm:*:${local.account}:parameter/*/persistent-civo/*",
  "arn:aws:ssm:*:${local.account}:parameter/*/cluster/*",
  "arn:aws:ssm:*:${local.account}:parameter/*/cluster-civo/*",
  "arn:aws:ssm:*:${local.account}:parameter/account/*",
]
```

- [ ] **Step 2: Validate**

```bash
cd terraform/live/account/lab-role && terragrunt run --all --non-interactive -- validate
cd terraform/live/account/lab-role && terragrunt run --all --non-interactive -- plan
```

Expected: plan shows an in-place policy update only (one new resource ARN added to an existing statement).

- [ ] **Step 3: Commit**

```bash
git add terraform/modules/lab-role/main.tf
git commit -m "civo-030: grant lab-role the cluster-civo SSM path"
```

---

## Task 6: Add `CIVO_REGION` to the shared region library

**Files:**
- Modify: `scripts/lib/region.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `CIVO_REGION` shell variable — not consumed anywhere in this plan (`status.sh`'s Task 7 change branches on `$PROVIDER`, not this constant); added because spec §4 requires it declared here, for CIVO-040's scripts to consume later.

- [ ] **Step 1: Add the constant, matching the file's existing convention (not exported)**

```bash
# scripts/lib/region.sh
# The platform targets exactly one region. Deliberately not named AWS_REGION
# and deliberately not exported: an exported AWS_REGION would let the AWS CLI
# resolve a region ambiently and collide with the operator's own profile.

LAB_REGION="eu-west-1"

# Civo's region constant. Also declared in terraform/live/root.hcl
# (civo_region) - Terraform and shell each need their own copy since one
# isn't reachable from the other; never derive this value, keep both literal.
CIVO_REGION="LON1"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/lib/region.sh
git commit -m "civo-030: add CIVO_REGION to scripts/lib/region.sh"
```

---

## Task 7: Make `scripts/status.sh` resolve the cluster unit per provider

**Files:**
- Modify: `scripts/status.sh:58`

**Interfaces:**
- Consumes: `$PROVIDER` env var (already exported by `Makefile:31-40`), Task 3's `civo-k8s` module's `cluster_name` output.
- Produces: correct `CLUSTER_NAME` for the Argo-health check that follows this line — no other task depends on this.

- [ ] **Step 1: Branch the terragrunt working-dir by provider**

```bash
# scripts/status.sh, replacing line 58
if [ "${PROVIDER:-aws}" = "civo" ]; then
  CLUSTER_NAME="$(terragrunt --working-dir "$REPO_ROOT/terraform/live/cluster-civo/k8s" output -raw cluster_name 2>/dev/null || true)"
else
  CLUSTER_NAME="$(terragrunt --working-dir "$REPO_ROOT/terraform/live/cluster/eks" output -raw cluster_name 2>/dev/null || true)"
fi
```

- [ ] **Step 2: Verify manually (no cluster required for the empty-state path)**

```bash
PROVIDER=civo make status
```

Expected: reports "cluster not up" (or equivalent empty state) without error — proves the civo branch is reachable and doesn't crash when no `cluster-civo/k8s` state exists yet.

- [ ] **Step 3: Commit**

```bash
git add scripts/status.sh
git commit -m "civo-030: resolve status.sh's cluster unit per PROVIDER"
```

---

## Task 8: Real create/destroy cycle and full acceptance-criteria verification

**Files:** none (verification only).

**Interfaces:** consumes every prior task's output; produces nothing further.

- [ ] **Step 1: Real create**

```bash
PROVIDER=civo make cluster-up
```

`cluster-up` (Makefile:152-154) runs `./scripts/require-persistent.sh` first. That script was written for AWS and checks for the `eks-access-identity` IAM role and persistent Terraform state in S3 — verify it doesn't hard-fail under `PROVIDER=civo` before relying on this command; if it does, run `terragrunt run --all --non-interactive -- apply -auto-approve` directly in `terraform/live/cluster-civo` instead and note the gap for CIVO-040.

Expected: completes in well under 10 minutes (spec's own budget, revised from the stale "one Large node" text — see Task 9).

- [ ] **Step 2: Fetch kubeconfig to a scratch path (ad hoc — no script, per this plan's Security notes)**

```bash
civo kubernetes config "$PROJECT_NAME" --region LON1 --save --merge --switch
```

- [ ] **Step 3: Verify node readiness the correct way**

```bash
kubectl get nodes
```

Expected: 3 nodes, all `Ready` — gate on this, never on `civo kubernetes show`'s `ready`/`status` fields (CIVO-020's documented trap).

- [ ] **Step 4: Verify no Traefik, metrics-server present and not a failure**

```bash
kubectl get pods -A | grep -i traefik   # expect: no output
kubectl get pods -A | grep -i metrics-server   # expect: running pod, this is expected
```

- [ ] **Step 5: Verify the cluster firewall (live network probe — a real target exists: the node IPs)**

```bash
nc -zv -w3 <a-node-public-ip> 6443    # expect: succeeds
nc -zv -w3 <a-node-public-ip> 10250   # expect: times out / refused
```

- [ ] **Step 6: Verify the LB firewall (rule-inspection only — no live consumer until CIVO-060)**

```bash
civo firewall show "${PROJECT_NAME}-lb" --region LON1
```

Expected: exactly two ingress rules (80, 443), no live LoadBalancer bound to it yet.

- [ ] **Step 7: Verify SSM params**

```bash
aws ssm get-parameters-by-path --path "/${PROJECT_NAME}/cluster-civo" --recursive --query 'Parameters[].Name'
```

Expected: `network/cluster_firewall_id`, `network/lb_firewall_id`, `k8s/cluster_id`, `k8s/api_endpoint` all present.

- [ ] **Step 8: Verify no kubeconfig ever reached state**

```bash
cd terraform/live/cluster-civo/k8s && terragrunt state pull | jq '.resources[].instances[].attributes.kubeconfig'
```

Expected: `null` or the key is absent — never a populated string.

- [ ] **Step 9: Real destroy**

`make cluster-down` (Makefile:161-162) runs `scripts/cluster-down.sh`, which has no civo branch and expects an EKS cluster plus a prior `argo-down` cascade (Makefile:161's own comment) — do not run it under `PROVIDER=civo`. Use the direct terragrunt call the spec names instead:

```bash
cd terraform/live/cluster-civo && terragrunt run --all --non-interactive -- destroy -auto-approve
```

(terragrunt's own dependency graph orders `k8s` before `network` correctly via `run --all`.)

- [ ] **Step 10: Verify persistent resources untouched**

```bash
civo network ls --region LON1     # expect: the persistent network still present
civo volume ls --region LON1      # expect: unchanged (spec's own acceptance criterion)
```

- [ ] **Step 11: AWS regression check**

```bash
cd terraform/live/cluster && terragrunt run --all --non-interactive -- plan
```

Expected: no changes.

- [ ] **Step 12: Record the real cost and timing observed** in this plan's execution notes (spec §9 wants the real create/destroy cycle cost recorded; expect roughly 3 × Medium-node-hours plus a firewall, well under $1 for one cycle — replaces the stale "one Large node ~0.06 USD" figure, see Task 9).

- [ ] **Step 13: Commit any incidental fixes found during this run**, if the real `civo_kubernetes_cluster` schema disagrees with Task 3's HCL (e.g. `tags` type, `pools` block form) — re-run `terraform plan` after any fix and repeat from Step 1.

---

## Task 9: Correct spec drift found during planning

**Files:**
- Modify: `specs/civo/030-civo-terraform-cluster/spec.md`

Three statements in the spec's own text don't match the tree, matching the precedent this series already set with CIVO-025 ("Correct CIVO-025 spec text that the implementation contradicted").

**Interfaces:** none — documentation only.

- [ ] **Step 1: Fix §5's `root.hcl` claim**

Change: "`terraform/live/root.hcl` (`civo_region`)" listed under "Files/components affected" implies a change is needed there. It is not — `civo_region = "LON1"` already exists at `root.hcl:52`, and `cluster-civo` is already present in both `lifecycle_class` (`root.hcl:48`) and `civo_stack` (`root.hcl:58`). Replace with: "`terraform/live/root.hcl` — already has `civo_region` and the `cluster-civo` lifecycle/provider mappings; no change needed."

- [ ] **Step 2: Fix §9's stale cost figure**

Change "Cost: one Large node for under an hour (~0.06 USD)" (leftover from before the 3×Medium decision recorded in §14) to reflect three Medium nodes plus two firewalls for one create/destroy cycle — update with the real figure recorded in Task 8 Step 12 once known; until then, replace "one Large node" with "three Medium nodes (per §14's decision)".

- [ ] **Step 3: Fix §4's `pools` HCL shape**

Change `pools = [{ label = "workers", size = "g4s.kube.medium", node_count = 3 }]` (list-attribute syntax) to the confirmed repeatable-block form:
```hcl
pools {
  label      = "workers"
  size       = "g4s.kube.medium"
  node_count = 3
}
```

- [ ] **Step 4: Commit**

```bash
git add specs/civo/030-civo-terraform-cluster/spec.md
git commit -m "civo-030: correct spec text against verified provider schema and existing root.hcl state"
```

---

## Self-Review

**Spec coverage:** Requirement/design bullets in spec §4 → Tasks 1–4 (network+firewalls, k8s cluster). §5's affected-files list → Tasks 1–7 (every file named is touched or explicitly marked "no change needed" in Task 9). §6's five implementation steps → Tasks 1–4 (write modules/units), Task 8 (plan with mocks, real create, verify, destroy). §8's acceptance criteria → Task 8's steps 1–11 map one-to-one. §10 AWS regression → Task 8 Step 11. §12 risks (`applications` semantics, version availability) → addressed inline in Task 3's comments, not a separate task since they're already resolved facts from CIVO-020, not open risks requiring new code.

**Placeholder scan:** no TBD/TODO; every code block is complete HCL/bash, not prose describing intent.

**Type consistency:** `cluster_firewall_id` (Task 1 output) matches the exact name used in Task 2's `inputs` and Task 4's `dependency` block. `cluster_name` (Task 3 output) matches Task 7's `output -raw cluster_name`. `network_id` variable name is consistent across Task 1's module and Tasks 2/4's terragrunt units.
