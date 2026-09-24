#!/usr/bin/env bash
# Installs Argo CD and the root ("app-of-apps") Application onto the
# disposable EKS cluster. A script, not Terraform (ADR 0012) - Argo's own
# bootstrap only needs to run after EKS exists, and terraform-provider-helm
# can't reliably wait through Argo's finalizer-gated cascade on the way
# down, so both directions use the same non-Terraform mechanism.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"
# shellcheck source=lib/argo-watch.sh
source "$REPO_ROOT/scripts/lib/argo-watch.sh"

# Keeps kubectl and helm on a repo-local kubeconfig: a lifecycle run must never
# change the context the operator is working in.
use_isolated_kubeconfig
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.4.0}"
# hetzner only. Installed by this script rather than by Argo CD, because
# Argo needs the cluster DNS that only this controller unblocks.
HCCM_CHART_VERSION="${HCCM_CHART_VERSION:-1.37.0}"
# hetzner only. Must match the image the nodes module gives the fixed pool -
# an autoscaled node boots that pool's cloud-init and would fail on another OS.
HCLOUD_NODE_IMAGE="${HCLOUD_NODE_IMAGE:-ubuntu-24.04}"
TARGET_REVISION="${TARGET_REVISION:-main}"
REPO_URL="${REPO_URL:-https://github.com/savak1990/vk-lab-platform}"
# local target only. Fixed and publicly known on purpose, like
# FIXED_TEST_PASSWORDS: the cluster is throwaway and holds nothing real.
LOCAL_ARGOCD_PASSWORD="${LOCAL_ARGOCD_PASSWORD:-test}"
LOCAL_GRAFANA_PASSWORD="${LOCAL_GRAFANA_PASSWORD:-test}"
# Comma-separated. spot is general workload capacity (several arm64
# families/sizes, so a capacity-optimized fleet request has a fallback when one
# instance type/AZ combination has no Spot capacity); onDemand is tainted and
# reserved for Postgres, which tolerates it explicitly.
SPOT_KARPENTER_INSTANCE_TYPES="${SPOT_KARPENTER_INSTANCE_TYPES:-t4g.medium,t4g.large,m6g.medium,m6g.large,m7g.medium,m7g.large}"
ON_DEMAND_KARPENTER_INSTANCE_TYPES="${ON_DEMAND_KARPENTER_INSTANCE_TYPES:-t4g.medium,t4g.large,m6g.medium,m6g.large,m7g.medium,m7g.large}"
# Increase-only: Kubernetes rejects a PVC shrink. The local default is smaller
# because kind's provisioner carves it out of the laptop's own disk.
if [ "$PROVIDER" = local ]; then
  POSTGRES_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-5Gi}"
else
  POSTGRES_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-20Gi}"
fi
# Never set below 2: recovery reads the previous generation while
# the current one is still building its own first base backup.
POSTGRES_BACKUP_KEEP_GENERATIONS="${POSTGRES_BACKUP_KEEP_GENERATIONS:-2}"
SPOT_KARPENTER_INSTANCE_TYPES_JSON="$(jq -Rc 'split(",")' <<< "$SPOT_KARPENTER_INSTANCE_TYPES")"
ON_DEMAND_KARPENTER_INSTANCE_TYPES_JSON="$(jq -Rc 'split(",")' <<< "$ON_DEMAND_KARPENTER_INSTANCE_TYPES")"

eks_output() {
  terragrunt --working-dir "$REPO_ROOT/terraform/live/cluster/eks" output -raw "$1"
}

# The owning terragrunt unit is named in the failure message - a plain
# ParameterNotFound doesn't say which unit should have created it, unlike
# terragrunt output's own error.
ssm_output() {
  local i
  for i in "${!SSM_BATCH_NAMES[@]}"; do
    [ "${SSM_BATCH_NAMES[$i]}" = "$1" ] && { printf '%s' "${SSM_BATCH_VALUES[$i]}"; return; }
  done
  echo "ARGO-UP: missing SSM parameter $1 - has its owning terragrunt unit been applied?" >&2
  exit 1
}

# One batched get-parameters call, not six round trips. --with-decryption
# is a no-op on the plain String ones, so this serves both types uniformly.
# Bash 3.2 compatible (no associative arrays) - linear scan over 6 items.
aws_resolve_inputs() {
  local ssm_names=(
    "/$PROJECT_NAME/bootstrap/acm/certificate_arn"
    "/$PROJECT_NAME/persistent/vpc/vpc_id"
    "/$PROJECT_NAME/cluster/eks/node_subnet_id"
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
    "/$PROJECT_NAME/persistent/backups/bucket_name"
  )
  SSM_BATCH_NAMES=()
  SSM_BATCH_VALUES=()
  while IFS=$'\t' read -r name value; do
    SSM_BATCH_NAMES+=("$name")
    SSM_BATCH_VALUES+=("$value")
  done < <(aws ssm get-parameters --region "$LAB_REGION" --with-decryption \
    --names "${ssm_names[@]}" --query 'Parameters[].[Name,Value]' --output text)

  CLUSTER_NAME="$(eks_output cluster_name)"
  ACM_CERTIFICATE_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/acm/certificate_arn")"
  VPC_ID="$(ssm_output "/$PROJECT_NAME/persistent/vpc/vpc_id")"
  NODE_SUBNET_ID="$(ssm_output "/$PROJECT_NAME/cluster/eks/node_subnet_id")"
  # fqdn ("lab.<root-domain>") is sensitive - never echo it, including via a
  # full hostname built from it (label DNS output by short name instead).
  LAB_FQDN="$(ssm_output "/$PROJECT_NAME/bootstrap/route53/fqdn")"
  ADMIN_PASSWORD_BCRYPT_HASH="$(ssm_output "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt")"
  BACKUP_BUCKET="$(ssm_output "/$PROJECT_NAME/persistent/backups/bucket_name")"
  backup_resolve_generation
  configure_kubeconfig "$KUBECONFIG"
}

