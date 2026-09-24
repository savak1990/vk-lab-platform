#!/usr/bin/env bash
# Pins wait_for_nodes_ready against the node count it is given. The gate used
# to be an equality, which held only while the fixed pool was the whole
# cluster: once the autoscaler adds a node, a re-run of `make up` would wait
# out its ten-minute budget and then fail a cluster that was entirely healthy.
#
# Needs no credentials and no cluster - kubectl is a stub.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PROVIDER=hetzner
# shellcheck source=../../scripts/lib/provider.sh
source "$REPO_ROOT/scripts/lib/provider.sh"

fails=0
NODES=""

kubectl() {
  case "$*" in
    "get nodes --no-headers") printf '%s\n' "$NODES" ;;
    *) return 0 ;;
  esac
}
# The failure path enumerates servers over the Hetzner API; an empty list
# keeps this test offline without suppressing the return code under test.
hcloud_cli() { printf '[]\n'; }
hetzner_ssh() { return 0; }

run_case() {
  local label="$1" nodes="$2" count="$3" want="$4" got
  NODES="$nodes"
  NODE_COUNT="$count" HETZNER_NODE_READY_SECONDS=1 ARGO_UP_POLL_INTERVAL=1 \
    wait_for_nodes_ready > /dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label - wanted exit $want, got $got"
    fails=$((fails + 1))
  fi
}

READY3="cp-1 Ready control-plane 1h v1.36.4
w-1 Ready <none> 1h v1.36.4
w-2 Ready <none> 1h v1.36.4"

run_case "the fixed pool alone is Ready" "$READY3" 3 0
run_case "an autoscaled node above the fixed pool still passes" \
  "$READY3
w-auto Ready <none> 2m v1.36.4" 3 0
run_case "a NotReady node fails even when the count is met" \
  "$READY3
w-auto NotReady <none> 30s v1.36.4" 3 1
run_case "fewer nodes than the fixed pool fails" \
  "cp-1 Ready control-plane 1h v1.36.4" 3 1
run_case "no nodes at all fails" "" 3 1

if [ "$fails" -gt 0 ]; then
  echo "node-ready-test: $fails case(s) failed" >&2
  exit 1
fi
echo "node-ready-test: all 5 cases passed"
