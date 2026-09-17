# Specs Reorg Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every spec into `specs/{aws,civo,hetzner,local,shared}/` with a status letter in each folder name, and keep all path references valid.

**Architecture:** A committed check script defines "done" (letters match `status:`, links resolve, no old paths). Two throwaway Python scripts in the session scratchpad do the bulk work: one moves folders and adds front matter, one rewrites path references from the rename map. Protocol docs are edited by hand.

**Tech Stack:** bash 3.2 (macOS), python3, grep/sed, Markdown.

**Spec:** `docs/superpowers/specs/2026-09-17-specs-reorg-design.md`

## Global Constraints

- Folder name: `NNN-X-name`; `X` in `D|A|P|Z`. `NNN` may carry a sub-number (`006-1`).
- Letters: `D`=DONE; `A`=IN_PROGRESS, IN_REVIEW; `P`=DRAFT, READY, BLOCKED; `Z`=DEFERRED, SUPERSEDED, CANCELLED.
- New front matter for aws/shared/local: `id` (`AWS-NNN`, `SHARED-NNN`, `LOCAL-NNN`, from the folder number), `status`, `updated: "2026-09-17"`.
- `**Status:** <text>` becomes `**Status note:** <text>`. No other body edits: no dependency, title or requirement changes.
- civo and hetzner front matter is not changed.
- Do not edit `docs/superpowers/plans/` or prose IDs ("spec 025", `CIVO-070`).
- Use plain `mv`, not `git mv`. The worktree guard blocks complex git commands and commands that invoke `bash`/`make gitops-*` by name; run scripts as `./path`.
- Comments in code: at most 3 lines, only where needed, no doc references.

## Scratchpad

`SP=/private/tmp/claude-504/-Users-margo-Proj-Lab-vk-lab-platform/760f909b-0262-48b2-b235-c4ac11565e25/scratchpad`

---

### Task 1: Check script (fails on the current layout)

**Files:**
- Create: `scripts/specs-check.sh`
- Modify: `Makefile` (add `specs-check` next to `gitops-check`)

**Interfaces:**
- Produces: `./scripts/specs-check.sh` — exit 0 when the layout is valid; otherwise prints `SPECS-CHECK: <problem>` lines to stderr and exits 1.

- [x] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Validates specs/ layout: package folders, NNN-X-name letters vs front-matter
# status, relative Markdown links, and leftover pre-reorg spec paths.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
err() { echo "SPECS-CHECK: $*" >&2; fail=1; }

letter_for() {
  case "$1" in
    DONE) echo D ;;
    IN_PROGRESS|IN_REVIEW) echo A ;;
    DRAFT|READY|BLOCKED) echo P ;;
    DEFERRED|SUPERSEDED|CANCELLED) echo Z ;;
    *) echo "?" ;;
  esac
}

for entry in specs/*; do
  name=$(basename "$entry")
  if [[ -d "$entry" ]]; then
    case "$name" in aws|civo|hetzner|local|shared) ;; *) err "unexpected folder $entry" ;; esac
  elif [[ "$name" != "README.md" ]]; then
    err "unexpected file $entry"
  fi
done

for d in specs/*/[0-9]*; do
  [[ -d "$d" ]] || continue
  name=$(basename "$d")
  if [[ ! "$name" =~ ^[0-9]{3}(-[0-9]+)?-([DAPZ])-[a-z0-9-]+$ ]]; then
    err "$d: name is not NNN-X-name"
    continue
  fi
  letter=${BASH_REMATCH[2]}
  f="$d/spec.md"
  if [[ ! -f "$f" ]]; then err "$d: no spec.md"; continue; fi
  if [[ "$(head -1 "$f")" != "---" ]]; then err "$f: no front matter"; continue; fi
  fm=$(awk 'NR==1{next} /^---$/{exit} {print}' "$f")
  id=$(printf '%s\n' "$fm" | sed -n 's/^id: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p')
  status=$(printf '%s\n' "$fm" | sed -n 's/^status: *"\{0,1\}\([A-Z_]*\)"\{0,1\} *$/\1/p')
  [[ -n "$id" ]] || err "$f: front matter has no id"
  want=$(letter_for "$status")
  [[ "$want" == "$letter" ]] || err "$d: letter $letter does not match status '${status}'"
done

while IFS= read -r f; do
  dir=$(dirname "$f")
  while IFS= read -r target; do
    case "$target" in ''|http://*|https://*|mailto:*) continue ;; esac
    [[ -e "$dir/$target" ]] || err "$f: broken link ($target)"
  done < <(grep -o '\]([^)#[:space:]]*' "$f" | sed 's/^](//')
