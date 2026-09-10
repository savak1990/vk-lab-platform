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
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.4.0}"
TARGET_REVISION="${TARGET_REVISION:-main}"
REPO_URL="${REPO_URL:-https://github.com/savak1990/vk-lab-platform}"
# Comma-separated; cpu limit is a node-count cap, not a vCPU budget - keep
# it in sync with the instance types' vCPU count when overriding either.
# spot is general workload capacity (several arm64 families/sizes, so a
# capacity-optimized fleet request has a fallback when one instance
# type/AZ combination has no Spot capacity); onDemand is tainted and
# reserved for Postgres, which tolerates it explicitly.
SPOT_KARPENTER_INSTANCE_TYPES="${SPOT_KARPENTER_INSTANCE_TYPES:-t4g.medium,t4g.large,m6g.medium,m6g.large,m7g.medium,m7g.large}"
SPOT_KARPENTER_CPU_LIMIT="${SPOT_KARPENTER_CPU_LIMIT:-4}"
ON_DEMAND_KARPENTER_INSTANCE_TYPES="${ON_DEMAND_KARPENTER_INSTANCE_TYPES:-t4g.medium,t4g.large,m6g.medium,m6g.large,m7g.medium,m7g.large}"
ON_DEMAND_KARPENTER_CPU_LIMIT="${ON_DEMAND_KARPENTER_CPU_LIMIT:-4}"
# Increase-only: Kubernetes rejects a PVC shrink, and shrinking below a
# retained snapshot's restore size leaves the recovered PVC unable to bind.
POSTGRES_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-20Gi}"
SPOT_KARPENTER_INSTANCE_TYPES_JSON="$(jq -Rc 'split(",")' <<< "$SPOT_KARPENTER_INSTANCE_TYPES")"
ON_DEMAND_KARPENTER_INSTANCE_TYPES_JSON="$(jq -Rc 'split(",")' <<< "$ON_DEMAND_KARPENTER_INSTANCE_TYPES")"
# Project-scoped so two environments with different PROJECT_NAME values in
# the same region/account never collide on each other's snapshots.
SNAPSHOT_TAG_FILTERS=("Name=tag:Project,Values=$PROJECT_NAME" "Name=tag:Component,Values=postgres")

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

# One batched get-parameters call, not five round trips. --with-decryption
# is a no-op on the plain String ones, so this serves both types uniformly.
# Bash 3.2 compatible (no associative arrays) - linear scan over 5 items.
aws_resolve_inputs() {
  local ssm_names=(
    "/$PROJECT_NAME/bootstrap/acm/certificate_arn"
    "/$PROJECT_NAME/persistent/vpc/vpc_id"
    "/$PROJECT_NAME/cluster/eks/node_subnet_id"
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
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
  configure_kubeconfig
}

civo_resolve_inputs() {
  civo_token
  local civo_ssm_names=(
    "/$PROJECT_NAME/bootstrap/route53/fqdn"
    "/$PROJECT_NAME/persistent/argocd/admin_password_bcrypt"
    "/$PROJECT_NAME/persistent-civo/reserved-ip/address"
    "/$PROJECT_NAME/cluster-civo/network/lb_firewall_id"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/trust_anchor_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/profile_arn"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/eso"
    "/$PROJECT_NAME/bootstrap/rolesanywhere/role_arn/external-dns"
  )
  local civo_ssm_batch_names=() civo_ssm_batch_values=()
  while IFS=$'\t' read -r name value; do
    civo_ssm_batch_names+=("$name")
    civo_ssm_batch_values+=("$value")
  done < <(aws ssm get-parameters --region "$LAB_REGION" --with-decryption \
    --names "${civo_ssm_names[@]}" --query 'Parameters[].[Name,Value]' --output text)

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
      */admin_password_bcrypt) ADMIN_PASSWORD_BCRYPT_HASH="$found" ;;
      */reserved-ip/address) RESERVED_IP="$found" ;;
      */lb_firewall_id) FIREWALL_ID="$found" ;;
      */rolesanywhere/trust_anchor_arn) TRUST_ANCHOR_ARN="$found" ;;
      */rolesanywhere/profile_arn) PROFILE_ARN="$found" ;;
      */rolesanywhere/role_arn/eso) ESO_ROLE_ARN="$found" ;;
      */rolesanywhere/role_arn/external-dns) EXTERNAL_DNS_ROLE_ARN="$found" ;;
    esac
  done

  configure_kubeconfig
}

if [ "$PROVIDER" = civo ]; then
  civo_resolve_inputs
else
  aws_resolve_inputs
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

