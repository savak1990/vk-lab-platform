#!/usr/bin/env bash
# Lists every platform cluster live on every provider, whatever its
# PROJECT_NAME: EKS in the AWS account, Kubernetes in each Civo region the
# catalogue lists, and scope=platform servers grouped by project label in the
# Hetzner account. Deliberately project-independent: it reads no Terraform
# state and takes no PROJECT_NAME, so it answers "what is running right now?"
# rather than "what does this checkout own?" - which is what `make status`
# answers. Purely informational - always exits 0.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/catalog.sh"
source "$REPO_ROOT/scripts/lib/argo-state.sh"

# The Makefile exports these into every recipe, and provider.sh's
# export X="${X:-default}" cannot then change them - so one inherited value
# would pin all three arms to whichever provider make was invoked for. Each
# arm sets PROVIDER itself and discovers the project from tags and labels.
unset PROVIDER PROJECT_NAME CLUSTER_NAME REGION NODE_TYPE NODE_COUNT

# Never the operator's ~/.kube/config: update-kubeconfig also switches
# current-context, so walking N clusters would silently repoint their kubectl.
KUBECONFIG_TMP="$(mktemp)"
trap 'rm -f "$KUBECONFIG_TMP"' EXIT

# createdAt looks like 2026-09-06T17:17:21.772000+01:00. Drop the fractional
# seconds and un-colon the offset (BSD date's %z wants +0100), but keep the
# offset itself or the age comes out skewed by the operator's local zone.
age_of() {
  local stamp created_epoch now_epoch delta
  stamp="$(echo "$1" | sed -E 's/\.[0-9]+//; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')"
  created_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$stamp" +%s 2>/dev/null \
    || date -d "$1" +%s 2>/dev/null || echo "")"
  [ -n "$created_epoch" ] || { echo "-"; return; }
  now_epoch="$(date +%s)"
  delta=$(( (now_epoch - created_epoch) / 60 ))
  if [ "$delta" -lt 60 ]; then echo "${delta}m"
  elif [ "$delta" -lt 1440 ]; then echo "$((delta / 60))h"
  else echo "$((delta / 1440))d"
  fi
}

row() { printf '%-24s %-28s %-8s %-6s %-6s %s\n' "$@"; }

# A paren body makes each arm its own subshell, so the PROVIDER it exports and
# the values provider.sh derives from it cannot reach the next arm.
list_aws() (
  export PROVIDER=aws
  source "$REPO_ROOT/scripts/lib/region.sh"

  # Counts both the fixed system nodegroup and Karpenter's dynamic nodes, which
  # a nodegroup-only query would miss; needs no cluster access.
  node_count_of() {
    aws ec2 describe-instances --region "$LAB_REGION" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/$1" \
      "Name=instance-state-name,Values=running" \
      --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "?"
  }

  local clusters cluster scope project status created found=0
  clusters="$(aws eks list-clusters --region "$LAB_REGION" \
    --query 'clusters[]' --output text 2>/dev/null || true)"
  if [ -z "$clusters" ] || [ "$clusters" = "None" ]; then
    echo "(aws: no EKS clusters in $LAB_REGION)"
    return 0
  fi

  # Resolved once here, not per cluster: argo_state runs inside $( ), so a cache
  # set within that subshell would never reach the next iteration.
  ARGO_ACCESS_ROLE_ARN="$(argo_access_role_arn)"

  for cluster in $clusters; do
    # A flat array with --output text is already tab-separated; join() with a
    # literal tab is not expressible in JMESPath's backtick JSON literals.
    read -r scope project status created <<<"$(aws eks describe-cluster --name "$cluster" \
      --region "$LAB_REGION" \
      --query '[cluster.tags.Scope || `-`, cluster.tags.Project || `-`, cluster.status, cluster.createdAt]' \
      --output text 2>/dev/null || echo "- - - -")"

    # Scope=platform is what separates this platform's clusters from anything
    # else in a shared account (constitution §16).
    if [ "$scope" = "platform" ]; then
      found=1
      row "$project" "$cluster" "$status" \
        "$(node_count_of "$cluster")" "$(age_of "$created")" \
        "$(argo_state "$cluster" "$KUBECONFIG_TMP")"
    fi
  done

  [ "$found" -eq 1 ] || echo "(aws: no clusters tagged Scope=platform)"
)