done < <(find specs -name '*.md')

stale=$(grep -rInE 'specs/((aws|civo|hetzner|local|shared)/)?[0-9]{3}(-[0-9]+)?-[a-z]' . \
  --exclude-dir=.git --exclude-dir=superpowers --exclude-dir=.terraform \
  --exclude-dir=.terragrunt-cache --exclude-dir=node_modules --exclude-dir=evidence || true)
if [[ -n "$stale" ]]; then
  err "pre-reorg spec paths remain:"
  printf '%s\n' "$stale" >&2
fi

if [[ $fail -eq 0 ]]; then echo "SPECS-CHECK: specs/ layout is valid."; fi
exit $fail
```

The `evidence/` folder holds captured command output and is excluded.

- [x] **Step 2: Make it executable and add the Make target**

```bash
chmod +x scripts/specs-check.sh
```

Makefile, after the `gitops-check` target:

```make
specs-check:
	@./scripts/specs-check.sh
```

- [x] **Step 3: Run it, expect FAIL**

Run: `./scripts/specs-check.sh; echo EXIT=$?`
Expected: `unexpected folder specs/000-constitution` (and similar), `no front matter`, stale path lines, `EXIT=1`.

- [x] **Step 4: Commit**

```bash
git add scripts/specs-check.sh Makefile
git commit -m "feat(specs-reorg): add specs layout check"
```

---

### Task 2: Move folders and add front matter

**Files:**
- Create (not committed): `$SP/reorg.py`, output `$SP/rename-map.json`
- Move: all 94 spec folders
- Modify: `spec.md` of the 37 aws/shared/local specs (front matter + status note)

**Interfaces:**
- Consumes: nothing.
- Produces: `$SP/rename-map.json` — object `{ "specs/<old>": "specs/<pkg>/<new>" }` for every moved folder, used by Task 3.

- [x] **Step 1: Write `$SP/reorg.py`**

```python
#!/usr/bin/env python3
import json, os, re, sys

ROOT = "/Users/margo/Proj/Lab/vk-lab-platform/.claude/worktrees/feature+refactoring"
SP = os.path.dirname(os.path.abspath(__file__))
LETTER = {"DONE": "D", "IN_PROGRESS": "A", "IN_REVIEW": "A", "DRAFT": "P",
          "READY": "P", "BLOCKED": "P", "DEFERRED": "Z", "SUPERSEDED": "Z",
          "CANCELLED": "Z"}
PREFIX = {"aws": "AWS", "shared": "SHARED", "local": "LOCAL"}
TOP = {
    "000-constitution": ("shared", "DONE"),
    "001-bootstrap": ("aws", "DONE"),
    "002-persistent-foundation": ("aws", "DONE"),
    "003-network-and-eks": ("aws", "DONE"),
    "004-argocd-bootstrap": ("aws", "DONE"),
    "005-storage-contract": ("aws", "DONE"),
    "006-karpenter": ("aws", "DONE"),
    "006-1-karpenter-node-lifecycle": ("aws", "DONE"),
    "007-postgres": ("aws", "DONE"),
    "007-1-postgres-persistence-recovery": ("aws", "DONE"),
    "007-2-secrets-for-postgres": ("aws", "DONE"),
    "009-observability": ("aws", "DONE"),
    "010-envoy-gateway": ("aws", "DONE"),
    "011-nlb-edge": ("aws", "DONE"),
    "012-external-dns": ("aws", "DONE"),
    "013-secrets": ("aws", "DONE"),
    "014-lifecycle": ("aws", "DONE"),
    "015-github-oidc-bootstrap": ("aws", "DONE"),
    "016-github-actions-lifecycle": ("aws", "DONE"),
    "017-branch-protection": ("shared", "READY"),
    "018-atlantis-terraform-automation": ("aws", "READY"),
    "019-ci-fast-validation": ("shared", "READY"),
    "020-ci-full-lifecycle-validation": ("aws", "IN_PROGRESS"),
    "021-vpc": ("aws", "DONE"),
    "022-local-dev-mode": ("local", "READY"),
    "023-e2e-test-framework": ("shared", "DONE"),
    "024-ci-kind-integration-test": ("local", "READY"),
    "025-kafka": ("aws", "DEFERRED"),
    "026-debezium": ("aws", "READY"),
    "027-alt-cloud-targets": ("shared", "SUPERSEDED"),
    "028-pod-density-ipv6": ("aws", "READY"),
    "029-tracing-otel": ("aws", "DEFERRED"),
    "030-cluster-status-badge": ("aws", "READY"),
    "031-non-home-region-cluster": ("aws", "DEFERRED"),
    "032-argo-bootstrap-resilience": ("aws", "DONE"),
    "033-lbc-webhook-cert-churn": ("aws", "IN_PROGRESS"),
    "034-github-secrets": ("shared", "READY"),
}
NUM = re.compile(r"^(\d{3}(?:-\d+)?)-(.+)$")