civo_wait_for_lb_ip() {
  local watch_seconds="${CIVO_ARGO_UP_LB_WATCH_SECONDS:-300}"
  local poll_interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local elapsed=0 svc_ip=""
  while [ "$elapsed" -lt "$watch_seconds" ]; do
    svc_ip="$(kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [ -n "$svc_ip" ] && [ "$svc_ip" = "$RESERVED_IP" ]; then
      echo "ARGO-UP: Envoy Service LB has the reserved IP ($RESERVED_IP)."
      return 0
    fi
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done
  echo "ARGO-UP: timed out after ${watch_seconds}s waiting for Envoy Service LB to get reserved IP $RESERVED_IP - last observed: ${svc_ip:-none}." >&2
  return 1
}

civo_wait_for_dns() {
  local watch_seconds="${CIVO_ARGO_UP_DNS_WATCH_SECONDS:-60}"
  local poll_interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local elapsed=0 svc_ip="" dig_ip=""
  while [ "$elapsed" -lt "$watch_seconds" ]; do
    svc_ip="$(kubectl get svc -n envoy -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
      -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [ -z "$svc_ip" ] && svc_ip="$RESERVED_IP"
    dig_ip="$(dig +short "argo.$LAB_FQDN" 2>/dev/null | tail -n1 || true)"
    if [ -n "$dig_ip" ] && [ -n "$svc_ip" ] && [ "$dig_ip" = "$svc_ip" ]; then
      echo "ARGO-UP: DNS resolved (argo.<fqdn> -> matches Envoy Service/reserved IP)."
      echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."
      return 0
    fi
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))
  done
  echo "ARGO-UP: DNS not resolved for argo.<fqdn> after ${watch_seconds}s - non-fatal on civo (external-dns isn't implemented yet, so no DNS record is created automatically)." >&2
  echo "ARGO-UP: root Synced/Healthy - platform ready (DNS not yet resolved, non-fatal on civo)."
  return 0
}

