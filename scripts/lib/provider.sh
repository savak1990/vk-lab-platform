# shellcheck shell=bash
# Provider defaults mirror the Makefile: PROVIDER selects the project name,
# subdomain, and disposable-cluster stack directory. aws is the default and
# is unchanged from before this variable existed.

PROVIDER_SH_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export PROVIDER="${PROVIDER:-aws}"

if [ "$PROVIDER" = "civo" ]; then
  export PROJECT_NAME="${PROJECT_NAME:-vk-civo-lab}"
  export SUBDOMAIN="${SUBDOMAIN:-civo}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster-civo}"
  export CLUSTER_NAME="${CLUSTER_NAME:-$PROJECT_NAME}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-persistent-civo}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-acm}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-vpc backups}"
  export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-persistent-civo}"
elif [ "$PROVIDER" = "local" ]; then
  export PROJECT_NAME="${PROJECT_NAME:-vk-local-lab}"
  export SUBDOMAIN="${SUBDOMAIN:-local}"
  export CLUSTER_DIR="${CLUSTER_DIR:-}"
  export CLUSTER_NAME="${CLUSTER_NAME:-$PROJECT_NAME}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-}"
  export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-}"
elif [ "$PROVIDER" = "hetzner" ]; then
  export PROJECT_NAME="${PROJECT_NAME:-vk-hetzner-lab}"
  export SUBDOMAIN="${SUBDOMAIN:-hz}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster-hetzner}"
  export CLUSTER_NAME="${CLUSTER_NAME:-$PROJECT_NAME}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-persistent-hetzner}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-acm}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-vpc}"
  export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-persistent}"
else
  export PROJECT_NAME="${PROJECT_NAME:-vk-lab-platform}"
  export SUBDOMAIN="${SUBDOMAIN:-lab}"
  export CLUSTER_DIR="${CLUSTER_DIR:-cluster}"
  export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT_NAME}-eks}"
  export PERSISTENT_EXTRA_DIR="${PERSISTENT_EXTRA_DIR:-}"
  export BOOTSTRAP_EXCLUDE="${BOOTSTRAP_EXCLUDE:-}"
  export PERSISTENT_EXCLUDE="${PERSISTENT_EXCLUDE:-}"
  export BACKUP_SSM_LAYER="${BACKUP_SSM_LAYER:-persistent}"
fi

# The cluster's shape. Defaults come from the catalogue so an unset
# variable reproduces the behaviour that predates them; operator input is
# canonicalised here so every consumer sees the provider's own spelling,
# whatever case was typed. An unrecognised value is left alone for
# require_valid_node_config to reject with a message worth reading.
# shellcheck source=catalog.sh
source "$PROVIDER_SH_REPO_ROOT/scripts/lib/catalog.sh"

if catalog_takes_node_inputs "$PROVIDER"; then
  export REGION="${REGION:-$(catalog_default_region "$PROVIDER")}"
  # Region first: the node-type default is keyed by it.
  if _provider_canonical="$(catalog_canonical_region "$PROVIDER" "$REGION")"; then
    export REGION="$_provider_canonical"
  fi
  export WORKER_NODE_TYPE="${WORKER_NODE_TYPE:-$(catalog_default_worker_node_type "$PROVIDER" "$REGION")}"
  export MIN_WORKER_NODES="${MIN_WORKER_NODES:-$(catalog_default_min_workers "$PROVIDER")}"
  export MAX_WORKER_NODES="${MAX_WORKER_NODES:-$(catalog_default_max_workers "$PROVIDER")}"
  export CONTROL_PLANE_NODE_TYPE="${CONTROL_PLANE_NODE_TYPE:-$(catalog_default_control_plane_node_type "$PROVIDER")}"

  if _provider_canonical="$(catalog_canonical_node_type "$PROVIDER" "$REGION" "$WORKER_NODE_TYPE")"; then
    export WORKER_NODE_TYPE="$_provider_canonical"
  fi
  if [ -n "$CONTROL_PLANE_NODE_TYPE" ] &&
    _provider_canonical="$(catalog_canonical_node_type "$PROVIDER" "$REGION" "$CONTROL_PLANE_NODE_TYPE")"; then
    export CONTROL_PLANE_NODE_TYPE="$_provider_canonical"
  fi
  unset _provider_canonical