def lettered(name, status):
    num, rest = NUM.match(name).groups()
    return num, f"{num}-{LETTER[status]}-{rest}"


def plan():
    moves = []
    for name, (pkg, status) in TOP.items():
        num, new = lettered(name, status)
        moves.append((f"specs/{name}", f"specs/{pkg}/{new}", pkg, num, status))
    for pkg in ("civo", "hetzner"):
        for name in sorted(os.listdir(f"{ROOT}/specs/{pkg}")):
            if not NUM.match(name):
                continue
            text = open(f"{ROOT}/specs/{pkg}/{name}/spec.md").read()
            status = re.search(r'^status:\s*"?([A-Z_]+)"?', text, re.M).group(1)
            _, new = lettered(name, status)
            moves.append((f"specs/{pkg}/{name}", f"specs/{pkg}/{new}", pkg, None, status))
    return moves


def add_front_matter(path, pkg, num, status):
    text = open(path).read()
    assert not text.startswith("---"), path
    text = text.replace("**Status:**", "**Status note:**", 1)
    text = text.replace("> **Status: ", "> **Status note: ", 1)
    fm = f'---\nid: "{PREFIX[pkg]}-{num}"\nstatus: "{status}"\nupdated: "2026-09-17"\n---\n'
    open(path, "w").write(fm + text)


def main():
    only_first = sys.argv[1:] == ["one"]
    moves = plan()
    assert len(moves) == 94, len(moves)
    if only_first:
        moves = moves[:1]
    for pkg in PREFIX:
        os.makedirs(f"{ROOT}/specs/{pkg}", exist_ok=True)
    done = {}
    for old, new, pkg, num, status in moves:
        if not os.path.isdir(f"{ROOT}/{old}"):
            continue
        os.rename(f"{ROOT}/{old}", f"{ROOT}/{new}")
        if pkg in PREFIX:
            add_front_matter(f"{ROOT}/{new}/spec.md", pkg, num, status)
        done[old] = new
    mp = f"{SP}/rename-map.json"
    prev = json.load(open(mp)) if os.path.exists(mp) else {}
    prev.update(done)
    json.dump(prev, open(mp, "w"), indent=1, sort_keys=True)
    print(f"moved {len(done)}; map has {len(prev)}")


main()
```

`os.rename` is a plain move, equal to `mv`.

- [x] **Step 2: Move one folder, confirm git sees a rename**

Run: `chmod +x $SP/reorg.py && $SP/reorg.py one`
Expected: `moved 1; map has 1` (`specs/000-constitution` → `specs/shared/000-D-constitution`).

Run: `git add -A specs && git status --short specs`
Expected: one `R` line for `spec.md`. If git shows `D` + `A`, stop: the front-matter edit dropped similarity below 50%. (The constitution file is large; the edit adds 5 lines.)

- [x] **Step 3: Move the rest**

Run: `$SP/reorg.py`
Expected: `moved 93; map has 94`.

Run: `ls specs specs/aws specs/shared specs/local | head -60`
Expected: only `aws civo hetzner local shared` at the top level; lettered names below.

- [x] **Step 4: Spot-check headers**

Run: `head -8 specs/aws/025-Z-kafka/spec.md specs/aws/032-D-argo-bootstrap-resilience/spec.md specs/shared/000-D-constitution/spec.md`
Expected: front matter with `AWS-025`/`DEFERRED`, `AWS-032`/`DONE`, `SHARED-000`/`DONE`; `> **Status note: Deferred ...` and `**Status note:** Proposed` lines.

- [x] **Step 5: Run the check, expect only link and stale-path failures**

Run: `./scripts/specs-check.sh 2>&1 | grep 'SPECS-CHECK'`
Expected: only `broken link` and `pre-reorg spec paths remain` lines; no `unexpected folder`, `name is not`, `no front matter`, or `does not match` lines.

- [x] **Step 6: Commit**

```bash
git add -A specs
git status --short
git commit -m "refactor(specs): move specs into per-target folders with status letters"
```

Expected before commit: only `M`/`R` lines for `spec.md` files in specs.

---

### Task 3: Rewrite path references

**Files:**
- Create (not committed): `$SP/refs.py`
- Modify: `CLAUDE.md`, `README.md`, `docs/architecture.md`, `docs/argocd-design.md`, `docs/architecture-review-2026-09-06.md`, `docs/civo-high-level-design.md`, `docs/hetzner-high-level-design.md`, `docs/adr/0001*`, `0002*`, `0014*`, `0017*`, `0026*`, `0027*`, `0032*`, `terraform/live/cluster/README.md`, `tests/manual/024-kafka.md`, spec files with `specs/...` paths, `specs/civo/README.md`, `specs/hetzner/README.md`, `specs/shared/027-Z-alt-cloud-targets/spec.md`

**Interfaces:**
- Consumes: `$SP/rename-map.json` from Task 2.

- [x] **Step 1: Write `$SP/refs.py`**

```python
#!/usr/bin/env python3
import json, os, re

