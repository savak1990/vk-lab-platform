# HETZ-176 Part A — Autoscaler Groups per Location Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Hetzner cluster autoscaler gets one node group per location that sells the worker type, tried in priority order, with a total node cap, so it can add a worker when one location is out of stock.

**Architecture:** `argo-up.sh` computes one space-separated location list (`REGION` first, then the other catalog locations that sell `WORKER_NODE_TYPE`). The same list feeds two consumers: the root Application parameter `capacity.autoscaler.locations` (rendered into one `autoscalingGroups` entry and one `expanderPriorities` entry per location) and the `nodeConfigs` keys in the `hcloud-autoscaler-config` Secret. `REGION` is still one location in this PR; Part B (PR 2, separate plan) turns it into a network zone.

**Tech Stack:** Bash, jq, Helm 3 templates (sprig), Argo CD Applications, cluster-autoscaler chart 9.59.0 / image v1.36.1 (hetzner provider).

**Spec:** `specs/hetzner/176-P-zone-wide-placement/spec.md` (§4.5, §5 Part A, §6 steps 1–4, §11 PR 1). Task 3 renames the folder to `176-A-zone-wide-placement`.

## Global Constraints

- Work in the worktree `/Users/margo/Proj/Lab/vk-lab-platform-hetz176`, branch `hetz-176-zone-placement`. Never commit in `/Users/margo/Proj/Lab/vk-lab-platform` (shared checkout).
- Hetzner only. Civo and AWS behavior MUST NOT change. The aws golden (`tests/golden/gitops-aws/`) may change only in the bootstrap `root` Application's parameter list.
- Group name: `workers-<location>` (lowercase location). Group `region`: the location in uppercase.
- `minSize: 0`, `maxSize: MAX_WORKER_NODES - MIN_WORKER_NODES` (unchanged meaning of `capacity.autoscaler.max`).
- `extraArgs.max-nodes-total` = `1 + MAX_WORKER_NODES` (it counts every node: control plane, fixed workers, autoscaled workers).
- `extraArgs.expander: priority`; `expanderPriorities` keys are `(len - index) * 10`, values one anchored regex `^workers-<location>$`.
- The location list is space-separated, never comma-separated (`helm --set` splits on commas).
- `nodeConfigs` also keeps a `workers` key in this PR. The provider looks keys up by group name only (`hetzner_cloud_provider.go:244` at v1.36.1), so an extra key is ignored, while a missing one is fatal. This makes the Secret safe for both the old `workers` group and the new groups. Part B removes it.
- Code comments: only where the code is not obvious, at most 3 lines, never naming a spec, ADR or ticket (repo `CLAUDE.md`).
- Commit trailer on every commit:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
  ```

---

## File map

| File | Change |
|---|---|
| `gitops/templates/platform/hetzner/autoscaler/application.yaml` | groups and priorities from the list; expander; cap |
| `gitops/values.yaml` | `capacity.autoscaler.location` → `locations`; add `maxNodesTotal` |
| `gitops/bootstrap/values.yaml` | same two keys |
| `gitops/bootstrap/templates/root-application.yaml` | same two parameters |
| `tests/golden/gitops-aws/bootstrap/Application__argocd__root.yaml` | regenerated |
| `scripts/gitops-render-check.sh` | hetzner render sets the values; asserts groups, priorities, cap |
| `.github/workflows/lifecycle-test.yml` | hetzner `helm template` sets the required values |
| `scripts/argo-up.sh` | `hetzner_autoscaler_locations`; `nodeConfigs` per location; root parameters |
| `tests/scripts/autoscaler-config-test.sh` | per-location keys; location list cases |
| `specs/hetzner/176-*/spec.md`, `specs/hetzner/README.md` | status `IN_PROGRESS`, folder `176-A-` |

---

### Task 1: Render one autoscaler group per location

**Files:**
- Modify: `scripts/gitops-render-check.sh` (hetzner sets in the loop near line 379; assert in `verify_object_set`)
- Modify: `gitops/templates/platform/hetzner/autoscaler/application.yaml:1`, `:29-37`, `:58-64`
- Modify: `gitops/values.yaml:21-34`
- Modify: `gitops/bootstrap/values.yaml:31-38`
- Modify: `gitops/bootstrap/templates/root-application.yaml:42-43`
- Modify: `.github/workflows/lifecycle-test.yml:295-299`
- Regenerate: `tests/golden/gitops-aws/bootstrap/Application__argocd__root.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: Helm values `capacity.autoscaler.locations` (string, space-separated locations, required on hetzner) and `capacity.autoscaler.maxNodesTotal` (string of an integer, required on hetzner). Task 2 sets both from `argo-up.sh`.

