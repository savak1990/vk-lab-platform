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
STRUCT_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR" "$STRUCT_DIR"' EXIT

# Splits a multi-document `helm template` stream into one normalized file
# per rendered object, named by kind/namespace/name so the same object
# always lands at the same path regardless of which source file rendered
# it or what order Helm emitted it in.
render_and_normalize() {
  local chart_dir="$1" out_dir="$2" target="$3"; shift 3
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  local raw="$WORK_DIR/raw-$$-$RANDOM.yaml"
  helm template "$chart_dir" --set "target=$target" "$@" > "$raw"

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

render_and_normalize "$REPO_ROOT/gitops" "$WORK_DIR/platform" aws
render_and_normalize "$REPO_ROOT/gitops" "$WORK_DIR/platform-recovery" aws \
  --set postgres.recoverySnapshotHandle=snap-x
render_and_normalize "$REPO_ROOT/gitops/bootstrap" "$WORK_DIR/bootstrap" aws

# civo/local have no golden baseline (nothing to diff - CIVO-050 is the
# first spec to render them at all), so they're checked structurally
# instead: the M1 baseline must appear, and nothing gated to aws only
# (observability, karpenter, alb-controller, ebs-csi, the CNPG Cluster,
# the ClusterSecretStore/ExternalSecret pair - see spec CIVO-050 S3's
# 2026-09-07 correction) may leak through by accident.
REQUIRED_OBJECTS="Application__argocd__envoy-gateway Application__argocd__cnpg-operator \
Application__argocd__external-secrets PriorityClass__cluster__postgres-critical \
ClusterRole__cluster__e2e-test-readonly BackendTrafficPolicy__observability__grafana-traffic-policy"
FORBIDDEN_KINDS="StorageClass VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot \
ClusterSecretStore ExternalSecret Cluster NodePool EC2NodeClass EnvoyProxy Gateway GatewayClass"
FORBIDDEN_APPLICATIONS="aws-load-balancer-controller cert-manager ebs-csi-driver karpenter \
kube-prometheus-stack loki metrics-server alloy external-snapshotter external-snapshotter-crds \
external-dns"

verify_object_set() {
  local dir="$1" target="$2" obj name kind
  for obj in $REQUIRED_OBJECTS; do
    if [ ! -e "$dir/$obj.yaml" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target is missing required object $obj" >&2
      return 1
    fi
  done
  for kind in $FORBIDDEN_KINDS; do
    if compgen -G "$dir/${kind}__*.yaml" >/dev/null; then
      echo "GITOPS-RENDER-CHECK: target=$target unexpectedly renders a $kind (aws/ebs/karpenter-only kind leaked into shared/civo)" >&2
      return 1
    fi
  done
  for name in $FORBIDDEN_APPLICATIONS; do
    if [ -e "$dir/Application__argocd__$name.yaml" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target unexpectedly renders Application/$name (aws-only until a later spec)" >&2
      return 1
    fi
  done
}

CIVO_LOCAL_OK=true
for t in civo local; do
  render_and_normalize "$REPO_ROOT/gitops" "$STRUCT_DIR/$t" "$t"
  verify_object_set "$STRUCT_DIR/$t" "$t" || CIVO_LOCAL_OK=false
done
if [ "$CIVO_LOCAL_OK" != true ]; then
  exit 1
fi
echo "GITOPS-RENDER-CHECK: civo and local renders have the expected M1 object set."

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