# serverName is minted per bring-up, so a recovered cluster never archives
# into the generation it recovered from.
backup_resolve_generation() {
  RECOVER_SERVER_NAME="$(backup_recovery_handle "$BACKUP_SSM_LAYER")"
  BACKUP_SERVER_NAME="lab-postgres-$(date -u +%Y%m%dT%H%M%SZ)"
}

civo_resolve_inputs() {
  civo_token
  # aws ssm get-parameters accepts at most 10 names per call, so the list is
  # fetched in batches rather than one request.
  local civo_ssm_names=(
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/bootstrap/route53/zone_id"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
    "/$PROJECT_NAME/persistent-civo/reserved-ip/address"
    "/$PROJECT_NAME/persistent-civo/backups/bucket_name"
    "/$PROJECT_NAME/cluster-civo/network/lb_firewall_id"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/trust_anchor_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/profile_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/eso"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/external-dns"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/cert-manager"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/pgbackup"
  )
  local civo_ssm_batch_names=() civo_ssm_batch_values=()
  local batch_start=0
  while [ "$batch_start" -lt "${#civo_ssm_names[@]}" ]; do
    while IFS=$'\t' read -r name value; do
      civo_ssm_batch_names+=("$name")
      civo_ssm_batch_values+=("$value")
    done < <(aws ssm get-parameters --region "$LAB_REGION" --with-decryption \
      --names "${civo_ssm_names[@]:$batch_start:10}" \
      --query 'Parameters[].[Name,Value]' --output text)
    batch_start=$((batch_start + 10))
  done

  local i
  for i in "${!civo_ssm_names[@]}"; do
    local found=""
    local j
    for j in "${!civo_ssm_batch_names[@]}"; do
      [ "${civo_ssm_batch_names[$j]}" = "${civo_ssm_names[$i]}" ] && { found="${civo_ssm_batch_values[$j]}"; break; }
    done
    if [ -z "$found" ]; then
      echo "ARGO-UP: missing SSM parameter ${civo_ssm_names[$i]} - has its owning terragrunt unit been applied?" >&2
      exit 1
    fi
    case "${civo_ssm_names[$i]}" in
      */fqdn) LAB_FQDN="$found" ;;
      */route53/zone_id) ROUTE53_ZONE_ID="$found" ;;
      */admin_password_bcrypt) ADMIN_PASSWORD_BCRYPT_HASH="$found" ;;
      */reserved-ip/address) RESERVED_IP="$found" ;;
      */lb_firewall_id) FIREWALL_ID="$found" ;;
      */rolesanywhere/trust_anchor_arn) TRUST_ANCHOR_ARN="$found" ;;
      */rolesanywhere/profile_arn) PROFILE_ARN="$found" ;;
      */rolesanywhere/role_arn/eso) ESO_ROLE_ARN="$found" ;;
      */rolesanywhere/role_arn/external-dns) EXTERNAL_DNS_ROLE_ARN="$found" ;;
      */rolesanywhere/role_arn/cert-manager) CERT_MANAGER_ROLE_ARN="$found" ;;
      */rolesanywhere/role_arn/pgbackup) PGBACKUP_ROLE_ARN="$found" ;;
      */backups/bucket_name) BACKUP_BUCKET="$found" ;;
    esac
  done

  # The pointer is absent on the first bring-up, so it cannot go through the
  # fail-hard loop above.
  backup_resolve_generation

  configure_kubeconfig "$KUBECONFIG"
}

# Reaches no cloud API at all. Every value the other resolvers read from SSM
# either has no local equivalent or is generated here, and the password is the
# publicly-known "test" that FIXED_TEST_PASSWORDS already uses for throwaway
# environments - nothing on this target is real enough to protect.
local_resolve_inputs() {
  command -v htpasswd >/dev/null 2>&1 || {
    echo "ARGO-UP: htpasswd is required to hash the local Argo CD password." >&2
    exit 1
  }
  ADMIN_PASSWORD_BCRYPT_HASH="$(htpasswd -nbBC 10 "" "$LOCAL_ARGOCD_PASSWORD" | cut -d: -f2 | tr -d '\n')"
  # Empty rather than unset: the DNS and backup machinery below is shared by
  # every target and reads these outside a provider branch, under `set -u`.
  LAB_FQDN=""
  BACKUP_BUCKET=""
  BACKUP_SERVER_NAME=""
  RECOVER_SERVER_NAME=""
  configure_kubeconfig "$KUBECONFIG"
  require_local_context
}