- [ ] **Step 1: Write the failing render assertion**

In `scripts/gitops-render-check.sh`, in the `for t in civo hetzner local; do` loop, directly after the `if [ "$t" != local ]; then extra_sets=(...) fi` block, add:

```bash
  # argo-up always passes these on hetzner; the template refuses to render without them.
  if [ "$t" = hetzner ]; then
    extra_sets+=(
      --set "capacity.autoscaler.locations=fsn1 nbg1 hel1"
      --set capacity.autoscaler.nodeType=cx33
      --set capacity.autoscaler.min=0
      --set capacity.autoscaler.max=1
      --set capacity.autoscaler.maxNodesTotal=3
    )
  fi
```

In `verify_object_set`, directly after the `for obj in $forbidden_objects; do ... done` loop and before `case "$target" in civo | hetzner | local)`, add:

```bash
  if [ "$target" = hetzner ]; then
    assert_helm_values "$target" cluster-autoscaler "$dir" \
      '.autoscalingGroups | length=3' \
      '.autoscalingGroups[0].name=workers-fsn1' \
      '.autoscalingGroups[1].name=workers-nbg1' \
      '.autoscalingGroups[2].region=HEL1' \
      '.autoscalingGroups[1].instanceType=CX33' \
      '.autoscalingGroups[2].minSize=0' \
      '.autoscalingGroups[2].maxSize=1' \
      '.expanderPriorities.30[0]=^workers-fsn1$' \
      '.expanderPriorities.10[0]=^workers-hel1$' \
      '.extraArgs.expander=priority' \
      '.extraArgs."max-nodes-total"=3' || return 1
  fi
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cd /Users/margo/Proj/Lab/vk-lab-platform-hetz176 && make gitops-check`
Expected: FAIL with `GITOPS-RENDER-CHECK: target=hetzner cluster-autoscaler .autoscalingGroups | length is '1', expected '3'`.

- [ ] **Step 3: Rewrite the autoscaler template**

In `gitops/templates/platform/hetzner/autoscaler/application.yaml`, replace line 1:

```yaml
{{- if eq .Values.target "hetzner" }}
```

with:

```yaml
{{- if eq .Values.target "hetzner" }}
{{- $locations := splitList " " (required "capacity.autoscaler.locations is set by argo-up" .Values.capacity.autoscaler.locations) }}
```

Replace the block from `# This group is separate from the fixed pool` through the `region:` line (lines 29-37) with:

```yaml
        # These groups are separate from the fixed pool, so their bounds are a
        # delta: argo-up passes 0 and MAX_WORKER_NODES - MIN_WORKER_NODES.
        # Civo's autoscaler owns the pool it created and takes absolutes.
        autoscalingGroups:
        {{- range $locations }}
          - name: workers-{{ . }}
            minSize: {{ $.Values.capacity.autoscaler.min }}
            maxSize: {{ $.Values.capacity.autoscaler.max }}
            instanceType: {{ $.Values.capacity.autoscaler.nodeType | upper | quote }}
            region: {{ . | upper | quote }}
        {{- end }}
        # One group per location so a stock-out in one is not a stock-out for
        # the cluster; the first location argo-up lists is tried first.
        expanderPriorities:
        {{- range $i, $location := $locations }}
          {{ mul (sub (len $locations) $i) 10 }}:
            - ^workers-{{ $location }}$
        {{- end }}
```

