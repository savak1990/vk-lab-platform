#!/usr/bin/env bash
# Pins the HCLOUD_CLUSTER_CONFIG that argo-up hands the Hetzner autoscaler.
# Two things here are load-bearing and neither fails loudly in production:
#
#   serverLabels - three separate consumers select on these, and each needs a
#   different key. The teardown sweep swallows its errors, so a server missing
#   the project label survives `make down` unseen rather than erroring.
#
#   cloudInit - a multi-line value that must arrive byte-identical. It is
#   base64 once, never twice, and it is read from SSM outside the batched
#   get-parameters call because --output text writes newlines literally.
#
# Needs no credentials and no cluster - kubectl is a stub.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP="$(mktemp)"
trap 'rm -f "$CAP"' EXIT
fails=0

# Just the function, so sourcing argo-up.sh's top level never happens.
eval "$(awk '/^ensure_autoscaler_config\(\) \{/,/^\}/' "$REPO_ROOT/scripts/argo-up.sh")"

# Reads no stdin. The first kubectl of the pipeline under test would otherwise
# read this script's own, which is the terminal when a person runs it by hand.
kubectl() {
  if [ "${1:-}" = "create" ]; then
    local a
    for a in "$@"; do
      case "$a" in
        --from-literal=HCLOUD_CLUSTER_CONFIG=*)
          printf '%s' "${a#--from-literal=HCLOUD_CLUSTER_CONFIG=}" > "$CAP" ;;
      esac
    done
  fi
  return 0
}

check() {
  local label="$1" filter="$2"
  if printf '%s' "$JSON" | jq -e "$filter" > /dev/null 2>&1; then
    echo "ok   $label"
  else
    echo "FAIL $label"
    fails=$((fails + 1))
  fi
}

# Shaped like the real render: multi-line, with a tab inside a command, which
# is what would break a tab-delimited batch read.
WORKER_USER_DATA='#cloud-config
write_files:
  - path: /etc/netplan/60-private.yaml
    content: |
      network:
      	version: 2
runcmd:
  - curl -sfL https://get.k3s.io | K3S_TOKEN=join-token sh -s - agent'
# Exported because the function under test is eval'd, so shellcheck cannot see
# the read and reports each one unused.
export HCLOUD_NODE_IMAGE=ubuntu-24.04
export HCLOUD_SUBNET_IP_RANGE=10.0.1.0/24
export PROJECT_NAME=vk-hetzner-lab

ensure_autoscaler_config
JSON="$(base64 -d < "$CAP")"

check "the node group is named for the --nodes flag's pool" \
  '.nodeConfigs | keys == ["workers"]'
check "all five serverLabels are present" \
  '.nodeConfigs.workers.serverLabels | keys == ["lifecycle","managed_by","project","role","scope"]'
check "project=<project>      - firewall selector and teardown sweep" \
  '.nodeConfigs.workers.serverLabels.project == "vk-hetzner-lab"'
check "scope=platform         - firewall selector" \
  '.nodeConfigs.workers.serverLabels.scope == "platform"'
check "managed_by=autoscaler  - teardown sweep" \
  '.nodeConfigs.workers.serverLabels.managed_by == "autoscaler"'
check "lifecycle=disposable   - failure diagnostics" \
  '.nodeConfigs.workers.serverLabels.lifecycle == "disposable"'
check "the subnet is stated rather than left to the hcloud default" \
  '.defaultSubnetIPRange == "10.0.1.0/24"'
check "both architectures name the fixed pool's image" \
  '.imagesForArch == {amd64: "ubuntu-24.04", arm64: "ubuntu-24.04"}'

DECODED="$(printf '%s' "$JSON" | jq -r '.nodeConfigs.workers.cloudInit' | base64 -d)"
if [ "$DECODED" = "$WORKER_USER_DATA" ]; then
  echo "ok   the cloud-init round-trips byte-identical, newlines and tab intact"
else
  echo "FAIL the cloud-init does not round-trip - it is encoded twice, or truncated"
  fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "autoscaler-config-test: $fails case(s) failed" >&2
  exit 1
fi
echo "autoscaler-config-test: all 9 cases passed"