fi

# One negated --filter per unit named in PERSISTENT_EXCLUDE, one argument per line.
persistent_exclude_filters() {
  local unit
  for unit in $PERSISTENT_EXCLUDE; do
    printf -- '--filter\n!./%s\n' "$unit"
  done
}

# Decrypts the Civo API token and exports it as CIVO_TOKEN. Masks it in
# GitHub Actions logs; never echoes it anywhere else.
civo_token() {
  local token
  token="$(SECRET_SCOPE=global "$PROVIDER_SH_REPO_ROOT/scripts/secret-decrypt.sh" civo-token)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$token"
  fi
  export CIVO_TOKEN="$token"
}

# civo CLI writes token to ~/.civo.json as a side effect; CIVO_CONFIG redirects to throwaway tmpfile.
# || status=$? prevents set -e interference on failure.
civo_cli() {
  local tmp status=0
  tmp="$(mktemp)"
  CIVO_CONFIG="$tmp" civo "$@" || status=$?
  rm -f "$tmp"
  return "$status"
}

# civo <resource> ls -o json returns plain text "No resources..." instead of [] on zero results.
# Check shape before piping to jq to avoid aborting under set -e.
civo_list_names() {
  local resource="$1"
  shift
  local raw
  raw="$(civo_cli "$resource" ls -o json --region "$CIVO_REGION" "$@" 2>/dev/null || true)"
  case "$raw" in
    \[*) echo "$raw" | jq -r '.[].name' ;;
  esac
}

# Decrypts the Hetzner API token and exports it as HCLOUD_TOKEN. Masks it in
# GitHub Actions logs; never echoes it anywhere else.
hcloud_token() {
  local token
  token="$(SECRET_SCOPE=global "$PROVIDER_SH_REPO_ROOT/scripts/secret-decrypt.sh" hetzner-token)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::add-mask::$token"
  fi
  export HCLOUD_TOKEN="$token"
}

# hcloud is stateless with HCLOUD_TOKEN set; an empty config keeps a stray
# operator context out of the run, and nothing is ever written to disk.
hcloud_cli() {
  HCLOUD_CONFIG=/dev/null hcloud "$@"
}