In `extraArgs`, after `scale-down-unneeded-time: 10m`, add:

```yaml
          expander: priority
          # Counts every node, the control plane and the fixed pool included.
          max-nodes-total: {{ required "capacity.autoscaler.maxNodesTotal is set by argo-up" .Values.capacity.autoscaler.maxNodesTotal | quote }}
```

- [ ] **Step 4: Rename the value in both values files**

`gitops/values.yaml`, in the `capacity.autoscaler` block: replace `location: ""` with:

```yaml
    locations: ""
    maxNodesTotal: ""
```

and in the comment above it change `The three below are` to `The five below are`.

`gitops/bootstrap/values.yaml`, in the `capacity.autoscaler` block: replace `location: ""` with:

```yaml
    locations: ""
    maxNodesTotal: ""
```

- [ ] **Step 5: Rename the root Application parameter**

In `gitops/bootstrap/templates/root-application.yaml`, replace:

```yaml
        - name: capacity.autoscaler.location
          value: {{ .Values.capacity.autoscaler.location | quote }}
```

with:

```yaml
        - name: capacity.autoscaler.locations
          value: {{ .Values.capacity.autoscaler.locations | quote }}
        - name: capacity.autoscaler.maxNodesTotal
          value: {{ .Values.capacity.autoscaler.maxNodesTotal | quote }}
```

- [ ] **Step 6: Run the render check**

Run: `make gitops-check`
Expected: the structural part passes (`civo, hetzner and local renders have the expected M1 object set.`), then FAIL on the aws golden diff for `bootstrap/Application__argocd__root.yaml`.

- [ ] **Step 7: Regenerate the aws golden and inspect the diff**

Run:
```bash
./scripts/gitops-render-check.sh update
git diff --stat tests/golden/
git diff tests/golden/
```
Expected: exactly one file changed, `tests/golden/gitops-aws/bootstrap/Application__argocd__root.yaml`; the only change is the parameter `capacity.autoscaler.location` replaced by `capacity.autoscaler.locations` plus a new `capacity.autoscaler.maxNodesTotal`, both with `value: ""`. Any other changed line is an AWS regression: stop and fix the template.

- [ ] **Step 8: Fix the CI hetzner render**

In `.github/workflows/lifecycle-test.yml`, replace the hetzner `helm template` block:

```yaml
          helm template gitops/ \
            --set target=hetzner \
            --set envoyGateway.fqdn=lab.example.com \
            --set envoyGateway.location=fsn1 \
            > rendered-hetzner.yaml
```

with:

```yaml
          helm template gitops/ \
            --set target=hetzner \
            --set envoyGateway.fqdn=lab.example.com \
            --set envoyGateway.location=fsn1 \
            --set "capacity.autoscaler.locations=fsn1 nbg1 hel1" \
            --set capacity.autoscaler.maxNodesTotal=3 \
            > rendered-hetzner.yaml
```

Run the same render locally to prove it: 
```bash
helm template gitops/ --set target=hetzner --set envoyGateway.fqdn=lab.example.com --set envoyGateway.location=fsn1 --set "capacity.autoscaler.locations=fsn1 nbg1 hel1" --set capacity.autoscaler.maxNodesTotal=3 >/dev/null && echo ok
```
Expected: `ok`.

- [ ] **Step 9: Run the checks**

Run: `make gitops-check && helm lint gitops/ && helm lint gitops/bootstrap`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add gitops scripts/gitops-render-check.sh tests/golden .github/workflows/lifecycle-test.yml
git commit -F - <<'EOF'
HETZ-176: one autoscaler group per location, priority expander, total cap

The hetzner autoscaler had one group pinned to one location, so a stock-out
there stopped all scale-up. It now renders a group per location from
capacity.autoscaler.locations, tried in list order, and caps the cluster at
maxNodesTotal. Both values are required, so a root that does not pass them
fails to render instead of rendering an empty group.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 2: argo-up builds one location list for groups and node configs