ROOT = "/Users/margo/Proj/Lab/vk-lab-platform/.claude/worktrees/feature+refactoring"
SP = os.path.dirname(os.path.abspath(__file__))
SKIP_DIRS = {".git", "superpowers", ".terraform", ".terragrunt-cache", "node_modules", "evidence"}
TEXT_EXT = {".md", ".sh", ".yaml", ".yml", ".tf", ".hcl", ".go", ".txt", ""}

m = json.load(open(f"{SP}/rename-map.json"))
m["specs/024-kafka"] = m["specs/025-kafka"]
paths = sorted(m, key=len, reverse=True)
path_re = re.compile("(" + "|".join(re.escape(p) for p in paths) + r")(?![A-Za-z0-9-])")

# In-package index links: "[010-name](010-name/spec.md)" -> lettered names.
local = {}
for old, new in m.items():
    parts = old.split("/")
    if len(parts) == 3:
        local[(parts[1], parts[2])] = new.split("/")[2]

changed = []
for dirpath, dirs, files in os.walk(ROOT):
    dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
    for fn in files:
        if os.path.splitext(fn)[1] not in TEXT_EXT:
            continue
        p = os.path.join(dirpath, fn)
        try:
            text = open(p).read()
        except (UnicodeDecodeError, OSError):
            continue
        new = path_re.sub(lambda x: m[x.group(1)], text)
        rel = os.path.relpath(p, ROOT)
        if rel in ("specs/civo/README.md", "specs/hetzner/README.md"):
            pkg = rel.split("/")[1]
            for (k_pkg, old_name), new_name in local.items():
                if k_pkg == pkg:
                    new = new.replace(f"[{old_name}]({old_name}/", f"[{new_name}]({new_name}/")
        if new != text:
            open(p, "w").write(new)
            changed.append(rel)
print("\n".join(sorted(changed)))
print(f"changed {len(changed)} files")
```

- [x] **Step 2: Run it**

Run: `chmod +x $SP/refs.py && $SP/refs.py`
Expected: a list including `CLAUDE.md`, `README.md`, ADR files, `specs/civo/README.md`, `specs/hetzner/README.md`; no path under `docs/superpowers/`.

- [x] **Step 3: Fix the moved relative link in 027**

In `specs/shared/027-Z-alt-cloud-targets/spec.md`, change `](../civo/README.md)` to `](../../civo/README.md)`.

- [x] **Step 4: Run the check**

Run: `./scripts/specs-check.sh; echo EXIT=$?`
Expected: `SPECS-CHECK: specs/ layout is valid.` and `EXIT=0`. Fix any remaining hit by hand (for example a path the map does not cover), then run again.

- [x] **Step 5: Review the diff for wrong replacements**

Run: `git diff --stat` and `git diff -- CLAUDE.md docs/adr README.md`
Expected: only `specs/...` path substrings changed.

- [x] **Step 6: Commit**

```bash
git add -A
git commit -m "docs(specs): point references at the reorganized spec paths"
```

---

### Task 4: Protocol docs

**Files:**
- Create: `specs/README.md`
- Modify: `specs/civo/README.md` (Format note, Status protocol table), `specs/hetzner/README.md` (Format note), `CLAUDE.md` (repository layout `specs/` entry), `docs/architecture.md` (layout tree near the `specs/` entry)

- [x] **Step 1: Write `specs/README.md`**

```markdown
# Specs

Specs are grouped by execution target. Each spec is a folder with a `spec.md`.