# Thirteen names against a get-parameters cap of ten, so this batches the way
# civo_resolve_inputs does and reuses the aws-side ssm_output lookup. It was one
# call until the autoscaler's two took it over the cap; its third, the worker
# cloud-init, is read below instead. The load balancer's location is not one of
# them: it comes from the REGION operator input, which no Terraform layer owns.
#
# No reserved IP: this target has none. No firewall id either, because nothing
# reads it. The backup bucket comes from the shared persistent layer, which
# this target does not exclude.
hetzner_resolve_inputs() {
  hcloud_token
  # aws ssm get-parameters accepts at most 10 names per call, so the list is
  # fetched in batches rather than one request.
  local ssm_names=(
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/bootstrap/route53/zone_id"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
    "/$PROJECT_NAME/persistent-hetzner/network/network_id"
    "/$PROJECT_NAME/persistent/backups/bucket_name"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/trust_anchor_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/profile_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/eso"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/external-dns"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/cert-manager"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/pgbackup"
    "/$PROJECT_NAME/persistent-hetzner/ssh-key/ssh_key_id"
    "/$PROJECT_NAME/persistent-hetzner/network/subnet_ip_range"
  )
  SSM_BATCH_NAMES=()
  SSM_BATCH_VALUES=()
  local batch_start=0
  while [ "$batch_start" -lt "${#ssm_names[@]}" ]; do
    while IFS=$'\t' read -r name value; do
      SSM_BATCH_NAMES+=("$name")
      SSM_BATCH_VALUES+=("$value")
    done < <(aws ssm get-parameters --region "$LAB_REGION" --with-decryption \
      --names "${ssm_names[@]:$batch_start:10}" \
      --query 'Parameters[].[Name,Value]' --output text)
    batch_start=$((batch_start + 10))
  done

  LAB_FQDN="$(ssm_output "/$PROJECT_NAME/bootstrap/route53/fqdn")"
  ROUTE53_ZONE_ID="$(ssm_output "/$PROJECT_NAME/bootstrap/route53/zone_id")"
  ADMIN_PASSWORD_BCRYPT_HASH="$(ssm_output "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt")"
  HCLOUD_NETWORK_ID="$(ssm_output "/$PROJECT_NAME/persistent-hetzner/network/network_id")"
  TRUST_ANCHOR_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/rolesanywhere/trust_anchor_arn")"
  PROFILE_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/rolesanywhere/profile_arn")"
  ESO_ROLE_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/eso")"
  EXTERNAL_DNS_ROLE_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/external-dns")"
  CERT_MANAGER_ROLE_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/cert-manager")"
  PGBACKUP_ROLE_ARN="$(ssm_output "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/pgbackup")"
  BACKUP_BUCKET="$(ssm_output "/$PROJECT_NAME/persistent/backups/bucket_name")"
  backup_resolve_generation
  SSH_KEY_ID="$(ssm_output "/$PROJECT_NAME/persistent-hetzner/ssh-key/ssh_key_id")"
  # Stated rather than left to Hetzner's default: the network holds one subnet
  # today, and a second would make that default a guess.
  HCLOUD_SUBNET_IP_RANGE="$(ssm_output "/$PROJECT_NAME/persistent-hetzner/network/subnet_ip_range")"
  # Its own call, not the batch: --output text writes a value's newlines
  # literally, and the batch reads one tab-separated pair per line. A
  # multi-line cloud-init would be truncated at its first line and every pair
  # after it misread. Carries the k3s join token, so it is never echoed.
  WORKER_USER_DATA="$(aws ssm get-parameter --region "$LAB_REGION" --with-decryption \
    --name "/$PROJECT_NAME/cluster-hetzner/k8s/worker_user_data" \
    --query 'Parameter.Value' --output text)"
  configure_kubeconfig "$KUBECONFIG"
}

case "$PROVIDER" in
  civo) civo_resolve_inputs ;;
  hetzner) hetzner_resolve_inputs ;;
  local) local_resolve_inputs ;;
  aws) aws_resolve_inputs ;;
  *) echo "ARGO-UP: no input resolver for PROVIDER=$PROVIDER." >&2; exit 1 ;;
esac

# Named providers rather than "not aws": local has no TLS Secret to import and
# no SSM to import it from, and would otherwise inherit the AWS call.
if [ "$PROVIDER" = civo ] || [ "$PROVIDER" = hetzner ]; then
  import_tls_secret
fi

# Parallel arrays, not an associative array: DNS_HOST_LABELS[i]/DNS_HOST_FQDNS[i],
# so this stays bash-3.2-compatible (stock macOS /bin/bash predates `declare -A`).
# Labels, not full hostnames, keep $LAB_FQDN out of any echoed output. dig
# failures (missing binary, network) are swallowed to "unresolved" here rather
# than aborting under set -euo pipefail - a wait loop should keep polling
# through a transient resolver error, not die on one.
DNS_HOST_LABELS=(argo grafana)
DNS_HOST_FQDNS=("argo.$LAB_FQDN" "grafana.$LAB_FQDN")

# Same label selector monitors.yaml already uses to find this Gateway's
# Service. Resolving the NLB's own hostname (not comparing Service objects)
# catches a stale Route 53 record left over from a torn-down cluster's NLB -
# a record that still resolves, just no longer to the live NLB.
current_nlb_ips() {
  local nlb_host
  nlb_host="$(kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$nlb_host" ] && dig +short "$nlb_host" 2>/dev/null || true
}

dns_status() {
  local nlb_ips="$1"
  local i label ip
  for i in "${!DNS_HOST_LABELS[@]}"; do
    label="${DNS_HOST_LABELS[$i]}"
    ip="$(dig +short "${DNS_HOST_FQDNS[$i]}" 2>/dev/null | tail -n1 || true)"
    if [ -z "$ip" ]; then
      echo "  $label -> <unresolved>"
    elif [ -n "$nlb_ips" ] && grep -qxF "$ip" <<< "$nlb_ips"; then
      echo "  $label -> $ip (matches current NLB)"
    else
      echo "  $label -> $ip (stale - does not match current NLB)"
    fi
  done
}