# Names of this project's <resource>s, narrowed by extra key=value label terms.
# CLIs before 1.55 print null rather than [] for an empty list.
hcloud_list_names() {
  local resource="$1" selector="project=$PROJECT_NAME"
  shift
  if [ $# -gt 0 ]; then
    selector="$selector,$(IFS=,; printf '%s' "$*")"
  fi
  hcloud_cli "$resource" list -o json -l "$selector" | jq -r '(. // [])[].name'
}

# The cloud controller manager labels nothing it creates, so the name
# annotation's project prefix is the only thing a sweep can match on.
wait_for_lb_gone() {
  local deadline listed remaining="" answered=no
  hcloud_token
  deadline=$(( $(date +%s) + ${HETZNER_LB_GONE_SECONDS:-180} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # An unanswered API call prints nothing, which would otherwise read as an
    # empty list and report a billing object gone while it is still running.
    if listed="$(hcloud_cli load-balancer list -o json 2>/dev/null)"; then
      answered=yes
      remaining="$(printf '%s' "$listed" | jq -r '(. // [])[].name' | grep -- "^${PROJECT_NAME}-" || true)"
      if [ -z "$remaining" ]; then
        echo "ARGO-DOWN: hcloud load balancer confirmed gone."
        return 0
      fi
    else
      answered=no
      echo "ARGO-DOWN: the hcloud API did not answer; retrying." >&2
    fi
    sleep "${POLL_INTERVAL:-5}"
  done
  if [ "$answered" = no ]; then
    echo "ARGO-DOWN: the hcloud API never answered within ${HETZNER_LB_GONE_SECONDS:-180}s, so whether a" >&2
    echo "ARGO-DOWN: load balancer survives is unknown; check 'hcloud load-balancer list' before retrying." >&2
  else
    echo "ARGO-DOWN: load balancer(s) still present after ${HETZNER_LB_GONE_SECONDS:-180}s: $remaining" >&2
    echo "ARGO-DOWN: they bill until deleted; delete them by hand before retrying." >&2
  fi
  return 1
}

# The control plane's public address, published to SSM by the k8s unit. Absent
# means the stack is down, which is a "no" to every caller, never an error.
hetzner_cp_ip() {
  local ip
  ip="$(aws ssm get-parameter --region "$LAB_REGION" \
    --name "/$PROJECT_NAME/cluster-hetzner/k8s/control_plane_ip" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  [ -n "$ip" ] && [ "$ip" != "None" ] || return 1
  printf '%s' "$ip"
}

# Runs one command on a node as root. The subshell's trap removes the decrypted
# key even on Ctrl-C. That costs one KMS decrypt per call, so a caller that polls
# runs its loop on the far side of a single call, never this in a local loop.
hetzner_ssh() {
  local ip="${1:?hetzner_ssh: ip required}"
  shift
  (
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' EXIT INT TERM
    "$PROVIDER_SH_REPO_ROOT/scripts/secret-decrypt.sh" hetzner-ssh-key >"$dir/key" || exit 1
    chmod 600 "$dir/key"
    # accept-new, into a known_hosts this call throws away: the operator's own
    # file must not collect entries for servers that live for one bring-up.
    ssh -i "$dir/key" -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$dir/known_hosts" -o ConnectTimeout=10 \
      "root@$ip" "$@"
  )
}

cluster_exists() {
  case "$PROVIDER" in
    civo)
      civo_token
      civo_cli kubernetes show "$CLUSTER_NAME" --region "$CIVO_REGION" >/dev/null 2>&1
      ;;
    hetzner)
      # Two parts, because a server that booted is not yet a cluster: the k3s
      # install runs from cloud-init and can fail, leaving the server running.
      # Anything unreadable answers no, so teardown destroys rather than refuse.
      local cp_ip
      hcloud_token
      [ -n "$(hcloud_list_names server role=control-plane 2>/dev/null)" ] || return 1
      cp_ip="$(hetzner_cp_ip)" || return 1
      hetzner_ssh "$cp_ip" 'test -f /etc/rancher/k3s/k3s.yaml' >/dev/null 2>&1
      ;;
    local)
      kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
      ;;
    *)
      aws eks describe-cluster --name "$CLUSTER_NAME" --region "$LAB_REGION" >/dev/null 2>&1
      ;;
  esac
}