**Files:**
- Modify: `scripts/argo-up.sh:426-461` (`ensure_autoscaler_config`, new `hetzner_autoscaler_locations` above it), `:532-534` (call site), `:906-907` (root parameters)
- Test: `tests/scripts/autoscaler-config-test.sh`

**Interfaces:**
- Consumes: Task 1's values `capacity.autoscaler.locations`, `capacity.autoscaler.maxNodesTotal`; `catalog_regions` and `catalog_node_types` from `scripts/lib/catalog.sh` (already sourced through `provider.sh`).
- Produces: `hetzner_autoscaler_locations` (reads `REGION`, `WORKER_NODE_TYPE`; prints a space-separated list, `REGION` first); global `AUTOSCALER_LOCATIONS`; `ensure_autoscaler_config` now reads `AUTOSCALER_LOCATIONS` and writes `nodeConfigs` keyed `workers-<location>` plus the legacy `workers`. Part B replaces the body of `hetzner_autoscaler_locations` and drops `workers`.

- [ ] **Step 1: Write the failing test**

Replace `tests/scripts/autoscaler-config-test.sh` from the line `# Just the function, so sourcing argo-up.sh's top level never happens.` to the end of the file with:

```bash
# Just the functions, so sourcing argo-up.sh's top level never happens.
eval "$(awk '/^ensure_autoscaler_config\(\) \{/,/^\}/' "$REPO_ROOT/scripts/argo-up.sh")"
eval "$(awk '/^hetzner_autoscaler_locations\(\) \{/,/^\}/' "$REPO_ROOT/scripts/argo-up.sh")"
# shellcheck source=../../scripts/lib/catalog.sh
source "$REPO_ROOT/scripts/lib/catalog.sh"

# Reads no stdin. The first kubectl of the pipeline under test would otherwise
# read this script's own, which is the terminal when a person runs it by hand.
kubectl() {
  if [ "${1:-}" = "create" ]; then
    local a
    for a in "$@"; do
      case "$a" in
        --from-literal=HCLOUD_CLUSTER_CONFIG=*)
          printf '%s' "${a#--from-literal=HCLOUD_CLUSTER_CONFIG=}" > "$CAP" ;;
      esac
    done
  fi
  return 0
}

check() {
  local label="$1" filter="$2"
  if printf '%s' "$JSON" | jq -e "$filter" > /dev/null 2>&1; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    fails=$((fails + 1))
  fi
}

check_locations() {
  local label="$1" region="$2" type="$3" want="$4" got
  got="$(REGION="$region" WORKER_NODE_TYPE="$type" hetzner_autoscaler_locations)"
  if [ "$got" = "$want" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label: got '$got', want '$want'"
    fails=$((fails + 1))
  fi
}

check_locations "REGION first, then every location selling the type" fsn1 cx33 "fsn1 nbg1 hel1"
check_locations "a location that does not sell the type is left out" fsn1 cx43 "fsn1 nbg1"
check_locations "the REGION location leads whichever it is" hel1 cx33 "hel1 nbg1 fsn1"
check_locations "only the REGION location sells it" nbg1 cx53 "nbg1"

# Shaped like the real render: multi-line, with a tab inside a command, which
# is what would break a tab-delimited batch read.
WORKER_USER_DATA='#cloud-config
write_files:
  - path: /etc/netplan/60-private.yaml
    content: |
      network:
      	version: 2
runcmd:
  - curl -sfL https://get.k3s.io | K3S_TOKEN=join-token sh -s - agent'
# Exported because the function under test is eval'd, so shellcheck cannot see
# the read and reports each one unused.
export HCLOUD_NODE_IMAGE=ubuntu-24.04
export HCLOUD_SUBNET_IP_RANGE=10.0.1.0/24
export PROJECT_NAME=vk-hetzner-lab
export AUTOSCALER_LOCATIONS="fsn1 nbg1 hel1"

ensure_autoscaler_config
JSON="$(base64 -d < "$CAP")"

check "one node config per --nodes group, plus the old single group" \
  '.nodeConfigs | keys == ["workers","workers-fsn1","workers-hel1","workers-nbg1"]'
check "all five serverLabels are present in every group" \
  '[.nodeConfigs[].serverLabels | keys] | unique == [["lifecycle","managed_by","project","role","scope"]]'
check "project=<project>      - firewall selector and teardown sweep" \
  '[.nodeConfigs[].serverLabels.project] | unique == ["vk-hetzner-lab"]'
check "scope=platform         - firewall selector" \
  '[.nodeConfigs[].serverLabels.scope] | unique == ["platform"]'
check "managed_by=autoscaler  - teardown sweep" \
  '[.nodeConfigs[].serverLabels.managed_by] | unique == ["autoscaler"]'
check "lifecycle=disposable   - failure diagnostics" \
  '[.nodeConfigs[].serverLabels.lifecycle] | unique == ["disposable"]'
check "the subnet is stated rather than left to the hcloud default" \
  '.defaultSubnetIPRange == "10.0.1.0/24"'
check "both architectures name the fixed pool's image" \
  '.imagesForArch == {amd64: "ubuntu-24.04", arm64: "ubuntu-24.04"}'

DECODED="$(printf '%s' "$JSON" | jq -r '.nodeConfigs["workers-nbg1"].cloudInit' | base64 -d)"
if [ "$DECODED" = "$WORKER_USER_DATA" ]; then
  echo "ok   the cloud-init round-trips byte-identical, newlines and tab intact"
else
  echo "FAIL the cloud-init does not round-trip - it is encoded twice, or truncated"
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "autoscaler-config-test: $fails case(s) failed" >&2
  exit 1
fi
echo "autoscaler-config-test: all 13 cases passed"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bash tests/scripts/autoscaler-config-test.sh`
Expected: FAIL. The four `check_locations` cases fail (`hetzner_autoscaler_locations: command not found`) and `one node config per --nodes group` fails (keys are `["workers"]`); exit code 1.

