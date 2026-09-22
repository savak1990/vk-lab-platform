#!/usr/bin/env bash
# Renders gitops/ and gitops/bootstrap/ with target=aws and compares a
# normalized, kind/name-sorted form against the committed baseline under
# tests/golden/gitops-aws/. Document order and `# Source:` comments are
# stripped first, since Argo tracks resources by kind/name, not file location.
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

# Backup objects render only when argo-up supplies these, so the backup
# renders set them the way a real bring-up does.
BACKUP_SETS=(
  --set postgres.backup.enabled=true
  --set postgres.backup.bucket=render-check-bucket
  --set postgres.backup.serverName=render-check-server
)
render_and_normalize "$REPO_ROOT/gitops" "$WORK_DIR/platform" aws
render_and_normalize "$REPO_ROOT/gitops" "$WORK_DIR/platform-backup" aws "${BACKUP_SETS[@]}"
render_and_normalize "$REPO_ROOT/gitops" "$WORK_DIR/platform-backup-recovery" aws \
  "${BACKUP_SETS[@]}" --set postgres.backup.recoverServerName=render-check-previous
render_and_normalize "$REPO_ROOT/gitops/bootstrap" "$WORK_DIR/bootstrap" aws

POSTGRES_IMAGE="$(yq '.postgres.imageName' "$REPO_ROOT/gitops/values.yaml")"

verify_backup_render() {
  local dir="$1" target="$2" sidecar_repo="$3" obj got
  for obj in ObjectStore__cnpg-system__lab-postgres-backups ScheduledBackup__cnpg-system__lab-postgres \
    Application__argocd__barman-cloud-plugin; do
    if [ ! -e "$dir/$obj.yaml" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target backup render is missing $obj" >&2
      return 1
    fi
  done
  got="$(yq '.spec.source.helm.parameters[] | select(.name == "sidecarImage.repository") | .value' \
    "$dir/Application__argocd__barman-cloud-plugin.yaml")"
  if [ "$got" != "$sidecar_repo" ]; then
    echo "GITOPS-RENDER-CHECK: target=$target backup sidecar repository is '$got', expected '$sidecar_repo'" >&2
    return 1
  fi
  got="$(yq '.spec.imageName' "$dir/Cluster__cnpg-system__lab-postgres.yaml")"
  case "$POSTGRES_IMAGE" in
    *@sha256:*) ;;
    *) echo "GITOPS-RENDER-CHECK: postgres.imageName '$POSTGRES_IMAGE' is not pinned by digest" >&2; return 1 ;;
  esac
  if [ "$got" != "$POSTGRES_IMAGE" ]; then
    echo "GITOPS-RENDER-CHECK: target=$target Cluster imageName is '$got', expected '$POSTGRES_IMAGE'" >&2
    return 1
  fi
}

verify_backup_render "$WORK_DIR/platform-backup" aws cloudnative-pg/plugin-barman-cloud-sidecar

# PostgreSQL persistence on aws is the backup plugin alone; a leftover
# snapshot object or snapshot-controller Application means it regressed.
verify_no_snapshot_path() {
  local dir kind
  for dir in "$WORK_DIR"/platform*; do
    for kind in VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot; do
      if compgen -G "$dir/${kind}__*.yaml" >/dev/null; then
        echo "GITOPS-RENDER-CHECK: aws render $(basename "$dir") still renders a $kind" >&2
        return 1
      fi
    done
    if compgen -G "$dir/Application__argocd__external-snapshotter*.yaml" >/dev/null; then
      echo "GITOPS-RENDER-CHECK: aws render $(basename "$dir") still renders an external-snapshotter Application" >&2
      return 1
    fi
  done
  if grep -qE 'VolumeSnapshotContent|recoverySnapshotHandle' "$WORK_DIR/bootstrap/Application__argocd__root.yaml"; then
    echo "GITOPS-RENDER-CHECK: the root Application still carries snapshot recovery settings" >&2
    return 1
  fi
}

verify_no_snapshot_path