wait_for_lb_ip() {
  local watch_seconds="${CIVO_ARGO_UP_LB_WATCH_SECONDS:-300}"
  local poll_interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local elapsed=0 svc_ip=""
  while [ "$elapsed" -lt "$watch_seconds" ]; do
    svc_ip="$(kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [ -n "$svc_ip" ] && { [ -z "${RESERVED_IP:-}" ] || [ "$svc_ip" = "$RESERVED_IP" ]; }; then
      echo "ARGO-UP: Envoy Service LB address is ${svc_ip}${RESERVED_IP:+ (the reserved IP)}."
      return 0
    fi
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done
  echo "ARGO-UP: timed out after ${watch_seconds}s waiting for Envoy Service LB${RESERVED_IP:+ to get reserved IP $RESERVED_IP} - last observed: ${svc_ip:-none}." >&2
  return 1
}

wait_for_dns() {
  local watch_seconds
  if [ "$PROVIDER" = hetzner ]; then
    watch_seconds="${HETZNER_ARGO_UP_DNS_WATCH_SECONDS:-300}"
  else
    watch_seconds="${CIVO_ARGO_UP_DNS_WATCH_SECONDS:-60}"
  fi
  local poll_interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local elapsed=0 svc_ip="" dig_ip="" all_resolved="" i
  while [ "$elapsed" -lt "$watch_seconds" ]; do
    svc_ip="$(kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -z "$svc_ip" ] && svc_ip="${RESERVED_IP:-}"
    all_resolved=true
    for i in "${!DNS_HOST_FQDNS[@]}"; do
      dig_ip="$(dig +short "${DNS_HOST_FQDNS[$i]}" 2>/dev/null | tail -n1 || true)"
      { [ -n "$dig_ip" ] && [ -n "$svc_ip" ] && [ "$dig_ip" = "$svc_ip" ]; } || all_resolved=false
    done
    if [ "$all_resolved" = true ]; then
      echo "ARGO-UP: DNS resolved (${DNS_HOST_LABELS[*]} -> ${svc_ip})."
      echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."
      return 0
    fi
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done
  echo "ARGO-UP: DNS not resolved for ${DNS_HOST_LABELS[*]} after ${watch_seconds}s - non-fatal, but check ExternalDNS's Application health and Route 53 directly before assuming the platform is reachable." >&2
  echo "ARGO-UP: root Synced/Healthy - platform ready (DNS not yet resolved within the watch window)."
  return 0
}

# The node template is Terraform's own worker render, so an autoscaled node
# cannot drift from the fixed pool: same k3s version, same flags, same token.
# serverLabels carries five keys because three consumers select on them - the
# firewall, the teardown sweep and the failure diagnostics - and each needs a
# different one.
ensure_autoscaler_config() {
  local cloud_init config
  cloud_init="$(printf '%s' "$WORKER_USER_DATA" | base64 | tr -d '\n')"
  config="$(jq -cn \
    --arg image "$HCLOUD_NODE_IMAGE" \
    --arg subnet "$HCLOUD_SUBNET_IP_RANGE" \
    --arg cloudInit "$cloud_init" \
    --arg project "$PROJECT_NAME" \
    '{
      imagesForArch: {amd64: $image, arm64: $image},
      defaultSubnetIPRange: $subnet,
      nodeConfigs: {
        workers: {
          cloudInit: $cloudInit,
          serverLabels: {
            project: $project,
            scope: "platform",
            lifecycle: "disposable",
            managed_by: "autoscaler",
            role: "worker"
          }
        }
      }
    }' | base64 | tr -d '\n')"
  kubectl create secret generic hcloud-autoscaler-config -n kube-system \
    --from-literal=HCLOUD_CLUSTER_CONFIG="$config" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - app.kubernetes.io/managed-by=argo-up -o yaml \
    | kubectl apply -f - >/dev/null
}

ensure_ca_secret() {
  local ca_cert_path="${REPO_ROOT}/secrets/${PROJECT_NAME}/${PROVIDER}-ca-cert.pem"
  [ -f "$ca_cert_path" ] || { echo "ARGO-UP: no CA cert at $ca_cert_path - run 'PROVIDER=$PROVIDER make ca-init' first." >&2; exit 1; }
  kubectl create namespace cert-manager \
    --dry-run=client -o yaml | kubectl apply -f -
  "$REPO_ROOT/scripts/secret-decrypt.sh" "${PROVIDER}-ca-key" | \
    kubectl create secret tls "${PROVIDER}-workload-ca" \
      --cert="$ca_cert_path" \
      --key=/dev/stdin \
      --namespace cert-manager \
      --dry-run=client -o yaml \
    | kubectl label --local -f - app.kubernetes.io/managed-by=argo-up -o yaml \
    | kubectl apply -f -
}

# External Secrets stays excluded on this target, so the credential Grafana's
# chart expects is created here instead, in the same untracked bootstrap class
# as the workload CA secret above.
ensure_grafana_admin_secret() {
  kubectl create namespace observability \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic grafana-admin-credentials \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$LOCAL_GRAFANA_PASSWORD" \
    --namespace observability \
    --dry-run=client -o yaml \
    | kubectl label --local -f - app.kubernetes.io/managed-by=argo-up -o yaml \
    | kubectl apply -f -
}