- [ ] **Step 3: Add the location list function**

In `scripts/argo-up.sh`, directly above the comment block that starts `# The node template is Terraform's own worker render`, add:

```bash
# One autoscaler group per location that sells the worker type, REGION first:
# the expander tries them in this order, so a stock-out in one is not fatal.
hetzner_autoscaler_locations() {
  local location others=()
  for location in $(catalog_regions hetzner); do
    [ "$location" = "$REGION" ] && continue
    case " $(catalog_node_types hetzner "$location") " in
      *" $WORKER_NODE_TYPE "*) others+=("$location") ;;
    esac
  done
  echo "$REGION${others[*]:+ ${others[*]}}"
}
```

- [ ] **Step 4: Key the node configs by location**

In `ensure_autoscaler_config`, replace the `jq -cn` call (from `config="$(jq -cn \` through `}' | base64 | tr -d '\n')"`) with:

```bash
  config="$(jq -cn \
    --arg image "$HCLOUD_NODE_IMAGE" \
    --arg subnet "$HCLOUD_SUBNET_IP_RANGE" \
    --arg cloudInit "$cloud_init" \
    --arg project "$PROJECT_NAME" \
    --arg locations "$AUTOSCALER_LOCATIONS" \
    '{
      imagesForArch: {amd64: $image, arm64: $image},
      defaultSubnetIPRange: $subnet,
      nodeConfigs: (($locations | split(" ") | map("workers-" + .)) + ["workers"] | map({
        key: .,
        value: {
          cloudInit: $cloudInit,
          serverLabels: {
            project: $project,
            scope: "platform",
            lifecycle: "disposable",
            managed_by: "autoscaler",
            role: "worker"
          }
        }
      }) | from_entries)
    }' | base64 | tr -d '\n')"
```

In the comment block above the function, after the line `# cannot drift from the fixed pool: same k3s version, same flags, same token.`, add:

```bash
# Keyed from the same list as the --nodes groups: a group with no key here
# makes the autoscaler exit at start. "workers" stays for a root that still
# runs the single group; extra keys are ignored.
```

- [ ] **Step 5: Set the list at the call site**

