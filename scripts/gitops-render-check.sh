#!/usr/bin/env bash
# Renders gitops/ (path=gitops) and gitops/bootstrap/ with target=aws, once
# plain and once with postgres.recoverySnapshotHandle set, and compares a
# normalized, kind/name-sorted form of the output against the committed
# baseline under tests/golden/gitops-aws/. Helm's own document order and
# `# Source:` comments are not part of Argo's contract (it tracks resources
# by group/kind/name/namespace, not file location - spec CIVO-050 S3), so
# both are stripped before the diff to avoid false positives on a pure move.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOLDEN_DIR="$REPO_ROOT/tests/golden/gitops-aws"
MODE="${1:-check}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Splits a multi-document `helm template` stream into one normalized file
# per rendered object, named by kind/namespace/name so the same object
# always lands at the same path regardless of which source file rendered
# it or what order Helm emitted it in.
render_and_normalize() {
  local chart_dir="$1" out_dir="$2"; shift 2
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  local raw="$WORK_DIR/raw-$$-$RANDOM.yaml"
  helm template "$chart_dir" --set target=aws "$@" > "$raw"

  awk -v out_dir="$out_dir" '
    /^---$/ { n++; file=sprintf("%s/doc-%03d.yaml", out_dir, n); next }
    /^# Source:/ { next }
    { if (n > 0) print > file }
  ' "$raw"

  local f kind ns name
  for f in "$out_dir"/doc-*.yaml; do
    [ -e "$f" ] || continue
    if [ ! -s "$f" ] || [ "$(yq 'select(. != null)' "$f")" = "" ]; then
      rm -f "$f"
      continue
    fi
    yq -P 'sort_keys(..)' -i "$f"
    kind="$(yq '.kind // "nokind"' "$f")"
    ns="$(yq '.metadata.namespace // "cluster"' "$f")"
    name="$(yq '.metadata.name // "noname"' "$f")"
    mv "$f" "$out_dir/${kind}__${ns}__${name}.yaml"
  done
}

render_and_normalize "$REPO_ROOT/gitops" "$WORK_DIR/platform"
render_and_normalize "$REPO_ROOT/gitops" "$WORK_DIR/platform-recovery" \
  --set postgres.recoverySnapshotHandle=snap-x
render_and_normalize "$REPO_ROOT/gitops/bootstrap" "$WORK_DIR/bootstrap"

if [ "$MODE" = "update" ]; then
  rm -rf "$GOLDEN_DIR"
  mkdir -p "$(dirname "$GOLDEN_DIR")"
  cp -R "$WORK_DIR/." "$GOLDEN_DIR"
  # mktemp -d workdir cleanup left an empty raw-* trace dir name only; drop
  # any stray raw-*.yaml that render_and_normalize left behind in $WORK_DIR.
  find "$GOLDEN_DIR" -maxdepth 1 -name 'raw-*.yaml' -delete
  echo "GITOPS-RENDER-CHECK: golden baseline updated at $GOLDEN_DIR"
  exit 0
fi

if [ ! -d "$GOLDEN_DIR" ]; then
  echo "GITOPS-RENDER-CHECK: no golden baseline at $GOLDEN_DIR - run '$0 update' to create it." >&2
  exit 1
fi

find "$WORK_DIR" -maxdepth 1 -name 'raw-*.yaml' -delete
if diff -ru "$GOLDEN_DIR" "$WORK_DIR"; then
  echo "GITOPS-RENDER-CHECK: aws render matches the golden baseline."
else
  echo "GITOPS-RENDER-CHECK: aws render differs from the golden baseline (see diff above)." >&2
  echo "GITOPS-RENDER-CHECK: if the change is intentional, run '$0 update' and review the diff." >&2
  exit 1
fi