# Civo's CLI is region-scoped and answers "zero matches" for a cluster in
# another region, so every region the catalogue allows has to be asked.
# Deliberately unfiltered by tag: Civo's update API rejects tags, so a running
# cluster may carry none, and a bill-safety command that hides one is worse
# than one that shows an extra. The cluster's name is the project's name.
list_civo() (
  export PROVIDER=civo
  source "$REPO_ROOT/scripts/lib/provider.sh"
  source "$REPO_ROOT/scripts/lib/region.sh"

  command -v civo >/dev/null 2>&1 || { echo "(civo: CLI not installed - skipped)"; return 0; }
  if ! civo_token >/dev/null 2>&1; then
    echo "(civo: token unavailable - skipped)"
    return 0
  fi

  local region raw name status nodes created found=0
  for region in $(catalog_regions civo); do
    # Assigned after region.sh, which would otherwise win: an inherited REGION
    # from another provider survives provider.sh's canonicalisation unchanged.
    CIVO_REGION="$region"
    raw="$(civo_cli kubernetes ls -o json --region "$region" 2>/dev/null || true)"
    # The CLI prints "No resources found in region X" rather than [] for none.
    case "$raw" in \[*) ;; *) continue ;; esac

    while IFS=$'\t' read -r name status nodes created; do
      if [ -n "$name" ]; then
        found=1
        row "$name" "$name@$region" "$status" "$nodes" "$(age_of "$created")" \
          "$(PROJECT_NAME="$name" argo_state "$name" "$KUBECONFIG_TMP")"
      fi
    done <<<"$(jq -r '.[] | [
        .name,
        (.status // "-"),
        ((.num_target_nodes // 0) | tostring),
        (.created_at // "")
      ] | @tsv' <<<"$raw")"
  done

  [ "$found" -eq 1 ] || echo "(civo: no clusters in $(catalog_regions civo))"
)

# Hetzner sells no managed Kubernetes, so there is no cluster object to list: a
# cluster is the set of servers sharing a project label. The server list is
# account-wide, so unlike Civo this needs no region loop.
list_hetzner() (
  export PROVIDER=hetzner
  source "$REPO_ROOT/scripts/lib/provider.sh"
  source "$REPO_ROOT/scripts/lib/region.sh"

  command -v hcloud >/dev/null 2>&1 || { echo "(hetzner: CLI not installed - skipped)"; return 0; }
  if ! hcloud_token >/dev/null 2>&1; then
    echo "(hetzner: token unavailable - skipped)"
    return 0
  fi

  local raw project loc status nodes created found=0
  raw="$(hcloud_cli server list -o json 2>/dev/null || true)"
  case "$raw" in \[*) ;; *) echo "(hetzner: server list unavailable)"; return 0 ;; esac

  # The cluster's age is its control plane's, so the group takes the oldest
  # server's; an ISO 8601 stamp sorts lexically and needs no date parsing.
  while IFS=$'\t' read -r project loc status nodes created; do
    if [ -n "$project" ]; then
      found=1
      # ponytail: ARGO is always "-" here. Reading it costs an SSM lookup, a KMS
      # decrypt and an SSH poll of the control plane per cluster, and needs a
      # private key only some projects commit. Add a flag if it is ever wanted.
      row "$project" "$project@$loc" "$status" "$nodes" "$(age_of "$created")" "-"
    fi
  done <<<"$(jq -r '
      [ .[] | select(.labels.scope == "platform") ]
      | group_by(.labels.project)[]
      | [ (.[0].labels.project // "-"),
          (.[0].datacenter.location.name // "-"),
          ([.[].status] | unique | if length == 1 then .[0] else "mixed" end),
          (length | tostring),
          ([.[].created] | sort | .[0]) ]
      | @tsv' <<<"$raw")"

  [ "$found" -eq 1 ] || echo "(hetzner: no servers labelled scope=platform)"
)

row PROJECT CLUSTER STATUS NODES AGE ARGO

# One arm's failure must not hide the other two, and must not stop the exit 0
# that every caller of an informational command relies on.
list_aws || true
list_civo || true
list_hetzner || true
