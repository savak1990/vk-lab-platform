#!/usr/bin/env bash
# Lists every platform EKS cluster live in this AWS account, whatever its
# PROJECT_NAME. Deliberately project-independent: it reads no Terraform state
# and takes no PROJECT_NAME, so it answers "what is running right now?" rather
# than "what does this checkout own?" - which is what `make status` answers.
# Purely informational - always exits 0.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/argo-state.sh"

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

# Counts both the fixed system nodegroup and Karpenter's dynamic nodes, which
# a nodegroup-only query would miss; needs no cluster access.
node_count_of() {
  aws ec2 describe-instances --region "$LAB_REGION" \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/$1" \
    "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo "?"
}

CLUSTERS="$(aws eks list-clusters --region "$LAB_REGION" --query 'clusters[]' --output text 2>/dev/null || true)"

if [ -z "$CLUSTERS" ] || [ "$CLUSTERS" = "None" ]; then
  echo "No EKS clusters in $LAB_REGION."
  exit 0
fi

printf '%-24s %-28s %-8s %-6s %-6s %s\n' PROJECT CLUSTER STATUS NODES AGE ARGO

# Resolved once here, not per cluster: argo_state runs inside $( ), so a cache
# set within that subshell would never reach the next iteration.
ARGO_ACCESS_ROLE_ARN="$(argo_access_role_arn)"

found=0
for cluster in $CLUSTERS; do
  # A flat array with --output text is already tab-separated; join() with a
  # literal tab is not expressible in JMESPath's backtick JSON literals.
  read -r scope project status created <<<"$(aws eks describe-cluster --name "$cluster" \
    --region "$LAB_REGION" \
    --query '[cluster.tags.Scope || `-`, cluster.tags.Project || `-`, cluster.status, cluster.createdAt]' \
    --output text 2>/dev/null || echo "- - - -")"

  # Scope=platform is what separates this platform's clusters from anything
  # else in a shared account (constitution §16).
  [ "$scope" = "platform" ] || continue
  found=1

  printf '%-24s %-28s %-8s %-6s %-6s %s\n' \
    "$project" "$cluster" "$status" \
    "$(node_count_of "$cluster")" "$(age_of "$created")" \
    "$(argo_state "$cluster" "$KUBECONFIG_TMP")"
done

[ "$found" -eq 1 ] || echo "(no clusters tagged Scope=platform)"