aws_wait_for_dns() {
  local watch_seconds="${ARGO_UP_DNS_WATCH_SECONDS:-300}"
  local poll_interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local elapsed=0 all_resolved="" nlb_ips=""
  while [ "$elapsed" -lt "$watch_seconds" ]; do
    nlb_ips="$(current_nlb_ips)"
    all_resolved=true
    if [ -z "$nlb_ips" ]; then
      all_resolved=false
    else
      for i in "${!DNS_HOST_FQDNS[@]}"; do
        ip="$(dig +short "${DNS_HOST_FQDNS[$i]}" 2>/dev/null | tail -n1 || true)"
        { [ -n "$ip" ] && grep -qxF "$ip" <<< "$nlb_ips"; } || all_resolved=false
      done
    fi
    [ "$all_resolved" = true ] && break
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done
  echo "ARGO-UP: DNS status:"
  dns_status "$nlb_ips"
  if [ "$all_resolved" != true ]; then
    echo "ARGO-UP: timed out after ${watch_seconds}s waiting for DNS to resolve to the current NLB." >&2
    return 1
  fi
}

# Runs above the fast-path guard below so repeated argo-up runs still repair
# the Secret even on the fast path, and creates the cert-manager namespace
# itself, since it runs before cert-manager's own Application can CreateNamespace=true it.
# Named providers rather than "not aws": local has no Roles Anywhere CA, and
# ensure_ca_secret would hard-fail on the missing committed certificate.
if [ "$PROVIDER" = civo ] || [ "$PROVIDER" = hetzner ]; then
  ensure_ca_secret
fi

# Above the fast-path guard for the same reason as ensure_ca_secret: a re-run
# that takes the fast path must still refresh this, because the render it
# copies changes whenever the nodes module re-applies.
if [ "$PROVIDER" = hetzner ]; then
  ensure_autoscaler_config
fi

# Idempotency guard: if the root Application is already Synced/Healthy,
# there's nothing to do beyond confirming DNS - see wait_for_dns above for
# why a stuck DNS record still needs to be caught even on this fast path.
# Not a correctness requirement for the helm upgrade below (which uses
# --server-side/--force-conflicts specifically so a second run doesn't need
# this guard: Argo's own controller takes server-side-apply ownership of
# some Application spec fields once it's reconciled the object, and a plain
# client-side `helm upgrade --install` on an already-synced root fails with
# "Apply failed with 1 conflict" against that field manager otherwise).
# Never taken on local: re-running argo-up is that target's edit-reconcile
# loop, so a Synced/Healthy root is the normal starting state, not a reason
# to stop.
EXISTING_STATUS="$(kubectl get application root -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
if [ "$EXISTING_STATUS" = "Synced/Healthy" ] && [ "$PROVIDER" != local ]; then
  echo "ARGO-UP: root Application already Synced/Healthy - checking DNS."
  case "$PROVIDER" in
    civo|hetzner)
      wait_for_lb_ip || exit 1
      wait_for_dns
      ;;
    aws)
      aws_wait_for_dns
      echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."
      ;;
    *)
      echo "ARGO-UP: no DNS wait for PROVIDER=$PROVIDER." >&2
      exit 1
      ;;
  esac
  exit 0
fi

install_argocd() {
  local antiaffinity_args=()
  if [ "$PROVIDER" = aws ]; then
    antiaffinity_args=(
      --set global.affinity.nodeAffinity.type=hard
      --set-json 'global.affinity.nodeAffinity.matchExpressions=[{"key":"karpenter.sh/capacity-type","operator":"NotIn","values":["spot"]}]'
    )
  fi
  # dex.enabled=false below: dex is unused (local bcrypt admin password, no
  # SSO) and its bundled image segfaults on some clusters. Kept outside the
  # backslash-continued command below - a `#` comment mid-continuation ends it early.
  # controller.resources was raised from 512Mi/768Mi: the controller was
  # OOMKilled twice at the old limit on a live cluster.
  helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd --create-namespace \
    -f "$REPO_ROOT/gitops/argocd/values.yaml" \
    --set server.service.type=ClusterIP \
    --set configs.params."server\.insecure"=true \
    --set dex.enabled=false \
    --set configs.secret.argocdServerAdminPassword="$ADMIN_PASSWORD_BCRYPT_HASH" \
    --set configs.secret.argocdServerAdminPasswordMtime="2026-08-20T00:00:00Z" \
    --set controller.metrics.enabled=true \
    --set server.metrics.enabled=true \
    --set repoServer.metrics.enabled=true \
    --set applicationSet.metrics.enabled=true \
    --set notifications.metrics.enabled=true \
    --set-json 'controller.resources={"requests":{"cpu":"20m","memory":"768Mi"},"limits":{"memory":"1152Mi"}}' \
    --set-json 'repoServer.resources={"requests":{"cpu":"10m","memory":"192Mi"},"limits":{"memory":"320Mi"}}' \
    --set-json 'server.resources={"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"memory":"128Mi"}}' \
    --set-json 'applicationSet.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'notifications.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'redis.resources={"requests":{"cpu":"5m","memory":"32Mi"},"limits":{"memory":"64Mi"}}' \
    ${antiaffinity_args[@]:+"${antiaffinity_args[@]}"} \
    --wait
}

