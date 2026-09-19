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
  done < <(sed 's/`[^`]*`//g' "$f" | grep -o '\]([^)#[:space:]]*' | sed 's/^](//')
done < <(find specs -name '*.md')

# .claude holds other sessions' worktrees - checkouts of other branches, whose
# stale paths say nothing about this working tree.
stale=$(grep -rInE 'specs/((aws|civo|hetzner|local|shared)/)?[0-9]{3}(-[0-9]+)?-[a-z]' . \
  --exclude-dir=.git --exclude-dir=superpowers --exclude-dir=.superpowers --exclude-dir=.terraform \
  --exclude-dir=.terragrunt-cache --exclude-dir=node_modules --exclude-dir=evidence \
  --exclude-dir=.claude || true)
if [[ -n "$stale" ]]; then
  err "pre-reorg spec paths remain:"
  printf '%s\n' "$stale" >&2
fi

# A status change renames the folder, so every lettered path must still exist.
while IFS= read -r p; do
  [[ -e "$p" ]] || err "path to a missing spec folder: $p"
done < <(grep -rIohE 'specs/[a-z]+/[0-9]{3}(-[0-9]+)?-[DAPZ]-[a-z0-9-]+' . \
  --exclude-dir=.git --exclude-dir=superpowers --exclude-dir=.superpowers --exclude-dir=.terraform \
  --exclude-dir=.terragrunt-cache --exclude-dir=node_modules --exclude-dir=evidence \
  --exclude-dir=.claude | sort -u)

if [[ $fail -eq 0 ]]; then echo "SPECS-CHECK: specs/ layout is valid."; fi
exit $fail