# Points this process's kubectl and helm at a repo-local kubeconfig instead of
# the operator's own, so a lifecycle run never changes the context they work in.
use_isolated_kubeconfig() {
  local path="${1:-.kube/${PROJECT_NAME}.config}"
  case "$path" in
    /*) ;;
    *) path="$PROVIDER_SH_REPO_ROOT/$path" ;;
  esac
  mkdir -p "$(dirname "$path")"
  # Deliberately not exported: an inherited marker would let the guard pass in a
  # shell that never called this function. KUBECONFIG is exported, for kubectl.
  LAB_KUBECONFIG="$path"
  export KUBECONFIG="$path"
}

# An unqualified kubectl call outside isolation reaches whatever cluster the
# operator selected. An empty-string check is not enough - they can export
# KUBECONFIG for their own session.
require_isolated_kubeconfig() {
  if [ -z "${LAB_KUBECONFIG:-}" ] || [ "${KUBECONFIG:-}" != "$LAB_KUBECONFIG" ]; then
    echo "${FUNCNAME[1]:-this function} runs kubectl: call use_isolated_kubeconfig first" >&2
    return 1
  fi
}

# Refuses to act on anything but a cluster whose API server is on this machine.
# The local lifecycle scripts take a cluster name from the environment, so a
# stale or hand-edited kubeconfig would otherwise let PROVIDER=local reach a
# real cluster.
require_local_context() {
  local server
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  case "$server" in
    https://127.0.0.1:* | https://localhost:* | https://0.0.0.0:* | "https://[::1]:"*) return 0 ;;
  esac
  echo "require_local_context: refusing to act - context server '$server' is not a local kind cluster" >&2
  return 1
}

# Writes the control plane's k3s.yaml to $2, waiting for it to appear.
#
# Two waits are needed and only one used to be here. cloud-init takes a minute
# or two to install k3s, so the file wait runs on the far side of the
# connection - one decrypt, one call. But sshd answers nothing at all on a
# server created seconds ago, and ssh then fails to connect rather than running
# that remote wait, which was reported as a k3s timeout it never performed.
# A connection that never opened is retried here.
hetzner_fetch_k3s_kubeconfig() {
  local ip="${1:?hetzner_fetch_k3s_kubeconfig: ip required}"
  local out="${2:?hetzner_fetch_k3s_kubeconfig: output path required}"
  local budget="${HETZNER_K3S_WAIT_SECONDS:-600}"
  local poll="${HETZNER_K3S_POLL_INTERVAL:-5}"
  local deadline=$(( $(date +%s) + budget ))
  local connected=false
  local remaining attempts rc

  while :; do
    remaining=$(( deadline - $(date +%s) ))
    [ "$remaining" -le 0 ] && break
    attempts=$(( remaining / poll ))
    [ "$attempts" -lt 1 ] && attempts=1

    hetzner_ssh "$ip" "i=0; while [ \$i -lt $attempts ]; do if [ -s /etc/rancher/k3s/k3s.yaml ]; then cat /etc/rancher/k3s/k3s.yaml; exit 0; fi; i=\$((i+1)); sleep $poll; done; exit 1" >"$out" 2>/dev/null
    rc=$?

    if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
      return 0
    fi
    # 255 is ssh's own "could not connect". Any other status came back from the
    # remote side, so the wait did run and the file is genuinely not there.
    if [ "$rc" -ne 255 ]; then
      connected=true
      break
    fi
    sleep "$poll"
  done

  if [ "$connected" = true ]; then
    echo "hetzner_fetch_k3s_kubeconfig: /etc/rancher/k3s/k3s.yaml did not appear on $ip within ${budget}s." >&2
  else
    echo "hetzner_fetch_k3s_kubeconfig: no ssh connection to $ip within ${budget}s - the server may still be booting." >&2
  fi
  return 1
}

# k3s writes its kubeconfig only on the control plane, naming every object
# "default" and pointing at 127.0.0.1. The API server certificate already
# carries the public address, so the server URL is all that has to change for
# the file to work from here; the names are rewritten so a merge into an
# operator's own config cannot collide with somebody else's "default".
hetzner_kubeconfig() {
  local target="${1:-${KUBECONFIG:-$HOME/.kube/config}}"
  local ctx="${PROJECT_NAME}-hetzner"
  local ip tmp merged status=0

  if ! ip="$(hetzner_cp_ip)"; then
    echo "hetzner_kubeconfig: no control_plane_ip in SSM - has 'make cluster-up' run?" >&2
    return 1
  fi

  tmp="$(mktemp)"
  if ! hetzner_fetch_k3s_kubeconfig "$ip" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  CTX="$ctx" SERVER="https://$ip:6443" yq -i '
    .clusters[0].name = strenv(CTX) |
    .clusters[0].cluster.server = strenv(SERVER) |
    .users[0].name = strenv(CTX) |
    .contexts[0].name = strenv(CTX) |
    .contexts[0].context.cluster = strenv(CTX) |
    .contexts[0].context.user = strenv(CTX) |
    ."current-context" = strenv(CTX)' "$tmp" || { rm -f "$tmp"; return 1; }

  mkdir -p "$(dirname "$target")"
  merged="$(mktemp)"
  if [ -s "$target" ]; then
    # The first file to set a name wins a flatten merge, so an entry left by an
    # earlier cluster would shadow this one and keep its dead server address.
    kubectl --kubeconfig "$target" config delete-context "$ctx" >/dev/null 2>&1 || true
    kubectl --kubeconfig "$target" config delete-cluster "$ctx" >/dev/null 2>&1 || true
    kubectl --kubeconfig "$target" config delete-user "$ctx" >/dev/null 2>&1 || true
    KUBECONFIG="$target:$tmp" kubectl config view --flatten >"$merged" || status=1
  else
    cp "$tmp" "$merged" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    cp "$merged" "$target" && chmod 600 "$target"
  fi
  rm -f "$tmp" "$merged"
  [ "$status" -eq 0 ] || return 1

  kubectl --kubeconfig "$target" config use-context "$ctx" >/dev/null
}

# On civo, renames context to ${PROJECT_NAME}-civo (no --context-name flag); deletes target context first
# to guard against reruns. On AWS, uses update-kubeconfig with the eks-access-identity role.
configure_kubeconfig() {
  local kubeconfig="${1:-}"
  local kcfg=()
  [ -n "$kubeconfig" ] && kcfg=(--kubeconfig "$kubeconfig")

  if [ "$PROVIDER" = "civo" ]; then
    civo_token
    if [ -n "$kubeconfig" ]; then
      civo_cli kubernetes config "$CLUSTER_NAME" --save --local-path "$kubeconfig" --region "$CIVO_REGION" >/dev/null || return 1
    else
      civo_cli kubernetes config "$CLUSTER_NAME" --save --region "$CIVO_REGION" >/dev/null || return 1
    fi
    local raw_context
    raw_context="$(echo "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]')"
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config delete-context "${PROJECT_NAME}-civo" >/dev/null 2>&1 || true
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config rename-context "$raw_context" "${PROJECT_NAME}-civo" >/dev/null
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config use-context "${PROJECT_NAME}-civo" >/dev/null
  elif [ "$PROVIDER" = "local" ]; then
    kind export kubeconfig --name "$CLUSTER_NAME" \
      ${kubeconfig:+--kubeconfig "$kubeconfig"} >/dev/null || return 1
  elif [ "$PROVIDER" = "hetzner" ]; then
    hetzner_kubeconfig "$kubeconfig" || return 1
  else
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$LAB_REGION" --alias "$CLUSTER_NAME" \
      --role-arn "$(aws iam get-role --role-name eks-access-identity --query Role.Arn --output text)" \
      ${kcfg[@]:+"${kcfg[@]}"} >/dev/null || return 1
  fi
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-context --current --namespace=default >/dev/null
}

# True once the API server answers, retrying through a transient outage rather
# than refusing on one bad probe. Teardown's callers abort when this fails, so
# a single blip would otherwise orphan load balancers and nodes - and a blip is
# most likely exactly here, right after a node pool resize.
api_reachable() {
  local attempts="${API_REACHABLE_ATTEMPTS:-6}" interval="${API_REACHABLE_INTERVAL:-10}" i=1
  while [ "$i" -le "$attempts" ]; do
    if kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
      [ "$i" -gt 1 ] && echo "API reachable again after $i attempts." >&2
      return 0
    fi
    [ "$i" -lt "$attempts" ] && sleep "$interval"
    i=$((i + 1))
  done
  return 1
}

# Terraform returns when the servers boot; k3s installs itself afterwards from
# cloud-init, so a bring-up is not finished until every node has joined. Ready
# is the whole assertion - nodes stay tainted uninitialized until HETZ-045's
# cloud controller manager runs, so waiting for schedulable would never return.
wait_for_nodes_ready() {
  # Only hetzner adds one: its control plane is a node of this cluster, tainted
  # and scheduling nothing but registering and reporting Ready like any other.
  # Every other target's control plane belongs to the cloud and never appears.
  local expected="${MIN_WORKER_NODES:-1}"
  [ "${PROVIDER:-}" = hetzner ] && expected=$(( expected + 1 ))
  local budget="${HETZNER_NODE_READY_SECONDS:-600}"
  local interval="${ARGO_UP_POLL_INTERVAL:-5}"
  local deadline=$((SECONDS + budget))
  local nodes total ready

  echo "CLUSTER-UP: waiting for $expected node(s) to report Ready (up to ${budget}s)..."
  while [ "$SECONDS" -lt "$deadline" ]; do
    nodes="$(kubectl get nodes --no-headers 2>/dev/null || true)"
    total="$(printf '%s' "$nodes" | grep -c . || true)"
    ready="$(printf '%s' "$nodes" | awk '$2 ~ /^Ready/' | grep -c . || true)"
    # At least the fixed pool, and every node present Ready. Equality would
    # never hold once the autoscaler has added one, so a re-run over a scaled
    # cluster would wait out the whole budget and then fail.
    if [ "$total" -ge "$expected" ] && [ "$ready" -eq "$total" ]; then
      echo "CLUSTER-UP: all $total node(s) Ready."
      return 0
    fi
    sleep "$interval"
  done

  echo "CLUSTER-UP: ERROR - only $ready of $expected node(s) Ready after ${budget}s." >&2
  kubectl get nodes -o wide >&2 2>&1 || true
  hetzner_node_diagnostics
  return 1
}

# One remote command per server that never registered: the decrypt is per call,
# so everything worth reading is collected in a single shell on the far side.
hetzner_node_diagnostics() {
  local registered srv ip
  registered=" $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true) "
  for srv in $(hcloud_list_names server lifecycle=disposable 2>/dev/null); do
    case "$registered" in *" $srv "*) continue ;; esac
    ip="$(hcloud_cli server ip "$srv" 2>/dev/null || true)"
    [ -n "$ip" ] || continue
    echo "--- $srv ($ip) never registered ---" >&2
    hetzner_ssh "$ip" 'cloud-init status --long; echo; tail -n 50 /var/log/cloud-init-output.log; echo; journalctl -u k3s -u k3s-agent --no-pager -n 50' >&2 2>&1 || true
  done
}

# On AWS, eks-test-identity maps to the read-only role through its EKS access
# entry. Every other target has no IAM to map a read-only identity to, so the
# E2E suite gets a short-lived token for the e2e-test ServiceAccount instead.
configure_test_kubeconfig() {
  local kubeconfig="${1:-}"
  local kcfg=()
  [ -n "$kubeconfig" ] && kcfg=(--kubeconfig "$kubeconfig")

  if [ "$PROVIDER" = "aws" ]; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$LAB_REGION" --alias "${CLUSTER_NAME}-test" \
      --role-arn "$(aws iam get-role --role-name eks-test-identity --query Role.Arn --output text)" \
      ${kcfg[@]:+"${kcfg[@]}"} >/dev/null || return 1
    kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-context --current --namespace=default >/dev/null
    return
  fi

  local admin_context="${PROJECT_NAME}-${PROVIDER}" test_context="${PROJECT_NAME}-${PROVIDER}-test"
  if [ "$PROVIDER" = "local" ]; then
    admin_context="kind-${CLUSTER_NAME}"
    test_context="${PROJECT_NAME}-local-test"
  fi
  local cluster token
  configure_kubeconfig "$kubeconfig"
  cluster="$(kubectl ${kcfg[@]:+"${kcfg[@]}"} config view -o jsonpath="{.contexts[?(@.name==\"$admin_context\")].context.cluster}")"
  if [ -z "$cluster" ]; then
    echo "configure_test_kubeconfig: kubeconfig has no context $admin_context" >&2
    return 1
  fi
  if ! token="$(kubectl ${kcfg[@]:+"${kcfg[@]}"} --context "$admin_context" create token e2e-test -n e2e --duration=1h)"; then
    echo "configure_test_kubeconfig: cannot create a token for ServiceAccount e2e/e2e-test - has 'make argo-up' synced the platform?" >&2
    return 1
  fi
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-credentials "$test_context" --token="$token" >/dev/null
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config set-context "$test_context" --cluster="$cluster" --user="$test_context" --namespace=default >/dev/null
  kubectl ${kcfg[@]:+"${kcfg[@]}"} config use-context "$test_context" >/dev/null
}

# The previous bring-up's serverName, read from the given SSM layer. Absent on
# the first bring-up; empty means there is nothing to recover from.
backup_recovery_handle() {
  local value
  value="$(aws ssm get-parameter --region "$LAB_REGION" \
    --name "/$PROJECT_NAME/$1/postgres-backup/server_name" \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  [ "$value" = "None" ] && value=""
  printf '%s' "$value"
}

# Best effort by design: continuous WAL archiving already made every committed
# row durable before teardown started, so a failed final base backup costs
# replay time, not data. Aborting here would leave a paid cluster running.
backup_teardown() {
  require_isolated_kubeconfig || return 1
  local ns=cnpg-system
  if ! kubectl get cluster lab-postgres -n "$ns" >/dev/null 2>&1; then
    echo "ARGO-DOWN: no lab-postgres Cluster found - nothing to back up."
    return 0
  fi
  if ! kubectl get objectstore lab-postgres-backups -n "$ns" >/dev/null 2>&1; then
    echo "ARGO-DOWN: no barman ObjectStore - backups are not configured, nothing to back up."
    return 0
  fi

  # Read before anything is attempted, not after a failure: this is what
  # decides whether a best-effort backup is a safe choice or a loud warning
  # that writes are about to be destroyed.
  local archiving
  archiving="$(backup_archiving_status "$ns")"
  if [ "$archiving" != "True" ]; then
    {
      echo "ARGO-DOWN: WARNING - WAL archiving is not healthy (ContinuousArchiving=${archiving:-unknown})."
      echo "ARGO-DOWN: WARNING - writes made since it stopped have NOT reached S3 and are destroyed by this teardown."
      echo "ARGO-DOWN: WARNING - $(backup_archiving_since "$ns")"
      echo "ARGO-DOWN: WARNING - the pre-teardown backup is attempted anyway, but do not rely on it."
    } >&2
  fi

  local poll="${ARGO_DOWN_POLL_INTERVAL:-5}"
  local timeout="${ARGO_DOWN_BACKUP_TIMEOUT:-600s}"
  timeout="${timeout%s}"

  # Closes the window between the last row written and the last segment
  # archived: without this the tail of WAL sits in an unarchived partial
  # segment that dies with the volume.
  local primary
  primary="$(kubectl get pod -n "$ns" -l cnpg.io/cluster=lab-postgres,cnpg.io/instanceRole=primary \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$primary" ]; then
    echo "ARGO-DOWN: forcing a WAL switch on $primary so the final segment is archived..."
    kubectl exec "$primary" -n "$ns" -c postgres -- \
      psql -U postgres -tAc 'select pg_switch_wal()' >/dev/null 2>&1 \
      || echo "ARGO-DOWN: WARNING - could not force a WAL switch; continuing." >&2
  else
    echo "ARGO-DOWN: WARNING - no primary pod found for lab-postgres; skipping the WAL switch." >&2
  fi

  local backup_name
  backup_name="lab-postgres-teardown-$(date +%s 2>/dev/null || echo manual)"
  echo "ARGO-DOWN: creating a pre-teardown plugin backup ($backup_name)..."
  if ! kubectl apply -f - <<EOF >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $backup_name
  namespace: $ns
spec:
  cluster:
    name: lab-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
  then
    backup_teardown_warn "$ns" "the Backup object could not be created"
    return 0
  fi

  local elapsed=0 phase
  while true; do
    phase="$(kubectl get backup "$backup_name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    echo "ARGO-DOWN: backup phase: ${phase:-pending} (${elapsed}s/${timeout}s)"
    if [ "$phase" = "completed" ]; then
      echo "ARGO-DOWN: pre-teardown backup completed."
      return 0
    fi
    if [ "$phase" = "failed" ]; then
      backup_teardown_warn "$ns" "Backup/$backup_name reported phase 'failed'"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      backup_teardown_warn "$ns" "Backup/$backup_name did not complete within ${timeout}s"
      return 0
    fi
    sleep "$poll"
    elapsed=$((elapsed + poll))
  done
}

# CNPG's Cluster status carries no last-archived segment name, so this
# condition is the only thing that says whether committed rows reached S3.
backup_archiving_status() {
  kubectl get cluster lab-postgres -n "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.status}{end}' \
    2>/dev/null || true
}

backup_archiving_since() {
  local since
  since="$(kubectl get cluster lab-postgres -n "$1" \
    -o jsonpath='{range .status.conditions[?(@.type=="ContinuousArchiving")]}{.lastTransitionTime}{end}' \
    2>/dev/null || true)"
  if [ -n "$since" ]; then
    echo "The unarchived window starts at $since."
  else
    echo "The start of the unarchived window is unknown."
  fi
}

backup_teardown_warn() {
  local ns="$1" reason="$2"
  {
    echo "ARGO-DOWN: WARNING - the pre-teardown Postgres backup did not complete: $reason."
    echo "ARGO-DOWN: WARNING - ContinuousArchiving=$(backup_archiving_status "$ns"). $(backup_archiving_since "$ns")"
    echo "ARGO-DOWN: WARNING - teardown continues. Rows committed while archiving was True are already in S3;"
    echo "ARGO-DOWN: WARNING - recovery will replay from the last base backup and cost extra time, not data."
    echo "ARGO-DOWN: WARNING - inspect with 'kubectl describe cluster lab-postgres -n $ns' before the next bring-up."
  } >&2
}

# Exports the whole Secret, not just cert/key fields, to preserve its
# cert-manager.io/* annotations and avoid a spurious reissue on next import.
# A missing Secret is not an error - first-ever run, argo-up bootstraps fresh.
export_tls_secret() {
  require_isolated_kubeconfig || return 1
  if ! kubectl get secret platform-public-tls -n envoy >/dev/null 2>&1; then
    echo "ARGO-DOWN: no platform-public-tls Secret found - nothing to export."
    return 0
  fi
  local manifest
  manifest="$(kubectl get secret platform-public-tls -n envoy -o yaml \
    | yq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields,
              .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])')"
  # Best effort: a failed export costs one ACME order on the next argo-up,
  # while aborting here would leave the whole cluster running.
  if aws ssm put-parameter \
    --region "$LAB_REGION" \
    --name "/${PROJECT_NAME}/persistent/${PROVIDER}/tls/platform-public" \
    --type SecureString \
    --tier Advanced \
    --key-id alias/lab-secrets \
    --overwrite \
    --value "$manifest" >/dev/null; then
    echo "ARGO-DOWN: exported platform-public-tls Secret to SSM (${#manifest} chars)."
  else
    echo "ARGO-DOWN: WARNING - could not store platform-public-tls in SSM (${#manifest} chars, limit 8192) - the next argo-up orders a fresh certificate." >&2
  fi
}

# Restoring before the root Application creates the Certificate avoids a
# redundant ACME order. A cert already past its renewal time is skipped -
# importing it would just trigger an immediate reissue anyway.
import_tls_secret() {
  require_isolated_kubeconfig || return 1
  if kubectl get secret platform-public-tls -n envoy >/dev/null 2>&1; then
    echo "ARGO-UP: platform-public-tls Secret already present - leaving the live one alone."
    return 0
  fi

  local manifest
  manifest="$(aws ssm get-parameter \
    --region "$LAB_REGION" \
    --name "/${PROJECT_NAME}/persistent/${PROVIDER}/tls/platform-public" \
    --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [ -z "$manifest" ] || [ "$manifest" = "None" ]; then
    echo "ARGO-UP: no stored platform-public-tls Secret in SSM - a fresh certificate will be ordered."
    return 0
  fi

  # cert-manager keeps notAfter/renewalTime on the Certificate, not the Secret,
  # so read the leaf's own expiry. Inside the default renewal window (last 30
  # days) an import only triggers an immediate renewal order anyway.
  local not_after not_after_epoch now_epoch
  # Guarded: an unreadable stored cert must fall through to a fresh order,
  # not end the whole bring-up silently under pipefail.
  not_after="$(echo "$manifest" | yq '.data["tls.crt"] // ""' | base64 -d 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
  if [ -n "$not_after" ]; then
    not_after_epoch="$(date -u -d "$not_after" +%s 2>/dev/null \
      || date -u -jf "%b %e %H:%M:%S %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    if [ "$not_after_epoch" -gt 0 ] && [ $((not_after_epoch - now_epoch)) -le $((30 * 24 * 3600)) ]; then
      echo "ARGO-UP: stored platform-public-tls certificate expires $not_after (inside the renewal window) - skipping import, a fresh certificate will be ordered."
      return 0
    fi
  fi

  kubectl create namespace envoy --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Server-side apply: client-side apply would stamp a last-applied annotation
  # holding a full copy of the Secret, doubling the next export past 8 KiB.
  echo "$manifest" | kubectl apply --server-side --force-conflicts -f - >/dev/null
  echo "ARGO-UP: restored platform-public-tls Secret from SSM (not-after: ${not_after:-unknown})."
}