# The kubelet taints every new node node.cloudprovider.kubernetes.io/uninitialized
# and k3s's CoreDNS does not tolerate it, so cluster DNS stays Pending until a
# cloud controller manager matches each node to its server and clears the taint.
# Argo CD needs cluster DNS to reach its own repository server, which is why
# this is installed by the script and not by Argo (ADR 0036, ADR 0037).
#
# The token reaches the cluster through a pipe, never a temp file.
ensure_hcloud_ccm() {
  echo "ARGO-UP: installing the hcloud cloud controller manager (chart $HCCM_CHART_VERSION)."
  kubectl create secret generic hcloud -n kube-system \
    --from-literal=token="$HCLOUD_TOKEN" \
    --from-literal=network="$HCLOUD_NETWORK_ID" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # clusterCIDR is k3s's own default: the control plane passes no --cluster-cidr,
  # so the chart's Flannel-oriented 10.244.0.0/16 would be wrong. Route
  # management stays off because k3s already runs flannel over the private NIC.
  #
  # --set-string for the routes flag, not --set: a container env value must be
  # a string, and plain --set makes it a bool that server-side apply rejects.
  helm upgrade --install hccm hcloud-cloud-controller-manager \
    --repo https://charts.hetzner.cloud \
    --version "$HCCM_CHART_VERSION" \
    --namespace kube-system \
    --set networking.enabled=true \
    --set networking.clusterCIDR=10.42.0.0/16 \
    --set-string env.HCLOUD_NETWORK_ROUTES_ENABLED.value=false \
    --set resources.requests.cpu=10m \
    --set resources.requests.memory=32Mi \
    --set resources.limits.memory=64Mi \
    --wait
}

# The one gate here that fails by hanging rather than erroring, so it prints
# what it was waiting on. Ready is not enough: a node stays Ready while still
# tainted, and CoreDNS stays Pending until the taint clears.
wait_for_nodes_initialized() {
  local budget="${HETZNER_ARGO_UP_CCM_WATCH_SECONDS:-180}"
  local interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local waited=0 tainted providerless
  while [ "$waited" -lt "$budget" ]; do
    tainted="$(kubectl get nodes \
      -o jsonpath='{range .items[*]}{.spec.taints[?(@.key=="node.cloudprovider.kubernetes.io/uninitialized")].key}{end}' 2>/dev/null || true)"
    providerless="$(kubectl get nodes -o json 2>/dev/null \
      | jq -r '[.items[] | select((.spec.providerID // "") | startswith("hcloud://") | not)] | length' 2>/dev/null || echo 1)"
    if [ -z "$tainted" ] && [ "$providerless" = 0 ]; then
      if kubectl wait --for=condition=Available deployment/coredns \
        -n kube-system --timeout=30s >/dev/null 2>&1; then
        echo "ARGO-UP: every node is cloud-initialized and cluster DNS is up."
        return 0
      fi
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  echo "ARGO-UP: nodes were still uninitialized after ${budget}s - the cloud controller manager never matched them to their servers." >&2
  kubectl get nodes -o wide >&2 || true
  kubectl logs -n kube-system -l app.kubernetes.io/name=hcloud-cloud-controller-manager --tail=50 >&2 || true
  return 1
}

if [ "$PROVIDER" = hetzner ]; then
  ensure_hcloud_ccm
  wait_for_nodes_initialized || exit 1
fi

install_argocd

# Compared by string below to tell a fresh sync's failure from one already on
# the object when this run started. Deliberately not a timestamp comparison -
# RFC3339 arithmetic is not portable across BSD/GNU date.
# Read by argo_watch_root, which this script sources.
# shellcheck disable=SC2034
PRIOR_OPERATION_STARTED_AT="$(kubectl get application root -n argocd \
  -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null || true)"

# No --wait here: the root Application's own health depends on everything
# beneath it in gitops/ reconciling, which can take much longer than a helm
# install timeout is meant to bound. The wait loop below handles that.
aws_install_root_application() {
  # Karpenter bounds a NodePool by vCPU, never by node count, so the operator's
  # worker range is converted here at a fixed vCPU per node. Each pool gets the
  # whole budget rather than a share: when spot capacity runs out, on-demand
  # has to be able to absorb all of it. A range with no room means no dynamic
  # capacity, which is a limit of zero.
  local karpenter_cpu_limit=$(( (MAX_WORKER_NODES - MIN_WORKER_NODES) * $(catalog_vcpu_per_node aws) ))
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=aws \
    --set project="$PROJECT_NAME" \
    --set vpcId="$VPC_ID" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE" \
    --set karpenter.spot.cpuLimit="$karpenter_cpu_limit" \
    --set karpenter.onDemand.cpuLimit="$karpenter_cpu_limit" \
    --set-json karpenter.spot.instanceTypes="$SPOT_KARPENTER_INSTANCE_TYPES_JSON" \
    --set-json karpenter.onDemand.instanceTypes="$ON_DEMAND_KARPENTER_INSTANCE_TYPES_JSON" \
    --set envoyGateway.acmCertificateArn="$ACM_CERTIFICATE_ARN" \
    --set envoyGateway.nlbSubnetIds="$NODE_SUBNET_ID" \
    --set envoyGateway.fqdn="$LAB_FQDN" \
    --set postgres.backup.enabled=true \
    --set postgres.backup.bucket="$BACKUP_BUCKET" \
    --set postgres.backup.serverName="$BACKUP_SERVER_NAME" \
    --set postgres.backup.recoverServerName="$RECOVER_SERVER_NAME"
}