| Folder | Holds | `id` prefix |
|---|---|---|
| `aws/` | AWS/EKS target specs | `AWS-` |
| `civo/` | Civo target package (see its README) | `CIVO-` |
| `hetzner/` | Hetzner target package (see its README) | `HETZ-` |
| `local/` | `local` (minikube/kind) target specs | `LOCAL-` |
| `shared/` | Specs that apply to every target, including the constitution | `SHARED-` |

## Folder name

`NNN-X-name`, for example `aws/025-Z-kafka`.

- `NNN` (with an optional sub-number such as `006-1`) and the front-matter
  `id` are the stable identifiers. Never renumber them.
- `X` is the status letter. When `status:` changes, rename the folder in the
  same commit and update links to it.

## Status letters

| Letter | Meaning | `status:` values |
|---|---|---|
| `D` | done | `DONE` |
| `A` | active | `IN_PROGRESS`, `IN_REVIEW` |
| `P` | planned | `DRAFT`, `READY`, `BLOCKED` |
| `Z` | closed, not done | `DEFERRED`, `SUPERSEDED`, `CANCELLED` |

The front-matter `status:` is the source of truth; the letter is a coarse view
of it. Status meanings are in `civo/README.md` (Status protocol).

Run `make specs-check` after any spec move or status change.
```

- [x] **Step 2: Edit `specs/civo/README.md`**

Replace the Format note sentences

```
bold-label headers. The folder name (`NNN-title`) and the `id` field are the
stable identifiers. Never renumber them. Numbers step by ten. Insert later
work into the gaps (`085-...`) without renumbering.
```

with

```
bold-label headers. The folder name is `NNN-X-title`, where `X` is the status
letter (see `../README.md`). The number and the `id` field are the stable
identifiers. Never renumber them. Numbers step by ten. Insert later work into
the gaps (`085-...`) without renumbering.
```

The first sentence's "Other specs in `specs/` use Markdown bold-label headers" is now false: change it to "Specs in `aws/`, `local/` and `shared/` use short front matter (`id`, `status`, `updated`) and Markdown bold-label headers."

In the Status protocol table, change the `CANCELLED` row and add two rows after it:

```
| `DEFERRED` | Postponed by a recorded decision; may return to `READY` |
| `SUPERSEDED` | Replaced by another spec or ADR; the replacement is named |
| `CANCELLED` | Abandoned; rationale kept |
```

Add below the table: "Each status maps to a folder letter; see `../README.md`."

- [x] **Step 3: Edit `specs/hetzner/README.md` Format note**

Replace

```
`specs/civo/`. The folder name (`NNN-title`) and the `id` field are the
stable identifiers. Never renumber them.
```

with

```
`specs/civo/`. The folder name is `NNN-X-title`, where `X` is the status
letter (see `../README.md`). The number and the `id` field are the stable
identifiers. Never renumber them.
```

- [x] **Step 4: Edit `CLAUDE.md` and `docs/architecture.md` layout entries**

Find with `grep -n '^`specs/`' CLAUDE.md` and `grep -n 'specs/' docs/architecture.md | head`. In CLAUDE.md, change the `specs/` entry's description to:

```
`specs/`
Spec-driven-development requirements, one folder per target (`aws/`, `civo/`,
`hetzner/`, `local/`, `shared/`). Folder names carry a status letter; see
`specs/README.md`.
```

In the `docs/architecture.md` layout tree, replace the `specs/` subtree lines with `aws/`, `civo/`, `hetzner/`, `local/`, `shared/` entries in the same tree style.

- [x] **Step 5: Verify**

Run: `./scripts/specs-check.sh; echo EXIT=$?`
Expected: valid, `EXIT=0`.

Run: `./scripts/gitops-render-check.sh check`
Expected: both GITOPS-RENDER-CHECK pass lines (no gitops file changed; confirms no collateral).

- [x] **Step 6: Commit**

```bash
git add specs/README.md specs/civo/README.md specs/hetzner/README.md CLAUDE.md docs/architecture.md
git commit -m "docs(specs): document per-target layout and status letters"
```

---

### Task 5: Final verification

- [x] **Step 1:** `./scripts/specs-check.sh` → valid.
- [x] **Step 2:** `git log --stat -4 --oneline | head -40` → 4 commits; the move commit shows renames.
- [x] **Step 3:** Break a letter on purpose to prove check 3 works: `mv specs/aws/025-Z-kafka specs/aws/025-D-kafka && ./scripts/specs-check.sh; mv specs/aws/025-D-kafka specs/aws/025-Z-kafka` → the first run reports `letter D does not match status 'DEFERRED'`.
- [x] **Step 4:** Mark this plan's checkboxes done and commit.