ensure_ca_secret() {
  local ca_cert_path="${REPO_ROOT}/secrets/${PROJECT_NAME}/civo-ca-cert.pem"
  [ -f "$ca_cert_path" ] || { echo "ARGO-UP: no CA cert at $ca_cert_path - run 'PROVIDER=civo make civo-ca-init' first." >&2; exit 1; }
  kubectl create namespace cert-manager \
    --dry-run=client -o yaml | kubectl apply -f -
  "$REPO_ROOT/scripts/secret-decrypt.sh" civo-ca-key | \
    kubectl create secret tls civo-workload-ca \
      --cert="$ca_cert_path" \
      --key=/dev/stdin \
      --namespace cert-manager \
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
if [ "$PROVIDER" = civo ]; then
  ensure_ca_secret
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
EXISTING_STATUS="$(kubectl get application root -n argocd \
  -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
if [ "$EXISTING_STATUS" = "Synced/Healthy" ]; then
  echo "ARGO-UP: root Application already Synced/Healthy - checking DNS."
  if [ "$PROVIDER" = civo ]; then
    civo_wait_for_lb_ip || exit 1
    civo_wait_for_dns
  else
    aws_wait_for_dns
    echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."
  fi
  exit 0
fi

# Discovers the latest Postgres EBS snapshot (if any) before pruning -
# deletion below is async, so discovering after pruning would open a race
# window against a snapshot mid-delete. Terraform has no role here: the
# snapshot is created by the running cluster at teardown time, not at
# apply time, so there's nothing for Terraform state to track (ADR 0013).
# A probe error (creds/network) aborts loudly rather than silently
# falling through to a fresh initdb over a good snapshot.
aws_resolve_snapshot() {
  if ! SNAPSHOTS_JSON="$(aws ec2 describe-snapshots --region "$LAB_REGION" --owner-ids self \
    --filters "${SNAPSHOT_TAG_FILTERS[@]}" "Name=status,Values=completed" \
    --query 'sort_by(Snapshots,&StartTime)' --output json)"; then
    echo "ARGO-UP: failed to query AWS for existing Postgres snapshots - aborting rather than risking a false 'fresh start'." >&2
    exit 1
  fi
  RECOVERY_SNAPSHOT_HANDLE="$(echo "$SNAPSHOTS_JSON" | jq -r '.[-1].SnapshotId // ""')"
  if [ -n "$RECOVERY_SNAPSHOT_HANDLE" ]; then
    echo "ARGO-UP: found latest Postgres snapshot $RECOVERY_SNAPSHOT_HANDLE - will recover from it."
  else
    echo "ARGO-UP: no existing Postgres snapshot found - will bootstrap fresh (initdb)."
  fi

  # Safety net for an interrupted prior argo-down (the primary enforcement
  # point for "keep newest 2" is argo-down.sh itself, right after it creates
  # a new snapshot). Re-queried without the status=completed filter, unlike
  # the discovery query above - a still-pending snapshot must still count
  # toward "newest 2" or this miscounts and prunes the wrong one.
  if ! ALL_SNAPSHOTS_JSON="$(aws ec2 describe-snapshots --region "$LAB_REGION" --owner-ids self \
    --filters "${SNAPSHOT_TAG_FILTERS[@]}" \
    --query 'sort_by(Snapshots,&StartTime)' --output json)"; then
    echo "ARGO-UP: failed to query AWS for Postgres snapshots to prune - aborting." >&2
    exit 1
  fi
  OLD_SNAPSHOTS="$(echo "$ALL_SNAPSHOTS_JSON" | jq -r '.[:-2][].SnapshotId')"
  if [ -n "$OLD_SNAPSHOTS" ]; then
    for snapshot_id in $OLD_SNAPSHOTS; do
      aws ec2 delete-snapshot --region "$LAB_REGION" --snapshot-id "$snapshot_id"
      echo "ARGO-UP: pruned old snapshot $snapshot_id"
    done
  fi
}

if [ "$PROVIDER" = civo ]; then
  RECOVERY_SNAPSHOT_HANDLE="$(civo_recovery_handle)"
else
  aws_resolve_snapshot
fi

install_argocd() {
  # dex is unused (local bcrypt admin password, no SSO configured) and its
  # bundled image segfaults on some clusters - disabled rather than fought.
  local antiaffinity_args=()
  if [ "$PROVIDER" != civo ]; then
    antiaffinity_args=(
      --set global.affinity.nodeAffinity.type=hard
      --set-json 'global.affinity.nodeAffinity.matchExpressions=[{"key":"karpenter.sh/capacity-type","operator":"NotIn","values":["spot"]}]'
    )
  fi
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
    --set-json 'controller.resources={"requests":{"cpu":"20m","memory":"512Mi"},"limits":{"memory":"768Mi"}}' \
    --set-json 'repoServer.resources={"requests":{"cpu":"10m","memory":"192Mi"},"limits":{"memory":"320Mi"}}' \
    --set-json 'server.resources={"requests":{"cpu":"10m","memory":"64Mi"},"limits":{"memory":"128Mi"}}' \
    --set-json 'applicationSet.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'dex.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'notifications.resources={"requests":{"cpu":"5m","memory":"48Mi"},"limits":{"memory":"96Mi"}}' \
    --set-json 'redis.resources={"requests":{"cpu":"5m","memory":"32Mi"},"limits":{"memory":"64Mi"}}' \
    ${antiaffinity_args[@]:+"${antiaffinity_args[@]}"} \
    --wait
}

install_argocd

# Compared by string below to tell a fresh sync's failure from one already on
# the object when this run started. Deliberately not a timestamp comparison -
# RFC3339 arithmetic is not portable across BSD/GNU date.
PRIOR_OPERATION_STARTED_AT="$(kubectl get application root -n argocd \
  -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null || true)"

# No --wait here: the root Application's own health depends on everything
# beneath it in gitops/ reconciling, which can take much longer than a helm
# install timeout is meant to bound. The wait loop below handles that.
aws_install_root_application() {
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=aws \
    --set project="$PROJECT_NAME" \
    --set vpcId="$VPC_ID" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.recoverySnapshotHandle="$RECOVERY_SNAPSHOT_HANDLE" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE" \
    --set karpenter.spot.cpuLimit="$SPOT_KARPENTER_CPU_LIMIT" \
    --set karpenter.onDemand.cpuLimit="$ON_DEMAND_KARPENTER_CPU_LIMIT" \
    --set-json karpenter.spot.instanceTypes="$SPOT_KARPENTER_INSTANCE_TYPES_JSON" \
    --set-json karpenter.onDemand.instanceTypes="$ON_DEMAND_KARPENTER_INSTANCE_TYPES_JSON" \
    --set envoyGateway.acmCertificateArn="$ACM_CERTIFICATE_ARN" \
    --set envoyGateway.nlbSubnetIds="$NODE_SUBNET_ID" \
    --set envoyGateway.fqdn="$LAB_FQDN"
}

civo_install_root_application() {
  helm upgrade --install root-application "$REPO_ROOT/gitops/bootstrap" \
    --namespace argocd \
    --server-side=true --force-conflicts \
    --set target=civo \
    --set project="$PROJECT_NAME" \
    --set repoURL="$REPO_URL" \
    --set targetRevision="$TARGET_REVISION" \
    --set postgres.recoverySnapshotHandle="$RECOVERY_SNAPSHOT_HANDLE" \
    --set postgres.storageSize="$POSTGRES_STORAGE_SIZE" \
    --set envoyGateway.fqdn="$LAB_FQDN" \
    --set envoyGateway.reservedIp="$RESERVED_IP" \
    --set envoyGateway.firewallId="$FIREWALL_ID" \
    --set externalDns.txtOwnerId="$PROJECT_NAME" \
    --set awsIdentity.rolesAnywhere.trustAnchorArn="$TRUST_ANCHOR_ARN" \
    --set awsIdentity.rolesAnywhere.profileArn="$PROFILE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.eso="$ESO_ROLE_ARN" \
    --set awsIdentity.rolesAnywhere.roleArns.external-dns="$EXTERNAL_DNS_ROLE_ARN"
}

if [ "$PROVIDER" = civo ]; then
  civo_install_root_application
else
  aws_install_root_application
fi

# Every child Application (cnpg-operator, karpenter, ...) with its own
# sync/health, so a single stuck one is visible by name instead of only
# root's aggregate rollup.
print_app_status() {
  kubectl get applications -n argocd -o json 2>/dev/null \
    | jq -r '.items[] | "  \(.metadata.name): sync=\(.status.sync.status // "Unknown") health=\(.status.health.status // "Unknown")"'
}

# root's own directly-templated resources (Cluster, NodePools, ...)
# not yet Healthy. Excludes kinds with no health concept at all (ServiceAccount,
# Role, RoleBinding, ...) unless they're also not Synced - jsonpath's
# @.health.status!="Healthy" matches a null health equally, which made every
# such resource show as permanently "pending" regardless of actual state.
pending_resources() {
  kubectl get application root -n argocd -o json 2>/dev/null | jq -r '
    [.status.resources[]?
      | select((.health.status // "") != "Healthy")
      | select((.health.status // "") != "" or .status != "Synced")
      | "\(.kind)/\(.name)=\(.status)(\(.health.status // "n/a"))"]
    | join(" ")'
}

# phase/startedAt/retryCount/message as one tab-separated line. Argo keeps
# phase at "Running" for the whole syncPolicy.retry sequence, so a terminal
# "Failed" here really means the retry budget is spent.
operation_state() {
  kubectl get application root -n argocd -o json 2>/dev/null | jq -r '
    (.status.operationState // {})
    | [.phase // "", .startedAt // "", .retryCount // 0,
       (.message // "" | gsub("\n"; " "))]
    | @tsv'
}

# Blocks until root is Synced/Healthy, so a 0 exit means the whole platform
# (including Postgres) is really ready. Only prints when something changes,
# to stay readable over a long recovery-from-snapshot bootstrap.
# TODO(civo): shorter default kept deliberately - root does reach
# Synced/Healthy here now, but that hasn't been proven stable across
# repeated runs yet.
if [ "$PROVIDER" = civo ]; then
  WATCH_SECONDS="${ARGO_UP_WATCH_SECONDS:-300}"
else
  WATCH_SECONDS="${ARGO_UP_WATCH_SECONDS:-2700}"
fi
POLL_INTERVAL="${ARGO_UP_POLL_INTERVAL:-5}"
elapsed=0
last_state=""
overall=""
while [ "$elapsed" -lt "$WATCH_SECONDS" ]; do
  overall="$(kubectl get application root -n argocd \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
  pending="$(pending_resources)"
  state="$overall|$pending"
  if [ "$state" != "$last_state" ]; then
    echo "ARGO-UP: root ${overall:-pending} - still reconciling: ${pending:-none}"
    echo "ARGO-UP: applications:"
    print_app_status
    last_state="$state"
  fi
  [ "$overall" = "Synced/Healthy" ] && break

  IFS=$'\t' read -r op_phase op_started op_retries op_message < <(operation_state) || true
  if { [ "$op_phase" = "Failed" ] || [ "$op_phase" = "Error" ]; } \
    && [ "$op_started" != "$PRIOR_OPERATION_STARTED_AT" ]; then
    echo "ARGO-UP: root sync $op_phase after $op_retries retries - Argo will not re-run it for this revision." >&2
    echo "ARGO-UP: $op_message" >&2
    echo "ARGO-UP: still reconciling: ${pending:-none}" >&2
    echo "ARGO-UP: applications:" >&2
    print_app_status >&2
    exit 1
  fi

  sleep "$POLL_INTERVAL"
  elapsed=$((elapsed + POLL_INTERVAL))
done

if [ "$overall" != "Synced/Healthy" ]; then
  echo "ARGO-UP: timed out after ${WATCH_SECONDS}s waiting for root to become Synced/Healthy - still reconciling: ${pending:-none}" >&2
  echo "ARGO-UP: applications:" >&2
  print_app_status >&2
  exit 1
fi
echo "ARGO-UP: root Synced/Healthy - waiting for external-dns to publish records."
if [ "$PROVIDER" = civo ]; then
  civo_wait_for_lb_ip || exit 1
  civo_wait_for_dns
else
  aws_wait_for_dns
  echo "ARGO-UP: root Synced/Healthy and DNS resolved - platform ready."
fi