# Written only after the platform is healthy: a failed bring-up must leave the
# previous generation as the one the next run recovers from.
backup_publish_server_name() {
  aws ssm put-parameter --region "$LAB_REGION" \
    --name "/$PROJECT_NAME/$BACKUP_SSM_LAYER/postgres-backup/server_name" \
    --type String --overwrite --value "$BACKUP_SERVER_NAME" >/dev/null
  echo "ARGO-UP: recorded backup server name $BACKUP_SERVER_NAME."
  backup_prune_generations
}

# The plugin's own retentionPolicy prunes only inside a live cluster and only
# within that cluster's serverName, so a generation nothing is running against
# is never pruned by it and would sit until the bucket's 30-day rule expires
# it. This is what actually bounds the stored backup count.
backup_prune_generations() {
  local keep="$POSTGRES_BACKUP_KEEP_GENERATIONS"
  local bucket="${BACKUP_BUCKET:-}" recovered_from="${RECOVER_SERVER_NAME:-}"
  if [ -z "$bucket" ]; then
    return 0
  fi

  # Only generations this script minted are candidates. Anything else in the
  # bucket was put there by hand and is not this function's to delete.
  local generations
  if ! generations="$(aws s3 ls "s3://$bucket/" --region "$LAB_REGION" 2>/dev/null \
    | awk '{print $2}' | tr -d '/' \
    | grep -E '^lab-postgres-[0-9]{8}T[0-9]{6}Z$' | sort)"; then
    echo "ARGO-UP: WARNING - could not list backup generations; skipping the prune." >&2
    return 0
  fi
  [ -z "$generations" ] && return 0

  local total
  total="$(printf '%s\n' "$generations" | wc -l | tr -d ' ')"
  if [ "$total" -le "$keep" ]; then
    echo "ARGO-UP: $total backup generation(s) stored, keeping $keep - nothing to prune."
    return 0
  fi

  local doomed
  doomed="$(printf '%s\n' "$generations" | head -n "$((total - keep))")"
  local generation
  for generation in $doomed; do
    # The timestamp sort puts these oldest-first, but the current and the
    # recovered-from generations are named explicitly rather than trusted to
    # fall outside the window - deleting either loses the running database's
    # own archive.
    if [ "$generation" = "$BACKUP_SERVER_NAME" ] || [ "$generation" = "$recovered_from" ]; then
      continue
    fi
    echo "ARGO-UP: pruning old backup generation $generation..."
    if ! aws s3 rm "s3://$bucket/$generation/" --recursive --region "$LAB_REGION" >/dev/null; then
      echo "ARGO-UP: WARNING - failed to prune $generation; it will expire with the bucket lifecycle rule." >&2
    fi
  done
}

civo_install_root_application() {
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=civo \
    --set project="$PROJECT_NAME" \
    --set capacity.autoscaler.min="$MIN_WORKER_NODES" \
    --set capacity.autoscaler.max="$MAX_WORKER_NODES" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE" \
    --set envoyGateway.fqdn="$LAB_FQDN" \
    --set envoyGateway.reservedIp="$RESERVED_IP" \
    --set envoyGateway.firewallId="$FIREWALL_ID" \
    --set externalDns.txtOwnerId="$PROJECT_NAME" \
    --set awsIdentity.rolesAnywhere.trustAnchorArn="$TRUST_ANCHOR_ARN" \
    --set awsIdentity.rolesAnywhere.profileArn="$PROFILE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.eso="$ESO_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.external-dns="$EXTERNAL_DNS_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.cert-manager="$CERT_MANAGER_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.pgbackup="$PGBACKUP_ROLE_ARN" \
    --set postgres.backup.enabled=true \
    --set postgres.backup.bucket="$BACKUP_BUCKET" \
    --set postgres.backup.serverName="$BACKUP_SERVER_NAME" \
    --set postgres.backup.recoverServerName="$RECOVER_SERVER_NAME" \
    --set tls.issuer="${TLS_ISSUER:-letsencrypt-prod}" \
    --set tls.acmeEmail="${TLS_ACME_EMAIL:-}" \
    --set tls.hostedZoneId="$ROUTE53_ZONE_ID"
}

# Renders gitops/ from the working tree and hands the result to the controller,
# so an uncommitted edit reconciles without a commit or a push. Argo refuses a
# local sync while automated sync is on, which is why the root Application omits
# that block for this target - nothing else syncs it, so this call is required,
# not an optimization. A previous failed sync leaves an operation Running and
# the next one is rejected outright, so clear that first.
local_sync_root() {
  local phase i
  command -v argocd >/dev/null 2>&1 || {
    echo "ARGO-UP: the argocd CLI is required on the local target - https://argo-cd.readthedocs.io/en/stable/cli_installation/" >&2
    return 1
  }
  # The CLI's core mode reads its namespace from the kubeconfig context, and
  # reports a missing argocd-cm rather than a missing namespace when it is wrong.
  kubectl config set-context --current --namespace=argocd >/dev/null
  export ARGOCD_OPTS="--core"

  phase="$(kubectl get application root -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  if [ "$phase" = Running ] || [ "$phase" = Terminating ]; then
    echo "ARGO-UP: clearing a $phase sync operation left by a previous run."
    argocd app terminate-op root >/dev/null 2>&1 || true
    for i in $(seq 1 30); do
      phase="$(kubectl get application root -n argocd -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
      [ "$phase" != Running ] && [ "$phase" != Terminating ] && break
      sleep 2
    done
  fi

  argocd app sync root --local "$REPO_ROOT/gitops" --local-repo-root "$REPO_ROOT" \
    --timeout "${LOCAL_SYNC_TIMEOUT:-600}"
  local rc=$?
  kubectl config set-context --current --namespace=default >/dev/null
  return $rc
}