Replace:

```bash
if [ "$PROVIDER" = hetzner ]; then
  ensure_autoscaler_config
fi
```

with:

```bash
if [ "$PROVIDER" = hetzner ]; then
  AUTOSCALER_LOCATIONS="$(hetzner_autoscaler_locations)"
  ensure_autoscaler_config
fi
```

- [ ] **Step 6: Pass the list and the cap to the root Application**

In `hetzner_install_root_application`, replace:

```bash
    --set capacity.autoscaler.location="$REGION" \
```

with:

```bash
    --set capacity.autoscaler.locations="$AUTOSCALER_LOCATIONS" \
    --set capacity.autoscaler.maxNodesTotal=$(( 1 + MAX_WORKER_NODES )) \
```

- [ ] **Step 7: Run the test and the script checks**

Run:
```bash
bash tests/scripts/autoscaler-config-test.sh
make scripts-check
```
Expected: `autoscaler-config-test: all 13 cases passed`; `scripts-check` passes (shellcheck clean, every `tests/scripts/*-test.sh` green).

- [ ] **Step 8: Commit**

```bash
git add scripts/argo-up.sh tests/scripts/autoscaler-config-test.sh
git commit -F - <<'EOF'
HETZ-176: argo-up builds one location list for groups and node configs

hetzner_autoscaler_locations lists REGION, then every other catalog location
that sells the worker type. The same list becomes the root's
capacity.autoscaler.locations and the Secret's nodeConfigs keys, because a
--nodes group with no matching key makes the autoscaler exit at start. The
old "workers" key stays, so a root not yet reinstalled keeps working.
The cap is 1 + MAX_WORKER_NODES: max-nodes-total counts every node.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

---

### Task 3: Spec to IN_PROGRESS and open PR 1

**Files:**
- Rename: `specs/hetzner/176-P-zone-wide-placement/` → `specs/hetzner/176-A-zone-wide-placement/`
- Modify: `specs/hetzner/176-A-zone-wide-placement/spec.md` (front matter, §14)
- Modify: `specs/hetzner/README.md:112`

**Interfaces:**
- Consumes: Tasks 1–2 committed.
- Produces: an open pull request with label `ci:lifecycle-hetzner`.

- [ ] **Step 1: Move the spec folder and status**

```bash
git mv specs/hetzner/176-P-zone-wide-placement specs/hetzner/176-A-zone-wide-placement
grep -rln '176-P-zone-wide-placement' . --exclude-dir=.git
```

Replace every hit from the grep with `176-A-zone-wide-placement` (expected: `specs/hetzner/README.md`). In `specs/hetzner/README.md`, change the HETZ-176 row's status cell from `READY` to `IN_PROGRESS`.

In the spec front matter set `status: "IN_PROGRESS"` and `updated: "2026-11-23"` (or today's date). Append to §14:

```markdown
- <date> — Part A implemented (PR 1): one autoscaler group per location,
  priority expander, `max-nodes-total = 1 + MAX_WORKER_NODES`. Evidence:
  `make gitops-check` (hetzner asserts), `autoscaler-config-test.sh` 13/13.
  Outstanding: AC3 live check after the merge (§11 PR 1 steps 4–5).
```

- [ ] **Step 2: Run the full fast validation**

Run: `make specs-check && make gitops-check && make scripts-check`
Expected: all three pass.

- [ ] **Step 3: Commit**

```bash
git add -A specs
git commit -F - <<'EOF'
HETZ-176: spec IN_PROGRESS — part A implemented

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

- [ ] **Step 4: Push and open the PR without a lifecycle label**

