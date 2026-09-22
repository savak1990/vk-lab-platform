#!/usr/bin/env bash
# Stops the background gateway forward that forward-up-local.sh started.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"

if [ "$PROVIDER" != "local" ]; then
  echo "forward-down-local.sh: PROVIDER=$PROVIDER forwards nothing - there is nothing to stop." >&2
  exit 1
fi

pidfile="$REPO_ROOT/.kube/$PROJECT_NAME-forward.pid"

if [ ! -f "$pidfile" ]; then
  echo "FORWARD-DOWN: nothing is forwarding."
  exit 0
fi

pid="$(cat "$pidfile")"
rm -f "$pidfile"

if ! kill -0 "$pid" 2>/dev/null; then
  echo "FORWARD-DOWN: the forward on pid $pid is already gone."
  exit 0
fi

kill "$pid"
for _ in $(seq 1 10); do
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
kill -9 "$pid" 2>/dev/null || true
echo "FORWARD-DOWN: stopped the forward on pid $pid."
