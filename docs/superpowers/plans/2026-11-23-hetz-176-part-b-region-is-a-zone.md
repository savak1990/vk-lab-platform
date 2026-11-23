# HETZ-176 Part B — REGION Is a Network Zone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On Hetzner, `REGION` names the network zone (`eu-central`); the platform places every server in any location of that zone, falls back to the next location on a stock-out, and keys the state bucket, the backup bucket and the load balancer by the zone.

**Architecture:** `catalog.sh` gains the zone → locations map and derives zone-level answers from the existing per-location lists. `region.sh`/`root.hcl` name buckets after the zone. A new `hetzner_apply` in `provider.sh` runs the cluster apply once per location (exporting `HCLOUD_LOCATION`, never changing `REGION`) until one succeeds; `location` is in `ignore_changes`, so servers already created never move. The autoscaler and the load balancer read the zone.

**Tech Stack:** Bash, Terragrunt/Terraform (hcloud provider 1.69.0), Helm templates, Argo CD, GitHub Actions.

**Spec:** `specs/hetzner/176-A-zone-wide-placement/spec.md` (§4.1–§4.8, §5 Part B, §6 steps 5–12, §8, §11 PR 2). Part A is merged (`a020ba9`, PR #117).

## Global Constraints

- Work in the worktree `/Users/margo/Proj/Lab/vk-lab-platform-hetz176b`, branch `hetz-176-part-b` (from `a020ba9`). Never commit in `/Users/margo/Proj/Lab/vk-lab-platform`. Start every shell command with `cd /Users/margo/Proj/Lab/vk-lab-platform-hetz176b &&`. Run tests with `bash`.
- Hetzner only. Civo and AWS behavior MUST NOT change. The aws golden may change only in the bootstrap `root` Application's parameter list (`envoyGateway.location` → `envoyGateway.networkZone`).
- Hetzner `REGION` is a zone; the only accepted zone is `eu-central`. `catalog_zone_locations eu-central` = `fsn1 nbg1 hel1` (this order everywhere).
- `REGION=<location>` is refused with exactly: `REGION is a network zone on hetzner; '<location>' is a location in <zone> - use REGION=<zone>`.
- Bucket names: `<project>-eu-central-tf-state`, `<project>-eu-central-postgres-backups`.
- `REGION` names the state bucket, so a retry MUST NOT change it. The per-attempt location is `HCLOUD_LOCATION`.
- Fallback signals: the output text `resource_unavailable` or `unsupported location for server type`. Never the bare code `invalid_input`.
- Load balancer annotation: `load-balancer.hetzner.cloud/network-zone`, never together with `load-balancer.hetzner.cloud/location`.
- Autoscaler `nodeConfigs` keys: `workers-<location>` for every location of the zone (no `workers` key any more).
- Code comments: only where non-obvious, at most 3 lines, never naming a spec, ADR or ticket (repo `CLAUDE.md`).
- Commit trailer on every commit:
  ```
  Co-Authored-By: <the model that wrote the commit> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
  ```

---

## File map

| File | Task | Change |
|---|---|---|
| `scripts/lib/catalog.sh` | 1 | zone functions; hetzner region list is the zone |
| `scripts/lib/require-valid-node-config.sh` | 1 | location refusal message |
| `scripts/lib/region.sh` | 1 | `LAB_PROVIDER_REGION` = lowercased zone; drop `HCLOUD_LOCATION` |
| `Makefile` | 1, 4 | `REGION ?= eu-central`; cluster-up calls `hetzner_apply` |
| `.github/workflows/lab.yml` | 1, 6 | dropdown order; region comment |
| `tests/scripts/node-config-test.sh` | 1 | zone cases |
| `terraform/live/root.hcl` | 2 | bucket namespace from the zone |
| `terraform/live/persistent-hetzner/network/terragrunt.hcl` | 2 | `network_zone` input |
| `terraform/live/cluster-hetzner/k8s/terragrunt.hcl` | 2 | `location` from `HCLOUD_LOCATION` |
| `terraform/modules/hcloud-nodes/main.tf`, `variables.tf` | 2 | `location` in `ignore_changes` |
| `scripts/state-up.sh` | 3 | guard also checks legacy location buckets |
| `tests/scripts/state-up-guard-test.sh` | 3 | new |
| `scripts/lib/provider.sh` | 4 | `hetzner_apply` |
| `scripts/park.sh` | 4 | apply through `hetzner_apply` |
| `tests/scripts/hetzner-apply-test.sh` | 4 | new |
| `tests/scripts/park-test.sh` | 4 | `REGION=eu-central` |
| `scripts/argo-up.sh` | 1, 5 | autoscaler list and keys from the zone (1); `envoyGateway.networkZone` (5) |
| `tests/scripts/autoscaler-config-test.sh` | 1 | zone cases |
| `gitops/templates/_helpers.tpl`, both values files, `root-application.yaml`, aws golden | 5 | `networkZone` |
| `scripts/gitops-render-check.sh`, `.github/workflows/lifecycle-test.yml` | 5 | render sets and asserts |
| `docs/adr/0047-hetzner-region-is-a-network-zone.md` | 6 | new |
| `specs/shared/044-D-node-and-region-inputs/spec.md`, `docs/adr/0039-*.md`, `CLAUDE.md`, `README.md`, `specs/hetzner/architecture.md`, `scripts/require-valid-recover-from.sh` | 6 | docs |
| `specs/hetzner/176-A-…` → `176-D-…`, `specs/hetzner/README.md` | 6 | status DONE |

---

### Task 1: REGION is the zone in the catalog and the gate

**Files:**
- Modify: `scripts/lib/catalog.sh:87-93` (comment), `:100-107`, `:122-129`, `:131-142`, new functions after `catalog_canonical_node_type`
- Modify: `scripts/lib/require-valid-node-config.sh:54-56`
- Modify: `scripts/lib/region.sh:14-16`, `:31-42`, `:50-54`
- Modify: `Makefile:54-59`
- Modify: `.github/workflows/lab.yml` (both hetzner dropdown lists)
- Modify: `scripts/argo-up.sh:427-455` (autoscaler location list and node-config keys)
- Test: `tests/scripts/node-config-test.sh`, `tests/scripts/autoscaler-config-test.sh`

**Interfaces:**
- Produces (catalog.sh, all print one space-separated line, empty when unknown):
  - `catalog_zone_locations <zone>` → `fsn1 nbg1 hel1` for `eu-central`
  - `catalog_zone_of <location>` → the zone (case-insensitive input); returns 1 when none
  - `catalog_locations_selling <zone> <type>` → the zone's locations, in order, whose list has the type
  - `catalog_node_types hetzner eu-central` → union of its locations' lists, first-seen order: `cx23 cx33 cx43 cpx32 cpx42 cx53`
  - `catalog_regions hetzner` → `eu-central`; `catalog_default_region hetzner` → `eu-central`; `catalog_default_worker_node_type hetzner eu-central` → `cx43`
- Produces (region.sh): `LAB_PROVIDER_REGION` = lowercased `REGION` (default `eu-central`) on hetzner; `HCLOUD_NETWORK_ZONE` = same value. `HCLOUD_LOCATION` is no longer set by region.sh.

- [ ] **Step 1: Write the failing test cases**

In `tests/scripts/node-config-test.sh`, replace lines 66-69:

```bash
expect pass   hetzner ""
expect pass   hetzner hel1
expect pass   hetzner fsn1
expect refuse hetzner LON1
```

with:

```bash
expect pass   hetzner ""
expect pass   hetzner eu-central
expect pass   hetzner EU-CENTRAL
# A location was the input before REGION became the zone; the refusal names the fix.
expect refuse hetzner fsn1      "use REGION=eu-central"
expect refuse hetzner HEL1      "use REGION=eu-central"
expect refuse hetzner us-east   "is not valid"
expect refuse hetzner LON1
```

Replace lines 104-109 (the six hetzner `expect_cp` lines) with:

```bash
expect_cp pass   hetzner eu-central ""
expect_cp pass   hetzner eu-central cx23
expect_cp pass   hetzner eu-central CX23
expect_cp pass   hetzner eu-central cx53
expect_cp refuse hetzner eu-central cax11 "not allowed in 'eu-central'"
```

In lines 150-157 (the eight `expect_mm ... hetzner fsn1 ...` lines) replace `fsn1` with `eu-central` on each line, keeping everything else.

Add, directly before the `# lab.yml lists the node types in two dropdowns.` comment block:

```bash
# The zone's answers are derived from its locations' lists, so they are pinned
# here rather than trusted.
expect_catalog() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    echo "ok: $label"
  else
    echo "FAIL: $label: got '$got', want '$want'"
    fails=$((fails + 1))
  fi
}
catalog_eval() { ( cd "$REPO_ROOT" && bash -c "source scripts/lib/catalog.sh; $1" ); }

expect_catalog "eu-central locations, placement order" \
  "$(catalog_eval 'catalog_zone_locations eu-central')" "fsn1 nbg1 hel1"
expect_catalog "eu-central sells the union of its locations" \
  "$(catalog_eval 'catalog_node_types hetzner eu-central')" "cx23 cx33 cx43 cpx32 cpx42 cx53"
expect_catalog "cx43 sells in fsn1 and nbg1 only" \
  "$(catalog_eval 'catalog_locations_selling eu-central cx43')" "fsn1 nbg1"
expect_catalog "cx53 sells in nbg1 only" \
  "$(catalog_eval 'catalog_locations_selling eu-central cx53')" "nbg1"
expect_catalog "an unsold type sells nowhere" \
  "$(catalog_eval 'catalog_locations_selling eu-central cax11')" ""
expect_catalog "a location maps back to its zone" \
  "$(catalog_eval 'catalog_zone_of HEL1')" "eu-central"
expect_catalog "the hetzner default region is the zone" \
  "$(catalog_eval 'catalog_default_region hetzner')" "eu-central"
expect_catalog "the zone's default worker type" \
  "$(catalog_eval 'catalog_default_worker_node_type hetzner eu-central')" "cx43"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/scripts/node-config-test.sh`
Expected: FAIL lines for `REGION='eu-central' should pass`, `REGION='fsn1' should be refused`, the `expect_catalog` cases (`catalog_zone_locations: command not found` → empty), and the lab.yml dropdown comparison does not fail yet. Exit 1.

- [ ] **Step 3: Rewrite the hetzner catalog entries**

In `scripts/lib/catalog.sh`:

`catalog_regions`: change `hetzner) echo "nbg1 hel1 fsn1" ;;` to `hetzner) echo "eu-central" ;;`.

`catalog_node_types`: add a line before `hetzner:nbg1)`:

```bash
    hetzner:eu-central) catalog_zone_node_types eu-central ;;
```

`catalog_default_region`: change `hetzner) echo "fsn1" ;;` to `hetzner) echo "eu-central" ;;`.

`catalog_default_worker_node_type`: delete the line `hetzner:hel1) echo "cx33" ;;` and replace the comment above the function with:

```bash
# Keyed by (provider, region) for the same reason catalog_node_types is: a flat
# default would name a type that cannot be created there.
```

Append at the end of the file:

```bash
# Hetzner's REGION is a network zone. Its locations are listed in placement
# order: servers and autoscaler groups try them first to last.
catalog_zone_locations() {
  case "$1" in
    eu-central) echo "fsn1 nbg1 hel1" ;;
    *) echo "" ;;
  esac
}

catalog_zone_of() {
  local want zone location
  want="$(catalog_lower "$1")"
  for zone in $(catalog_regions hetzner); do
    for location in $(catalog_zone_locations "$zone"); do
      if [ "$location" = "$want" ]; then
        printf '%s' "$zone"
        return 0
      fi
    done
  done
  return 1
}

# A zone sells a type when any of its locations does.
catalog_zone_node_types() {
  local location type seen=""
  for location in $(catalog_zone_locations "$1"); do
    for type in $(catalog_node_types hetzner "$location"); do
      case " $seen " in *" $type "*) continue ;; esac
      seen="$seen $type"
    done
  done
  echo "${seen# }"
}

catalog_locations_selling() {
  local location list=""
  for location in $(catalog_zone_locations "$1"); do
    case " $(catalog_node_types hetzner "$location") " in
      *" $2 "*) list="$list $location" ;;
    esac
  done
  echo "${list# }"
}
```

Replace the header comment paragraph at lines 87-93 (`# Region lists carry their own constraints. Hetzner is limited to the ...` through `... spelled uppercase to match CIVO_REGION in region.sh.`) with:

```bash
# Region lists carry their own constraints. Hetzner's REGION is the network
# zone, eu-central, because the private network HETZ-025 creates is
# eu-central and a server outside that zone cannot attach to it; the zone's
# locations are listed below and any of them can host any server. Hetzner
# location/type availability is HETZ-020's real creates on 2026-09-21
# (hetzner/research.md:144), not Hetzner's published catalogue, which
# proved unreliable in both directions. Civo regions are `civo region ls`,
# 2026-09-21, spelled uppercase to match CIVO_REGION in region.sh.
```

(This block is a header document, not an inline code comment; it keeps its existing references.)

- [ ] **Step 4: Name the fix when REGION is a location**

In `scripts/lib/require-valid-node-config.sh`, replace:

```bash
  elif ! canonical_region="$(catalog_canonical_region "$provider" "$region")"; then
    errors+=("REGION '$region' is not valid for PROVIDER '$provider'")
  fi
```

with:

```bash
  elif ! canonical_region="$(catalog_canonical_region "$provider" "$region")"; then
    local zone
    if [ "$provider" = "hetzner" ] && zone="$(catalog_zone_of "$region")"; then
      errors+=("REGION is a network zone on hetzner; '$region' is a location in $zone - use REGION=$zone")
    else
      errors+=("REGION '$region' is not valid for PROVIDER '$provider'")
    fi
  fi
```

- [ ] **Step 5: Name the state namespace after the zone**

In `scripts/lib/region.sh`:

Replace lines 14-16:

```bash
# REGION is the provider's region, validated against scripts/lib/catalog.sh
# before any of this is read. It selects a Civo region or a Hetzner location
# only; on aws it is refused, so nothing here reads it.
```

with:

```bash
# REGION is the provider's region, validated against scripts/lib/catalog.sh
# before any of this is read. It selects a Civo region or a Hetzner network
# zone only; on aws it is refused, so nothing here reads it.
```

Replace lines 31-42 (the `HCLOUD_LOCATION` if-block through `HCLOUD_NETWORK_ZONE="eu-central"`) with:

```bash
# Lowercased here because some callers source this before provider.sh
# canonicalises REGION, and the bucket name must not depend on that order.
if [ "${PROVIDER:-}" = "hetzner" ] && [ -n "${REGION:-}" ]; then
  HCLOUD_NETWORK_ZONE="$(printf '%s' "$REGION" | tr '[:upper:]' '[:lower:]')"
else
  HCLOUD_NETWORK_ZONE="eu-central"
fi
```

Change line 52 `hetzner) LAB_PROVIDER_REGION="$HCLOUD_LOCATION" ;;` to:

```bash
  hetzner) LAB_PROVIDER_REGION="$HCLOUD_NETWORK_ZONE" ;;
```

- [ ] **Step 6: Makefile default**

Replace `Makefile` lines 55-59:

```make
export REGION ?= fsn1
# No WORKER_NODE_TYPE literal: hetzner's default depends on the region, since
# hel1 does not sell cx43, and every hetzner recipe reaches terragrunt through
# provider.sh, which resolves it. A literal here would override that and make
# REGION=hel1 fail the gate on a type the operator never chose.
```

with:

```make
# The network zone, not a location: the platform picks the location per server.
export REGION ?= eu-central
# No WORKER_NODE_TYPE literal: every hetzner recipe reaches terragrunt through
# provider.sh, which takes the zone's default from the catalogue.
```

- [ ] **Step 7: Run the test; fix the dropdown order it reports**

Run: `bash tests/scripts/node-config-test.sh`
Expected: every REGION, catalog, cp and mm case passes; the two lab.yml dropdown comparisons FAIL with a diff, because the hetzner union now lists `cx53` last (`cx23 cx33 cx43 cpx32 cpx42 cx53`).

In `.github/workflows/lab.yml`, in both the `worker_node_type` and the `control_plane_node_type` option lists, move the line `          - "hetzner: cx53"` to directly after `          - "hetzner: cpx42"`. Change nothing else in those lists.

Run: `bash tests/scripts/node-config-test.sh`
Expected: `all node-config cases passed`.

- [ ] **Step 8: Autoscaler test reads the zone (fails first)**

In `tests/scripts/autoscaler-config-test.sh` replace the four `check_locations` lines with:

```bash
check_locations "every location of the zone that sells the type, in order" eu-central cx33 "fsn1 nbg1 hel1"
check_locations "a location that does not sell the type is left out" eu-central cx43 "fsn1 nbg1"
check_locations "a type one location sells gets one group" eu-central cx53 "nbg1"
```

Replace the line `export WORKER_NODE_TYPE=cx43` (directly before `ensure_autoscaler_config`) with:

```bash
export REGION=eu-central
```

Replace the keys check:

```bash
check "a node config for every catalog location and the old single group, whatever the type" \
  '.nodeConfigs | keys == ["workers","workers-fsn1","workers-hel1","workers-nbg1"]'
```

with:

```bash
check "a node config for every location of the zone, a superset of the groups" \
  '.nodeConfigs | keys == ["workers-fsn1","workers-hel1","workers-nbg1"]'
```

Change the final line to `echo "autoscaler-config-test: all 12 cases passed"`.

Run: `bash tests/scripts/autoscaler-config-test.sh`
Expected: FAIL — `check_locations` gets `eu-central ...` back (REGION is echoed first) and the keys still include `workers`.

- [ ] **Step 9: argo-up autoscaler reads the zone**

Replace `hetzner_autoscaler_locations` and its comment (lines 427-438) with:

```bash
# One autoscaler group per location of the zone that sells the worker type, in
# placement order: the expander tries them first to last.
hetzner_autoscaler_locations() {
  catalog_locations_selling "$REGION" "$WORKER_NODE_TYPE"
}
```

In `ensure_autoscaler_config`, replace the three comment lines above it with:

```bash
# The node template is Terraform's own worker render, so an autoscaled node
# cannot drift from the fixed pool. Keys cover every location of the zone: a
# --nodes group with no key makes the autoscaler exit.
```

and change `--arg locations "$(catalog_regions hetzner)" \` to `--arg locations "$(catalog_zone_locations "$REGION")" \`, and `nodeConfigs: (($locations | split(" ") | map("workers-" + .)) + ["workers"] | map({` to `nodeConfigs: ($locations | split(" ") | map("workers-" + .) | map({`.

Run: `bash tests/scripts/autoscaler-config-test.sh`
Expected: `autoscaler-config-test: all 12 cases passed`.

- [ ] **Step 10: Run the shell checks**

Run: `make scripts-check`
Expected: pass. If another `tests/scripts/*-test.sh` fails because it sets `REGION=fsn1` for hetzner, do not change it in this task unless it is `node-config-test.sh` or `autoscaler-config-test.sh`; note it in the report (Task 4 changes `park-test.sh`; `clusters-test.sh` unsets REGION itself).

- [ ] **Step 11: Commit**

```bash
git add scripts/lib/catalog.sh scripts/lib/require-valid-node-config.sh scripts/lib/region.sh Makefile .github/workflows/lab.yml tests/scripts/node-config-test.sh scripts/argo-up.sh tests/scripts/autoscaler-config-test.sh
git commit -F - <<'EOF'
HETZ-176: REGION is the network zone on hetzner

The catalogue maps eu-central to fsn1, nbg1 and hel1 and answers zone-level
questions from the per-location lists. REGION=fsn1 is refused with the fix
named, the state namespace is the lowercased zone, and the autoscaler groups
and node configs come from the zone's locations (the old "workers" key goes).

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 2: Terraform names from the zone, server location per attempt

**Files:**
- Modify: `terraform/live/root.hcl:18-20`, `:49-52`, `:80-82`
- Modify: `terraform/live/persistent-hetzner/network/terragrunt.hcl`
- Modify: `terraform/live/cluster-hetzner/k8s/terragrunt.hcl:42`
- Modify: `terraform/modules/hcloud-nodes/main.tf:69-73`, `:108-111`; `variables.tf:43-47`

**Interfaces:**
- Consumes: Task 1's meaning of `REGION` (the zone).
- Produces: env var `HCLOUD_LOCATION` is the k8s unit's `location` input (default `fsn1`, used only by plan/destroy); `include.root.locals.provider_region` is the lowercased zone on hetzner.

- [ ] **Step 1: root.hcl**

Replace lines 18-20:

```hcl
  # Every AWS resource this platform creates lives in the account region,
  # whatever the target. REGION selects a Civo region or a Hetzner location
  # and never an AWS one, so no layer varies this.
```

with:

```hcl
  # Every AWS resource this platform creates lives in the account region,
  # whatever the target. REGION selects a Civo region or a Hetzner network
  # zone and never an AWS one, so no layer varies this.
```

In `provider_region`, change `local.provider_name == "hetzner" ? local.hcloud_location : local.aws_region)` to `local.provider_name == "hetzner" ? local.hcloud_network_zone : local.aws_region)`.

Replace lines 80-82:

```hcl
  # Also declared in scripts/lib/region.sh - Terraform and shell each need
  # their own copy, since neither can read the other's.
  hcloud_location = local.provider_name == "hetzner" && local.region_input != "" ? local.region_input : "fsn1"
```

with:

```hcl
  # Also declared in scripts/lib/region.sh - Terraform and shell each need
  # their own copy, since neither can read the other's.
  hcloud_network_zone = local.provider_name == "hetzner" && local.region_input != "" ? local.region_input : "eu-central"
```

- [ ] **Step 2: The network takes its zone from REGION**

Replace `terraform/live/persistent-hetzner/network/terragrunt.hcl` with:

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
  # Needed to read provider_region below.
  expose = true
}

terraform {
  source = "${get_repo_root()}/terraform/modules/hcloud-network"
}

inputs = {
  project      = get_env("PROJECT_NAME", "vk-lab-platform")
  network_zone = include.root.locals.provider_region
}
```

- [ ] **Step 3: The server location is per attempt**

In `terraform/live/cluster-hetzner/k8s/terragrunt.hcl` replace line 42:

```hcl
  location                = get_env("REGION", "fsn1")
```

with:

```hcl
  # Set per attempt by hetzner_apply. Never REGION: that names the state bucket.
  location                = get_env("HCLOUD_LOCATION", "fsn1")
```

- [ ] **Step 4: Existing servers never move**

In `terraform/modules/hcloud-nodes/main.tf`, control plane: replace

```hcl
  # Replacing or power-cycling this server is cluster loss, so a cloud-init,
  # image or public_net edit must never trigger one. Such a change ships as a
  # teardown and a fresh bring-up instead.
  lifecycle {
    ignore_changes = [user_data, image, ssh_keys, public_net]
```

with:

```hcl
  # Replacing or power-cycling this server is cluster loss, so a cloud-init,
  # image, public_net or location change must never trigger one. Such a change
  # ships as a teardown and a fresh bring-up instead.
  lifecycle {
    ignore_changes = [user_data, image, ssh_keys, public_net, location]
```

Worker: in its `lifecycle` block change `ignore_changes = [user_data, image, ssh_keys, public_net]` to `ignore_changes = [user_data, image, ssh_keys, public_net, location]`, and above the existing two-line comment add nothing.

In `variables.tf` replace the `location` variable's description with:

```hcl
  description = "The Hetzner location for a server this apply creates. A server keeps its location afterwards; the variable may differ per apply attempt."
```

- [ ] **Step 5: Validate**

Run:
```bash
terraform fmt -check -recursive terraform/
terraform -chdir=terraform/modules/hcloud-nodes init -backend=false -input=false >/dev/null && terraform -chdir=terraform/modules/hcloud-nodes validate
terraform -chdir=terraform/modules/hcloud-network init -backend=false -input=false >/dev/null && terraform -chdir=terraform/modules/hcloud-network validate
PROVIDER=hetzner REGION=EU-Central bash -c 'source scripts/lib/region.sh; echo "$LAB_PROVIDER_REGION"'
```
Expected: fmt clean; both `Success! The configuration is valid.`; last line `eu-central`. Remove any `.terraform/` and `.terraform.lock.hcl` files the two `init` calls created that are not already tracked (`git status` must show only the intended changes).

- [ ] **Step 6: Commit**

```bash
git add terraform/live/root.hcl terraform/live/persistent-hetzner/network/terragrunt.hcl terraform/live/cluster-hetzner/k8s/terragrunt.hcl terraform/modules/hcloud-nodes/main.tf terraform/modules/hcloud-nodes/variables.tf
git commit -F - <<'EOF'
HETZ-176: Terraform names the state after the zone; servers keep their location

The bucket namespace is the zone, the network subnet takes its zone from
REGION, and the server location comes from HCLOUD_LOCATION per apply
attempt. location is ignored after create, so a retry in another location
never moves or replaces a server that already exists.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 3: The region-change guard sees location-named buckets

**Files:**
- Modify: `scripts/state-up.sh:41-65`
- Create: `tests/scripts/state-up-guard-test.sh`

**Interfaces:**
- Consumes: `catalog_regions`, `catalog_zone_locations`, `catalog_zone_of` (Task 1); `LAB_PROVIDER_REGION` (Task 1).

- [ ] **Step 1: Write the failing test**

Create `tests/scripts/state-up-guard-test.sh` (mode 755):

```bash
#!/usr/bin/env bash
# Pins state-up's region-change guard for hetzner: a bucket named after a
# location, from before REGION became the zone, must still block a second
# platform. Needs no credentials - aws and terragrunt are fakes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo/scripts/lib" "$TMP/repo/terraform/live/state"
cp "$REPO_ROOT/scripts/state-up.sh" "$TMP/repo/scripts/"
cp "$REPO_ROOT"/scripts/lib/*.sh "$TMP/repo/scripts/lib/"
touch "$TMP/repo/terraform/live/state/terragrunt.hcl"
CALLS="$TMP/calls"
export CALLS

# LEGACY: full - the fsn1 bucket holds objects; empty - it exists but is empty;
# absent - it does not exist. The zone bucket always exists.
cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
bucket=""
prev=""
for a in "$@"; do
  [ "$prev" = "--bucket" ] && bucket="$a"
  prev="$a"
done
case "$1 $2" in
  "sts get-caller-identity") echo '{}' ;;
  "s3api head-bucket")
    case "$bucket" in
      vk-fake-hz-eu-central-tf-state) exit 0 ;;
      vk-fake-hz-fsn1-tf-state) [ "$LEGACY" != absent ] && exit 0 ;;
    esac
    echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2
    exit 254 ;;
  "s3api list-objects-v2")
    if [ "$bucket" = vk-fake-hz-fsn1-tf-state ] && [ "$LEGACY" = full ]; then echo 3; else echo None; fi ;;
  *) echo "fake aws: unexpected $*" >&2; exit 2 ;;
esac
EOF
cat > "$TMP/bin/terragrunt" <<'EOF'
#!/usr/bin/env bash
echo "terragrunt $*" >> "$CALLS"
EOF
chmod +x "$TMP/bin/aws" "$TMP/bin/terragrunt"

fails=0
run_case() {
  rm -f "$CALLS"
  ( cd "$TMP/repo" && PATH="$TMP/bin:/usr/bin:/bin" LEGACY="$1" CALLS="$CALLS" \
      PROVIDER=hetzner PROJECT_NAME=vk-fake-hz REGION=eu-central AWS_PROFILE=fake \
      ./scripts/state-up.sh 2>&1 )
}

out="$(run_case full)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "s3://vk-fake-hz-fsn1-tf-state" \
  && printf '%s' "$out" | grep -q "a020ba9" && [ ! -s "$CALLS" ]; then
  echo "ok   a location-named bucket with objects refuses, names the old checkout, applies nothing"
else
  echo "FAIL legacy bucket with objects: rc=$rc"; echo "$out"; fails=$((fails + 1))
fi

for mode in empty absent; do
  out="$(run_case "$mode")"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q "terragrunt apply" "$CALLS"; then
    echo "ok   legacy bucket $mode: the guard lets state-up apply"
  else
    echo "FAIL legacy bucket $mode: rc=$rc"; echo "$out"; fails=$((fails + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "state-up-guard-test: $fails case(s) failed" >&2
  exit 1
fi
echo "state-up-guard-test: all 3 cases passed"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/scripts/state-up-guard-test.sh`
Expected: FAIL on the first case (the guard only scans `eu-central`, so the fsn1 bucket is never checked; rc=0 and terragrunt apply runs). The two other cases pass. Exit 1.

- [ ] **Step 3: Extend the guard**

In `scripts/state-up.sh`, replace lines 41-65 (from `# Changing REGION migrates nothing.` through the loop's closing `done`) with:

```bash
# Changing REGION migrates nothing. The bucket name carries the region, so a
# new region means a new bucket while the old platform keeps billing,
# invisible to this project's state. Candidates come from the catalogue, not
# a name prefix, which would false-match a longer project name. Hetzner
# buckets were once named after a location, so those names are candidates too.
candidates="$(catalog_regions "$PROVIDER")"
if [ "$PROVIDER" = hetzner ]; then
  for zone in $(catalog_regions hetzner); do
    candidates="$candidates $(catalog_zone_locations "$zone")"
  done
fi
for candidate_region in $candidates; do
  candidate_lower="$(catalog_lower "$candidate_region")"
  [ "$candidate_lower" = "$LAB_PROVIDER_REGION" ] && continue
  other_bucket="${PROJECT_NAME}-${candidate_lower}-tf-state"
  aws s3api head-bucket --bucket "$other_bucket" --region "$LAB_REGION" >/dev/null 2>&1 || continue

  other_count="$(aws s3api list-objects-v2 --bucket "$other_bucket" --region "$LAB_REGION" \
    --query 'length(Contents)' --output text 2>/dev/null || echo 0)"
  [ "$other_count" = "None" ] && other_count=0
  [ "$other_count" -gt 0 ] || continue

  {
    echo "Refusing: this project already exists in $candidate_region."
    echo "  s3://$other_bucket still holds $other_count object(s)."
    echo "Changing REGION does not move a platform - it would build a second one"
    echo "and leave the first running and billing, invisible to the new state."
    echo "Destroy the existing one first:"
    if [ "$PROVIDER" = hetzner ] && catalog_zone_of "$candidate_region" >/dev/null; then
      echo "  (a location-named bucket: only the code before REGION became a zone can name it)"
      echo "  git worktree add /tmp/platform-a020ba9 a020ba9 && cd /tmp/platform-a020ba9"
      echo "  PROVIDER=hetzner REGION=$candidate_region PROJECT_NAME=$PROJECT_NAME CONFIRM_DESTROY=$PROJECT_NAME make full-down"
    else
      echo "  REGION=$candidate_region CONFIRM_DESTROY=$PROJECT_NAME make full-down"
    fi
  } >&2
  exit 1
done
```

- [ ] **Step 4: Run the test and the shell checks**

Run: `bash tests/scripts/state-up-guard-test.sh && make scripts-check`
Expected: `state-up-guard-test: all 3 cases passed`; scripts-check passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/state-up.sh tests/scripts/state-up-guard-test.sh
git commit -F - <<'EOF'
HETZ-176: state-up refuses while a location-named bucket still holds state

Once buckets take the zone's name, the guard would no longer see a project
still running under its old -fsn1- bucket and would build a second one. It
now checks every location name too, and tells the operator to tear the old
platform down from the last commit that can name that bucket.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 4: hetzner_apply falls back across the zone's locations

**Files:**
- Modify: `scripts/lib/provider.sh` (new function, placed directly before `configure_kubeconfig()`)
- Modify: `Makefile:244`
- Modify: `scripts/park.sh:75-80`
- Modify: `tests/scripts/park-test.sh:157`
- Create: `tests/scripts/hetzner-apply-test.sh`

**Interfaces:**
- Consumes: `catalog_locations_selling`, `catalog_node_types` (Task 1); `HCLOUD_LOCATION` input of the k8s unit (Task 2); `PROVIDER_SH_REPO_ROOT`, `CLUSTER_DIR`, `REGION`, `WORKER_NODE_TYPE`, `CONTROL_PLANE_NODE_TYPE` (provider.sh).
- Produces: `hetzner_apply` — returns 0 on the first successful apply; the apply's own exit code on any other failure; 1 when every location failed on stock or withdrawal. Prints `HETZNER-APPLY: trying location <loc>` per attempt.

- [ ] **Step 1: Write the failing test**

Create `tests/scripts/hetzner-apply-test.sh` (mode 755):

```bash
#!/usr/bin/env bash
# Pins hetzner_apply's location fallback: which errors move on to the next
# location, which stop at once, and which locations are tried at all.
# Needs no credentials - terragrunt is a fake that fails as each case scripts.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo/terraform/live/cluster-hetzner"

# PLAN is a comma list, one outcome per attempt: ok, stock, withdrawn, other.
cat > "$TMP/bin/terragrunt" <<'EOF'
#!/usr/bin/env bash
echo "$HCLOUD_LOCATION" >> "$ATTEMPTS"
n="$(grep -c . "$ATTEMPTS")"
case "$(echo "$PLAN" | cut -d, -f"$n")" in
  ok) exit 0 ;;
  stock) echo "Error: error during placement (resource_unavailable, 0a1b2c)"; exit 1 ;;
  withdrawn) echo "Error: unsupported location for server type (invalid_input, 0a1b2c)"; exit 1 ;;
  *) echo "Error: image not found (invalid_input, 0a1b2c)"; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/terragrunt"

fails=0
run_case() {
  local plan="$1" worker="$2" cp="$3"
  rm -f "$TMP/attempts"
  ( cd "$REPO_ROOT" && PATH="$TMP/bin:$PATH" ATTEMPTS="$TMP/attempts" PLAN="$plan" \
      PROVIDER_SH_REPO_ROOT="$TMP/repo" CLUSTER_DIR=cluster-hetzner REGION=eu-central \
      WORKER_NODE_TYPE="$worker" CONTROL_PLANE_NODE_TYPE="$cp" bash -c '
      set -euo pipefail
      source scripts/lib/catalog.sh
      eval "$(awk "/^hetzner_apply\\(\\) \\{/,/^\\}/" scripts/lib/provider.sh)"
      hetzner_apply' 2>&1 )
}
attempts() { tr '\n' ' ' < "$TMP/attempts" | sed 's/ $//'; }

check() {
  local label="$1" want_rc="$2" want_attempts="$3" got_rc="$4" out="$5" match="${6:-}"
  local got_attempts rc_ok=0
  got_attempts="$(attempts)"
  if [ "$want_rc" = 0 ]; then
    [ "$got_rc" -eq 0 ] && rc_ok=1
  else
    [ "$got_rc" -ne 0 ] && rc_ok=1
  fi
  if [ "$rc_ok" = 1 ] && [ "$got_attempts" = "$want_attempts" ] \
    && { [ -z "$match" ] || printf '%s' "$out" | grep -q "$match"; }; then
    echo "ok   $label"
  else
    echo "FAIL $label: rc=$got_rc attempts='$got_attempts' (want '$want_attempts')"
    echo "$out"
    fails=$((fails + 1))
  fi
}

out="$(run_case ok cx33 cx23)"; check "first location succeeds" 0 "fsn1" $? "$out"
out="$(run_case stock,ok cx43 cx23)"; check "stock-out moves to the next location" 0 "fsn1 nbg1" $? "$out"
out="$(run_case withdrawn,stock,ok cx33 cx23)"; check "a withdrawn type moves on too" 0 "fsn1 nbg1 hel1" $? "$out"
out="$(run_case other cx33 cx23)"; check "any other error stops at once" 1 "fsn1" $? "$out"
out="$(run_case stock,stock cx43 cx23)"; check "every location out of stock fails and says so" 1 "fsn1 nbg1" $? "$out" "try another WORKER_NODE_TYPE"
out="$(run_case ok cx53 cx23)"; check "only locations selling the worker type are tried" 0 "nbg1" $? "$out"
out="$(run_case ok cx33 cx53)"; check "only locations selling the control-plane type are tried" 0 "nbg1" $? "$out"

if [ "$fails" -gt 0 ]; then
  echo "hetzner-apply-test: $fails case(s) failed" >&2
  exit 1
fi
echo "hetzner-apply-test: all 7 cases passed"
```

Note on the `check` call: `$?` there is the exit code of the `out="$(run_case ...)"` assignment, which is the exit code of `run_case`.

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/scripts/hetzner-apply-test.sh`
Expected: FAIL on every case (`hetzner_apply: command not found`, no attempts file). Exit 1.

- [ ] **Step 3: Add hetzner_apply**

In `scripts/lib/provider.sh`, directly before `configure_kubeconfig() {`, add:

```bash
# Applies the hetzner cluster stack, one location of the zone at a time. A
# stock-out or a withdrawn type moves on; servers an earlier attempt created
# keep their location, so the control plane and a worker can differ.
hetzner_apply() {
  local location log rc tried=""
  log="$(mktemp)"
  for location in $(catalog_locations_selling "$REGION" "$WORKER_NODE_TYPE"); do
    case " $(catalog_node_types hetzner "$location") " in
      *" $CONTROL_PLANE_NODE_TYPE "*) ;;
      *) continue ;;
    esac
    echo "HETZNER-APPLY: trying location $location"
    rc=0
    ( cd "$PROVIDER_SH_REPO_ROOT/terraform/live/$CLUSTER_DIR" &&
      HCLOUD_LOCATION="$location" terragrunt run --all --non-interactive -- apply -auto-approve ) 2>&1 \
      | tee "$log" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$log"
      return 0
    elif grep -q 'resource_unavailable' "$log"; then
      tried="$tried
  $location: out of stock (resource_unavailable)"
    elif grep -q 'unsupported location for server type' "$log"; then
      tried="$tried
  $location: type not sold there (unsupported location for server type)"
    else
      rm -f "$log"
      return "$rc"
    fi
  done
  rm -f "$log"
  echo "HETZNER-APPLY: no location in $REGION could create the servers:$tried" >&2
  echo "HETZNER-APPLY: try another WORKER_NODE_TYPE; $REGION sells: $(catalog_node_types hetzner "$REGION")" >&2
  return 1
}
```

- [ ] **Step 4: Run the test**

Run: `bash tests/scripts/hetzner-apply-test.sh`
Expected: `hetzner-apply-test: all 7 cases passed`.

- [ ] **Step 5: Route both apply paths through it**

`Makefile` line 244, replace:

```make
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; hcloud_token; use_isolated_kubeconfig; cd terraform/live/$(CLUSTER_DIR) && terragrunt run --all --non-interactive -- apply -auto-approve && configure_kubeconfig "$$KUBECONFIG" && wait_for_nodes_ready'
```

with:

```make
	@bash -c 'source scripts/lib/region.sh; source scripts/lib/provider.sh; hcloud_token; use_isolated_kubeconfig; hetzner_apply && configure_kubeconfig "$$KUBECONFIG" && wait_for_nodes_ready'
```

`scripts/park.sh`, replace the `terragrunt_apply` function:

```bash
terragrunt_apply() {
  log "applying the cluster stack with MIN_WORKER_NODES=$MIN_WORKER_NODES"
  cd "$REPO_ROOT/terraform/live/$CLUSTER_DIR"
  terragrunt run --all --non-interactive -- apply -auto-approve
  cd "$REPO_ROOT"
}
```

with:

```bash
terragrunt_apply() {
  log "applying the cluster stack with MIN_WORKER_NODES=$MIN_WORKER_NODES"
  hetzner_apply
}
```

`tests/scripts/park-test.sh` line 157: change `REGION=fsn1` to `REGION=eu-central`.

- [ ] **Step 6: Run the checks**

Run: `bash tests/scripts/park-test.sh && bash tests/scripts/hetzner-apply-test.sh && make scripts-check`
Expected: all pass. If park-test fails because its fake `terragrunt` asserts the working directory, read its fake and report what it expects rather than weakening it.

- [ ] **Step 7: Commit**

```bash
git add scripts/lib/provider.sh Makefile scripts/park.sh tests/scripts/park-test.sh tests/scripts/hetzner-apply-test.sh
git commit -F - <<'EOF'
HETZ-176: the hetzner apply falls back across the zone's locations

hetzner_apply runs the cluster stack once per location that sells both
server types, in catalogue order. resource_unavailable or "unsupported
location for server type" moves on; any other error stops. cluster-up and
park/unpark both apply through it, so a stock-out in fsn1 no longer fails a
bring-up.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 5: The load balancer is placed by network zone

**Files:**
- Modify: `scripts/argo-up.sh:256-260` (comment), `:902-905` (comment), `:916`
- Modify: `gitops/templates/_helpers.tpl:131-133`
- Modify: `gitops/values.yaml:167`, `gitops/bootstrap/values.yaml:47`, `gitops/bootstrap/templates/root-application.yaml:58-59`
- Modify: `scripts/gitops-render-check.sh` (hetzner sets; one assert)
- Modify: `.github/workflows/lifecycle-test.yml:298`
- Regenerate: `tests/golden/gitops-aws/bootstrap/Application__argocd__root.yaml`

**Interfaces:**
- Consumes: `catalog_locations_selling`, `catalog_zone_locations` (Task 1); `REGION` is the zone.
- Produces: Helm value `envoyGateway.networkZone` (replaces `envoyGateway.location`).

- [ ] **Step 1: Load balancer by network zone**

`gitops/templates/_helpers.tpl`, replace:

```yaml
  # Immutable - changing it deletes and recreates the load balancer, which
  # gets a new public IPv4. Carried from the REGION operator input.
  load-balancer.hetzner.cloud/location: {{ .Values.envoyGateway.location | quote }}
```

with:

```yaml
  # Immutable, and exclusive with the location annotation: changing either
  # recreates the load balancer with a new IPv4. Hetzner picks the location.
  load-balancer.hetzner.cloud/network-zone: {{ .Values.envoyGateway.networkZone | quote }}
```

In `gitops/values.yaml` and `gitops/bootstrap/values.yaml`, in the `envoyGateway` block, change `location: ""` to `networkZone: ""`.

In `gitops/bootstrap/templates/root-application.yaml`, replace:

```yaml
        - name: envoyGateway.location
          value: {{ .Values.envoyGateway.location | quote }}
```

with:

```yaml
        - name: envoyGateway.networkZone
          value: {{ .Values.envoyGateway.networkZone | quote }}
```

`scripts/argo-up.sh`: change `--set envoyGateway.location="$REGION" \` to `--set envoyGateway.networkZone="$REGION" \`. Replace the comment lines 904-905:

```bash
# REGION rather than HCLOUD_LOCATION: region.sh is sourced before provider.sh
# canonicalises the case, and the hcloud API wants it lowercase.
```

with:

```bash
# REGION is the network zone here, canonicalised by provider.sh.
```

and in the comment at lines 259-260 change `The load balancer's location is not one of\n# them: it comes from the REGION operator input, which no Terraform layer owns.` to `The load balancer's network zone is not one\n# of them: it is the REGION operator input, which no Terraform layer owns.` (two lines, same position).

`.github/workflows/lifecycle-test.yml` line 298: change `--set envoyGateway.location=fsn1 \` to `--set envoyGateway.networkZone=eu-central \`.

- [ ] **Step 2: Render check asserts the annotation**

In `scripts/gitops-render-check.sh`, in the hetzner `extra_sets+=(` block, add the line:

```bash
      --set envoyGateway.networkZone=eu-central
```

In the `if [ "$target" = hetzner ]; then` block that calls `assert_helm_values ... cluster-autoscaler`, directly after that call, add:

```bash
    local lb
    lb="$(grep -rh 'load-balancer.hetzner.cloud/' "$dir" || true)"
    if ! printf '%s' "$lb" | grep -q 'load-balancer.hetzner.cloud/network-zone: "\{0,1\}eu-central'; then
      echo "GITOPS-RENDER-CHECK: target=$target renders no network-zone annotation for the load balancer" >&2
      return 1
    fi
    if printf '%s' "$lb" | grep -q 'load-balancer.hetzner.cloud/location:'; then
      echo "GITOPS-RENDER-CHECK: target=$target renders a location annotation, which excludes network-zone" >&2
      return 1
    fi
```

- [ ] **Step 3: Render, regenerate the golden, inspect**

Run:
```bash
make gitops-check || true
./scripts/gitops-render-check.sh update
git diff tests/golden/
make gitops-check
```
Expected: the golden diff is exactly `envoyGateway.location` → `envoyGateway.networkZone` in `bootstrap/Application__argocd__root.yaml` (value `""`). Any other golden change is an AWS regression: stop and fix. Final `make gitops-check` passes.

- [ ] **Step 4: All checks**

Run: `make scripts-check && make gitops-check && helm lint gitops/ && helm lint gitops/bootstrap`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/argo-up.sh gitops scripts/gitops-render-check.sh .github/workflows/lifecycle-test.yml tests/golden
git commit -F - <<'EOF'
HETZ-176: the load balancer is placed by network zone

The load balancer is placed by network-zone instead of a fixed location;
the render check fails if a location annotation comes back, because the two
are mutually exclusive.

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 6: ADR 0047, docs, spec DONE

**Files:**
- Create: `docs/adr/0047-hetzner-region-is-a-network-zone.md`
- Modify: `specs/shared/044-D-node-and-region-inputs/spec.md` (§6), `docs/adr/0039-project-region-as-operator-input.md` (status line), `CLAUDE.md:154`, `README.md:167-168`, `:194-204`, `:233-234`, `:513-525`, `.github/workflows/lab.yml:67-69`, `:74-79`, `specs/hetzner/architecture.md` (REGION mentions), `scripts/require-valid-recover-from.sh:64`
- Rename: `specs/hetzner/176-A-zone-wide-placement/` → `specs/hetzner/176-D-zone-wide-placement/`; modify `specs/hetzner/README.md`

- [ ] **Step 1: ADR 0047**

Create `docs/adr/0047-hetzner-region-is-a-network-zone.md`:

```markdown
# 0047. On Hetzner, REGION is a network zone

Date: 2026-11-23

Status: Accepted. Amends ADR 0039.

## Context

ADR 0039 made `REGION` an operator input. On Hetzner it named one location
(`fsn1`). On 2026-11-23 creates of `cx33` and `cx43` in fsn1 returned
`resource_unavailable` while nbg1 and hel1, in the same private network zone,
could host the same servers. A location-valued `REGION` pinned the control
plane, the fixed workers, the autoscaler and the load balancer to the one
location that was out of stock.

## Decision

On Hetzner, `REGION` names the network zone. The only accepted zone is
`eu-central`; other zones are refused until a create probe shows what they sell.

- The platform picks the location per server. `make up` and `make unpark`
  try the zone's locations in catalogue order (`fsn1`, `nbg1`, `hel1`) and
  move on after `resource_unavailable` or `unsupported location for server type`.
  A server keeps its location after create.
- The autoscaler runs one node group per location that sells the worker type.
- The load balancer is placed with `load-balancer.hetzner.cloud/network-zone`.
- The state and backup buckets are named after the zone
  (`<project>-eu-central-tf-state`). A location value (`REGION=fsn1`) is
  refused with a message naming the zone.

## Consequences

- Moving a live platform to the new names is a `make full-down` with the code
  before this change, then a `make full-up` with it. The region-change guard
  refuses a `full-up` while a location-named bucket still holds state.
- A volume stays in the location where it was created. After `make park`, an
  unparked worker can land in another location; pods bound to those volumes
  wait for an autoscaled node in the volumes' location.
- Civo and AWS are unchanged.
```

In `docs/adr/0039-project-region-as-operator-input.md`, change its `Status:` line by appending ` Amended by ADR 0047 (on Hetzner, REGION is a network zone).` to the existing text.

- [ ] **Step 2: SHARED-044 amendment**

Append to §6 of `specs/shared/044-D-node-and-region-inputs/spec.md`:

```markdown
- 2026-11-23 — amended by HETZ-176 and ADR 0047: on Hetzner, `REGION` is the
  network zone (`eu-central`), not a location. The catalogue maps the zone to
  its locations; the state and backup buckets are named after the zone; the
  §3.7 region guard also checks the old location-named buckets.
```

- [ ] **Step 3: Operator docs**

In the bullets below, `\`` is only an escape for a literal backtick: write plain backticks in the files.


- `CLAUDE.md:154`: replace `selects the Civo region or the Hetzner location only` with `selects the Civo region or the Hetzner network zone only (ADR 0047: the platform picks the Hetzner location per server)`.
- `README.md:167`: `| \`REGION\` | \`LON1\` / \`eu-central\` | \`civo\` and \`hetzner\` only (on hetzner the network zone; a location is refused), see below; matched case-insensitively. Refused on \`aws\` |`
- `README.md:168`: `| \`WORKER_NODE_TYPE\` | \`t4g.medium\` / \`g4s.kube.medium\` / \`cx43\` | see below; a hetzner type must sell in at least one location of the zone |`
- `README.md:198-200` (the three hetzner rows): replace with one row `| \`hetzner\` | \`eu-central\` (locations \`fsn1\` \`nbg1\` \`hel1\`) | \`cx23\` \`cx33\` \`cx43\` \`cpx32\` \`cpx42\` \`cx53\` |`, and replace the paragraph at 202-204 with: `Node types are listed per region. On Hetzner the region is a network zone and the platform picks the location: \`cx43\` sells in \`fsn1\` and \`nbg1\` but not \`hel1\`, \`cx53\` only in \`nbg1\`, and a server is created in the first location of \`fsn1\`, \`nbg1\`, \`hel1\` that sells its type and has stock. All four Civo sizes sell in all four Civo regions, checked against \`civo size ls\` per region on 2026-09-22.`
- `README.md:233-234`: `| \`hetzner\` | \`cx33\` | 4 / 8 GiB | USD 12.09 |` and `| \`hetzner\` | \`cx43\` *(default)* | 8 / 16 GiB | USD 22.37 |`.
- `README.md:516`: change `` `fsn1`/`cx43`/`1`/`2` `` to `` `eu-central`/`cx43`/`1`/`2` ``.
- `.github/workflows/lab.yml:67-69`: `# civo and hetzner only. Blank uses the provider's default - LON1 on` / `# civo, the eu-central network zone on hetzner. aws refuses a value here: its` / `# region is fixed at eu-west-1, and the offline gate says so in the job's first seconds.` (keep it to these three lines).
- `.github/workflows/lab.yml:74-79`: replace `cx33 in hetzner hel1,\n      # which is the one region the preselected cx43 does not sell.` wording with `cx43 on hetzner.` — keep the rest of the comment.
- `specs/hetzner/architecture.md`: every sentence that says `REGION` selects a location (lines ~58-59, ~97) — reword to the network zone, with the location picked per server (ADR 0047).
- `scripts/require-valid-recover-from.sh:64`: in the help text, `<project>-<region>-postgres-backups` stays correct; no change unless it says `location`.

Run: `grep -rn "Hetzner location\|hetzner location" CLAUDE.md README.md specs/hetzner/architecture.md .github/workflows/lab.yml` and fix any remaining sentence that calls `REGION` a location.

- [ ] **Step 4: Spec to DONE**

```bash
git mv specs/hetzner/176-A-zone-wide-placement specs/hetzner/176-D-zone-wide-placement
grep -rln '176-A-zone-wide-placement' . --exclude-dir=.git --exclude-dir=.superpowers
```
Replace each hit outside `docs/superpowers/plans/` with `176-D-zone-wide-placement`. In `specs/hetzner/README.md`, set the HETZ-176 row status to `DONE`.

In the spec front matter: `status: "DONE"`, `completed: "2026-11-23"` (or today), `updated:` same. Tick §13 items that are met, and append to §14:

```markdown
- 2026-11-23 — PR 1 (#117, `a020ba9`) live check on vk-hetzner-lab: after the
  merge the root failed to render ("capacity.autoscaler.locations is set by
  argo-up"), argo-up took the full path, and the autoscaler ran
  `--nodes=0:1:CX33:{FSN1,NBG1,HEL1}:workers-{fsn1,nbg1,hel1}`,
  `--expander=priority`, `--max-nodes-total=3`, priorities 30/20/10, pod
  Running with no restarts. AC3 met for part A.
- <date> — Part B implemented (PR 2): REGION is the zone, zone-named buckets,
  network-zone load balancer, hetzner_apply location fallback, guard for
  location-named buckets, ADR 0047. Evidence: node-config-test,
  state-up-guard-test, hetzner-apply-test (AC6, AC7 offline), autoscaler-config
  test, gitops-check (aws golden: one parameter renamed — AC9). Outstanding
  until the live rollout (§11 PR 2): AC1, AC2, AC3 (zone), AC4 live, AC5,
  AC8.
```

- [ ] **Step 5: All checks**

Run: `make specs-check && make gitops-check && make scripts-check`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A docs/adr specs CLAUDE.md README.md .github/workflows/lab.yml scripts/require-valid-recover-from.sh
git commit -F - <<'EOF'
HETZ-176: ADR 0047, docs, spec DONE

Co-Authored-By: <model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 7: PR 2 and the live rollout (controller + operator)

**Files:** none.

- [ ] **Step 1: Push and open PR 2 without a lifecycle label, then swap labels in one edit**

```bash
git push -u origin hetz-176-part-b
gh pr create --title "HETZ-176 part B: REGION is a network zone on Hetzner" --label ci:skip-lifecycle --body-file <body>
gh pr edit --remove-label ci:skip-lifecycle --add-label ci:lifecycle-hetzner
```
The body states: what changed, ADR 0047, the validation run, and the rollout order below with the warning that **auto-merge must not be enabled before step 2 is done**. A cancelled first run is expected; `gh run rerun <id>` it.

- [ ] **Step 2: Tear the live lab down with the old code (operator, before merge)**

```bash
git -C /Users/margo/Proj/Lab/vk-lab-platform worktree add /tmp/platform-a020ba9 a020ba9
cd /tmp/platform-a020ba9
AWS_PROFILE=viacheslav-dev PROVIDER=hetzner PROJECT_NAME=vk-hetzner-lab CONFIRM_DESTROY=vk-hetzner-lab make full-down
```
Then check nothing remains: `hcloud server list`, `hcloud load-balancer list`, `hcloud volume list`, `hcloud network list` show no `vk-hetzner-lab` resource; `aws s3 ls | grep vk-hetzner-lab` is empty.

- [ ] **Step 3: Merge PR 2, then bring the lab up from main**

```bash
cd /Users/margo/Proj/Lab/vk-lab-platform-hetz176b && git fetch origin && git checkout --detach origin/main
AWS_PROFILE=viacheslav-dev PROVIDER=hetzner PROJECT_NAME=vk-hetzner-lab make full-up
```
If every location refuses the worker type, run again with `WORKER_NODE_TYPE=cx33` (or `cpx32`).

- [ ] **Step 4: Acceptance checks**

- AC1: `aws s3 ls | grep vk-hetzner-lab` shows `vk-hetzner-lab-eu-central-tf-state` and `vk-hetzner-lab-eu-central-postgres-backups`.
- AC2: `kubectl -n envoy get svc -o yaml | grep 'load-balancer.hetzner.cloud/'` shows `network-zone: eu-central` and no `location:`; `curl -sI https://argocd.hz.lab.<root-domain>` answers over TLS.
- AC3: autoscaler args and priority ConfigMap as in Part A, from the zone.
- The `HETZNER-APPLY: trying location ...` lines in the full-up output (AC6 live).
- AC8: `make down`, then `make up`, then `make verify-no-leaks`.

- [ ] **Step 5: Record**

Add the live evidence to the spec's §14 in a follow-up only if a code change is needed anyway; otherwise record it in the PR conversation (a status-only spec PR is not allowed).