# civo/local have no golden baseline to diff against, so they're checked
# structurally instead: the M1 baseline must appear, and nothing aws-only
# may leak through by accident.
REQUIRED_OBJECTS="Application__argocd__envoy-gateway Application__argocd__cnpg-operator \
Application__argocd__external-secrets PriorityClass__cluster__postgres-critical \
ClusterRole__cluster__e2e-test-readonly \
RoleBinding__cnpg-system__e2e-test-readonly RoleBinding__argocd__e2e-test-readonly"
REQUIRED_OBJECTS_CIVO="EnvoyProxy__envoy__envoy-proxy-config Gateway__envoy__platform-gateway \
GatewayClass__cluster__envoy-gateway Application__argocd__cert-manager \
ClusterIssuer__cluster__civo-workload-ca Certificate__external-secrets__eso \
Certificate__kube-system__external-dns Certificate__cert-manager__cert-manager \
ClusterSecretStore__cluster__aws-parameter-store \
ExternalSecret__cnpg-system__lab-postgres-app Application__argocd__external-dns \
ClusterIssuer__cluster__letsencrypt-staging ClusterIssuer__cluster__letsencrypt-prod \
Certificate__envoy__platform-public HTTPRoute__envoy__https-redirect \
HTTPRoute__argocd__argocd \
Cluster__cnpg-system__lab-postgres Certificate__cnpg-system__pgbackup \
ConfigMap__cnpg-system__pgbackup-aws-config \
ObjectStore__cnpg-system__lab-postgres-backups \
ScheduledBackup__cnpg-system__lab-postgres \
Application__argocd__barman-cloud-plugin \
Application__argocd__kube-prometheus-stack Application__argocd__loki \
Application__argocd__alloy HTTPRoute__observability__grafana \
ExternalSecret__observability__grafana-admin-credentials \
BackendTrafficPolicy__observability__grafana-traffic-policy \
RoleBinding__observability__e2e-test-readonly \
Application__argocd__cluster-autoscaler ServiceMonitor__kube-system__cluster-autoscaler \
PodMonitor__cnpg-system__cnpg-postgres ServiceMonitor__argocd__argocd \
Namespace__cluster__e2e ServiceAccount__e2e__e2e-test"
REQUIRED_OBJECTS_LOCAL="EnvoyProxy__envoy__envoy-proxy-config \
Gateway__envoy__platform-gateway GatewayClass__cluster__envoy-gateway \
HTTPRoute__argocd__argocd Cluster__cnpg-system__lab-postgres \
Application__argocd__kube-prometheus-stack Application__argocd__metrics-server \
ServiceMonitor__argocd__argocd PodMonitor__cnpg-system__cnpg-postgres \
ServiceMonitor__envoy__envoy-gateway PodMonitor__envoy__envoy-proxy \
ConfigMap__observability__dashboard-cnpg \
PrometheusRule__observability__observability-alerts"
FORBIDDEN_KINDS_LOCAL="StorageClass VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot \
ClusterSecretStore ExternalSecret NodePool EC2NodeClass \
ObjectStore ScheduledBackup"
FORBIDDEN_KINDS_CIVO="StorageClass VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot \
NodePool EC2NodeClass"
FORBIDDEN_APPLICATIONS_LOCAL="aws-load-balancer-controller cert-manager ebs-csi-driver karpenter \
loki alloy external-snapshotter external-snapshotter-crds \
external-dns barman-cloud-plugin"
FORBIDDEN_APPLICATIONS_CIVO="aws-load-balancer-controller ebs-csi-driver karpenter \
external-snapshotter external-snapshotter-crds"
FORBIDDEN_OBJECTS_LOCAL="BackendTrafficPolicy__observability__grafana-traffic-policy \
HTTPRoute__observability__grafana \
RoleBinding__observability__e2e-test-readonly \
ExternalSecret__observability__grafana-admin-credentials \
ServiceMonitor__kube-system__karpenter \
ConfigMap__observability__dashboard-karpenter-capacity \
Namespace__cluster__e2e ServiceAccount__e2e__e2e-test"
FORBIDDEN_OBJECTS_CIVO="ServiceMonitor__kube-system__karpenter \
ConfigMap__observability__dashboard-karpenter-capacity"
# The civo set, less the two features hetzner does not have yet, plus the CSI
# driver. The whole Gateway API surface - GatewayClass, EnvoyProxy, Gateway,
# every HTTPRoute, and the BackendTrafficPolicy that targets one - arrives with
# the load balancer (HETZ-060) and is forbidden until then: a route no Gateway
# accepts never reports healthy, and the root sync stalls behind it.
# cluster-autoscaler arrives with HETZ-170.
# StorageClass is allowed, unlike civo: the hcloud CSI chart ships its own.
REQUIRED_OBJECTS_HETZNER="Application__argocd__hcloud-csi \
Application__argocd__cert-manager \
ClusterIssuer__cluster__hetzner-workload-ca Certificate__external-secrets__eso \
Certificate__kube-system__external-dns Certificate__cert-manager__cert-manager \
ClusterSecretStore__cluster__aws-parameter-store \
ExternalSecret__cnpg-system__lab-postgres-app Application__argocd__external-dns \
ClusterIssuer__cluster__letsencrypt-staging ClusterIssuer__cluster__letsencrypt-prod \
Certificate__envoy__platform-public \
Cluster__cnpg-system__lab-postgres Certificate__cnpg-system__pgbackup \
ConfigMap__cnpg-system__pgbackup-aws-config \
ObjectStore__cnpg-system__lab-postgres-backups \
ScheduledBackup__cnpg-system__lab-postgres \
Application__argocd__barman-cloud-plugin \
Application__argocd__kube-prometheus-stack Application__argocd__loki \
Application__argocd__alloy \
ExternalSecret__observability__grafana-admin-credentials \
RoleBinding__observability__e2e-test-readonly \
PodMonitor__cnpg-system__cnpg-postgres ServiceMonitor__argocd__argocd \
Namespace__cluster__e2e ServiceAccount__e2e__e2e-test"
FORBIDDEN_KINDS_HETZNER="VolumeSnapshotClass VolumeSnapshotContent VolumeSnapshot \
NodePool EC2NodeClass"
FORBIDDEN_APPLICATIONS_HETZNER="aws-load-balancer-controller ebs-csi-driver karpenter \
external-snapshotter external-snapshotter-crds metrics-server"
FORBIDDEN_OBJECTS_HETZNER="GatewayClass__cluster__envoy-gateway \
HTTPRoute__envoy__https-redirect HTTPRoute__argocd__argocd \
HTTPRoute__observability__grafana \
BackendTrafficPolicy__observability__grafana-traffic-policy \
ServiceMonitor__kube-system__karpenter \
ConfigMap__observability__dashboard-karpenter-capacity"