```bash
git push -u origin hetz-176-zone-placement
gh pr create --title "HETZ-176 part A: autoscaler group per location" --label ci:skip-lifecycle --body-file - <<'EOF'
## What

The Hetzner autoscaler gets one node group per location that sells the worker
type (`workers-fsn1`, `workers-nbg1`, `workers-hel1`), tried in that order by
the priority expander, with `max-nodes-total = 1 + MAX_WORKER_NODES`.

## Why

On 2026-11-23 fsn1 refused `cx33` and `cx43` while the only worker sat at 88%
memory; the single fsn1 group could not add capacity.

## Spec

`specs/hetzner/176-A-zone-wide-placement/spec.md` — part A; part B follows in
a second PR, so the spec stays IN_PROGRESS.

## Live check (after merge)

The live root fails to render once this merges (the new values are required),
which takes argo-up off its fast path:
`PROJECT_NAME=vk-hetzner-lab WORKER_NODE_TYPE=cx33 make argo-up`.
A re-run before that takes the fast path: it rewrites the autoscaler Secret
but not the root parameters. The Secret keeps the old `workers` key, so that
is harmless.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01GiCsYKAgwEUe6VjvFBJRpg
EOF
```

- [ ] **Step 5: Swap to the lifecycle label in one edit**

Never add the lifecycle label at create time (the first run self-cancels).

```bash
gh pr edit --remove-label ci:skip-lifecycle --add-label ci:lifecycle-hetzner
```

If the first lifecycle run shows as cancelled, run `gh run rerun <run-id>`. If it fails on a server create with `resource_unavailable`, that is stock, not this change: rerun later.

---

### Task 4: Live check after the merge (operator runs, with Claude)

**Files:** none. Record results in the spec's §14 in PR 2.

- [ ] **Step 1: Before merging, confirm no autoscaled server exists**

```bash
export AWS_PROFILE=viacheslav-dev
hcloud server list -l managed_by=autoscaler
```
Expected: an empty table. If a server is listed, wait for it to scale down (10 min unneeded) before merging; it belongs to the old `workers` group, which no new group owns.

- [ ] **Step 2: Merge PR 1, then confirm the root left Synced/Healthy (hard gate)**

Do Steps 2 and 3 back to back: the live root stays in `ComparisonError` until Step 3.

```bash
cd /Users/margo/Proj/Lab/vk-lab-platform-hetz176 && git fetch origin && git checkout --detach origin/main
PROJECT_NAME=vk-hetzner-lab make kubeconfig
kubectl --kubeconfig .kube/vk-hetzner-lab.config get application root -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
```
Expected (within about 3 minutes of the merge): anything except `Synced/Healthy` (a `ComparisonError` naming `capacity.autoscaler.locations`). If it still reads `Synced/Healthy`, run `kubectl --kubeconfig .kube/vk-hetzner-lab.config -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite` and check again. Do not run Step 3 while it reads `Synced/Healthy`: argo-up would take its fast path and leave the root parameters unchanged.

- [ ] **Step 3: Install the root with the new parameters**

```bash
PROJECT_NAME=vk-hetzner-lab WORKER_NODE_TYPE=cx33 make argo-up
```
Expected: argo-up does not print `root Application already Synced/Healthy`; it ends with the root Synced/Healthy.

- [ ] **Step 4: Check AC3**

```bash
K="kubectl --kubeconfig .kube/vk-hetzner-lab.config"
$K -n kube-system get deploy -l app.kubernetes.io/name=hetzner-cluster-autoscaler -o yaml | grep -E -- '--(nodes|expander|max-nodes-total)'
$K -n kube-system get configmap cluster-autoscaler-priority-expander -o yaml | grep -A8 'priorities'
$K -n kube-system logs deploy/cluster-autoscaler-hetzner-cluster-autoscaler --tail=50 | grep -iE 'fatal|node group|error' || true
```
Expected: three `--nodes=0:1:CX33:<LOC>:workers-<loc>` lines (fsn1, nbg1, hel1), `--expander=priority`, `--max-nodes-total=3`; the ConfigMap lists `30: [^workers-fsn1$]`, `20: [^workers-nbg1$]`, `10: [^workers-hel1$]`; no `Fatal` in the log. If the label selector or Deployment name differs, list with `$K -n kube-system get deploy | grep autoscaler` and use that name.

- [ ] **Step 5: Record the evidence**

Paste the three outputs into a note for PR 2's §14 entry (AC3 met for part A).