# Every Application, not just root: see the call site for why root alone is not
# enough on this target.
local_wait_for_children() {
  local watch_seconds="${LOCAL_CHILDREN_WATCH_SECONDS:-900}" elapsed=0 unready last=""
  while [ "$elapsed" -lt "$watch_seconds" ]; do
    unready="$(kubectl get application -n argocd \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status} {end}' 2>/dev/null \
      | tr ' ' '\n' | grep -v '=Synced/Healthy$' | grep -v '^$' | tr '\n' ' ')"
    if [ -z "$unready" ]; then
      return 0
    fi
    if [ "$unready" != "$last" ]; then
      echo "ARGO-UP: [+${elapsed}s] still reconciling: $unready"
      last="$unready"
    fi
    sleep "${ARGO_UP_POLL_INTERVAL:-5}"
    elapsed=$((elapsed + ${ARGO_UP_POLL_INTERVAL:-5}))
  done
  echo "ARGO-UP: timed out after ${watch_seconds}s with Applications not Synced/Healthy: $unready" >&2
  return 1
}

local_install_root_application() {
  ensure_grafana_admin_secret
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=local \
    --set project="$PROJECT_NAME" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE"
  local_sync_root
}

# The civo installer less the values this target has no source for: no
# reserved IP, no LB firewall id, and no backup bucket until HETZ-115/120.
# REGION rather than HCLOUD_LOCATION: region.sh is sourced before provider.sh
# canonicalises the case, and the hcloud API wants it lowercase.
hetzner_install_root_application() {
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=hetzner \
    --set project="$PROJECT_NAME" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE" \
    --set envoyGateway.fqdn="$LAB_FQDN" \
    --set envoyGateway.location="$REGION" \
    --set capacity.autoscaler.min=0 \
    --set capacity.autoscaler.max=$(( MAX_WORKER_NODES - MIN_WORKER_NODES )) \
    --set capacity.autoscaler.nodeType="$WORKER_NODE_TYPE" \
    --set capacity.autoscaler.location="$REGION" \
    --set capacity.autoscaler.sshKeyId="$SSH_KEY_ID" \
    --set externalDns.txtOwnerId="$PROJECT_NAME" \
    --set awsIdentity.rolesAnywhere.trustAnchorArn="$TRUST_ANCHOR_ARN" \
    --set awsIdentity.rolesAnywhere.profileArn="$PROFILE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.eso="$ESO_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.external-dns="$EXTERNAL_DNS_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.cert-manager="$CERT_MANAGER_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.pgbackup="$PGBACKUP_ROLE_ARN" \
    --set postgres.backup.enabled=true \
    --set postgres.backup.bucket="$BACKUP_BUCKET" \
    --set postgres.backup.serverName="$BACKUP_SERVER_NAME" \
    --set postgres.backup.recoverServerName="$RECOVER_SERVER_NAME" \
    --set tls.issuer="${TLS_ISSUER:-letsencrypt-prod}" \
    --set tls.acmeEmail="${TLS_ACME_EMAIL:-}" \
    --set tls.hostedZoneId="$ROUTE53_ZONE_ID"
}

case "$PROVIDER" in
  civo) civo_install_root_application ;;
  hetzner) hetzner_install_root_application ;;
  local) local_install_root_application ;;
  aws) aws_install_root_application ;;
  *) echo "ARGO-UP: no root Application installer for PROVIDER=$PROVIDER." >&2; exit 1 ;;
esac

# Blocks until root is Synced/Healthy, so a 0 exit means the whole platform
# (including Postgres) is really ready. ARGO_UP_WATCH_SECONDS defaults to
# 2700 on both targets: root's retry budget alone is ~16 min worst case.
argo_watch_root || exit 1
if [ "$PROVIDER" != local ]; then
  echo "ARGO-UP: root Synced/Healthy - waiting for external-dns to publish records."
fi
case "$PROVIDER" in
  civo|hetzner)
    wait_for_lb_ip || exit 1
    wait_for_dns
    ;;
  local)
    # No load balancer and no DNS to wait for, but root reports Healthy as soon
    # as its own child Application objects are applied - before those children
    # have pulled an image or run a hook. On the other targets the DNS wait
    # absorbs that gap; here nothing would, so a bring-up would claim success
    # with the platform still starting.
    local_wait_for_children || exit 1
    echo "ARGO-UP: root and every child Synced/Healthy - platform ready."
    echo "ARGO-UP: 'make forward-up' forwards the gateway, and every component"
    echo "ARGO-UP: is then on its own path behind one port:"
    echo "ARGO-UP:   Argo CD  http://localhost:8080          admin / '$LOCAL_ARGOCD_PASSWORD'"
    echo "ARGO-UP:   Grafana  http://localhost:8080/grafana  admin / '$LOCAL_GRAFANA_PASSWORD'"
    echo "ARGO-UP: 'make forward-down' stops it."
    ;;
  aws)
    aws_wait_for_dns
    echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."
    ;;
  *)
    echo "ARGO-UP: no DNS wait for PROVIDER=$PROVIDER." >&2
    exit 1
    ;;
esac
# Writes to SSM and prunes S3. Keyed on the bucket rather than on the provider:
# local takes no backups and mints no server name, and put-parameter rejects
# the empty value that would then be written.
if [ -n "${BACKUP_BUCKET:-}" ]; then
  backup_publish_server_name
fi