# An Application's helm values are one YAML string, so they need a second
# parse. Each argument is <yq-path>=<expected>.
assert_helm_values() {
  local target="$1" app="$2" dir="$3" values pair path want got
  shift 3
  values="$(yq '.spec.source.helm.values' "$dir/Application__argocd__$app.yaml")"
  for pair in "$@"; do
    path="${pair%%=*}"
    want="${pair#*=}"
    got="$(printf '%s\n' "$values" | yq "$path")"
    if [ "$got" != "$want" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target $app $path is '$got', expected '$want'" >&2
      return 1
    fi
  done
}

verify_object_set() {
  local dir="$1" target="$2" obj name kind
  local required forbidden_kinds forbidden_apps forbidden_objects
  case "$target" in
    civo)
      required="$REQUIRED_OBJECTS $REQUIRED_OBJECTS_CIVO"
      forbidden_kinds="$FORBIDDEN_KINDS_CIVO"
      forbidden_apps="$FORBIDDEN_APPLICATIONS_CIVO"
      forbidden_objects="$FORBIDDEN_OBJECTS_CIVO"
      ;;
    hetzner)
      required="$REQUIRED_OBJECTS $REQUIRED_OBJECTS_HETZNER"
      forbidden_kinds="$FORBIDDEN_KINDS_HETZNER"
      forbidden_apps="$FORBIDDEN_APPLICATIONS_HETZNER"
      forbidden_objects="$FORBIDDEN_OBJECTS_HETZNER"
      ;;
    local)
      required="$REQUIRED_OBJECTS $REQUIRED_OBJECTS_LOCAL"
      forbidden_kinds="$FORBIDDEN_KINDS_LOCAL"
      forbidden_apps="$FORBIDDEN_APPLICATIONS_LOCAL"
      forbidden_objects="$FORBIDDEN_OBJECTS_LOCAL"
      ;;
    *)
      echo "GITOPS-RENDER-CHECK: no object set defined for target=$target" >&2
      return 1
      ;;
  esac
  for obj in $required; do
    if [ ! -e "$dir/$obj.yaml" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target is missing required object $obj" >&2
      return 1
    fi
  done
  for kind in $forbidden_kinds; do
    if compgen -G "$dir/${kind}__*.yaml" >/dev/null; then
      echo "GITOPS-RENDER-CHECK: target=$target unexpectedly renders a $kind (aws/ebs/karpenter-only kind leaked into shared/civo)" >&2
      return 1
    fi
  done
  for name in $forbidden_apps; do
    if [ -e "$dir/Application__argocd__$name.yaml" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target unexpectedly renders Application/$name (this application is not yet part of this target's baseline)" >&2
      return 1
    fi
  done
  for obj in $forbidden_objects; do
    if [ -e "$dir/$obj.yaml" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target unexpectedly renders $obj (is not part of this target's baseline)" >&2
      return 1
    fi
  done
  case "$target" in civo | hetzner | local)
    local hits
    local leaks=(-e 'ebs-delete' -e 'karpenter.sh/capacity-type')
    # civo's storage class and provider annotation are as wrong on hetzner as
    # an aws one: either means a civo-only branch was reached by both targets.
    if [ "$target" = hetzner ]; then
      leaks+=(-e 'civo-volume' -e 'kubernetes.civo.com')
    fi
    # grep -q exits as soon as it finds a match, killing the upstream grep with
    # SIGPIPE; under pipefail that turns a real match into a false "no match".
    # Capture matched lines instead so the upstream always runs to completion.
    hits="$(grep -rhEv '^[[:space:]]*#' "$dir" | grep "${leaks[@]}" || true)"
    if [ -n "$hits" ]; then
      echo "GITOPS-RENDER-CHECK: target=$target renders another target's storage class, spot affinity or provider annotation" >&2
      return 1
    fi
    if [ "$target" = local ]; then
      # The grep above only catches the literal ebs-delete. These pin the two
      # values a kind cluster cannot survive getting wrong.
      local got
      got="$(yq '.spec.storage.storageClass' "$dir/Cluster__cnpg-system__lab-postgres.yaml")"
      if [ "$got" != standard ]; then
        echo "GITOPS-RENDER-CHECK: target=$target Cluster storageClass is '$got', expected 'standard'" >&2
        return 1
      fi
      got="$(yq '.spec.enablePDB' "$dir/Cluster__cnpg-system__lab-postgres.yaml")"
      if [ "$got" != false ]; then
        echo "GITOPS-RENDER-CHECK: target=$target Cluster enablePDB is '$got', expected 'false'" >&2
        return 1
      fi
      # Laptop scale is invisible to the greps above: a cloud-sized retention
      # or claim renders as valid YAML either way.
      assert_helm_values "$target" kube-prometheus-stack "$dir" \
        '.prometheus.prometheusSpec.retention=6h' \
        '.prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=1Gi' \
        '.alertmanager.enabled=false' || return 1
    fi
    local karpenter_rule="$dir/PrometheusRule__observability__observability-alerts.yaml"
    if [ -e "$karpenter_rule" ]; then
      hits="$(grep -Ev '^[[:space:]]*#' "$karpenter_rule" | grep 'Karpenter' || true)"
      if [ -n "$hits" ]; then
        echo "GITOPS-RENDER-CHECK: target=$target renders an aws-only Karpenter alert" >&2
        return 1
      fi
    fi
    ;;
  esac
}

STRUCT_OK=true
for t in civo hetzner local; do
  # The backup objects render only when the operator-supplied values are
  # present, so the backup-carrying targets are rendered as a real bring-up
  # would set them.
  extra_sets=()
  if [ "$t" != local ]; then
    extra_sets=(
      --set postgres.backup.enabled=true
      --set postgres.backup.bucket=render-check-bucket
      --set postgres.backup.serverName=render-check-server
    )
  fi
  render_and_normalize "$REPO_ROOT/gitops" "$STRUCT_DIR/$t" "$t" "${extra_sets[@]+"${extra_sets[@]}"}"
  verify_object_set "$STRUCT_DIR/$t" "$t" || STRUCT_OK=false
  # Both self-managed targets reach AWS through Roles Anywhere, so both must
  # resolve to the sidecar build that carries aws_signing_helper. Without this
  # a target missing from sidecarImages renders an empty image reference
  # instead of failing.
  if [ "$t" != local ]; then
    verify_backup_render "$STRUCT_DIR/$t" "$t" savak1990/vk-lab-platform/cnpg-barman-sidecar || STRUCT_OK=false
  fi
done
if [ "$STRUCT_OK" != true ]; then
  exit 1
fi
echo "GITOPS-RENDER-CHECK: civo, hetzner and local renders have the expected M1 object set."

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
