#!/usr/bin/env bash
# Forwards the gateway to a local port in the background, so Argo CD and
# Grafana can be opened in a browser. Works through this repo's own
# kubeconfig, so it never reads or changes the operator's current context.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/region.sh"
source "$REPO_ROOT/scripts/lib/provider.sh"

if [ "$PROVIDER" != "local" ]; then
  echo "forward-up-local.sh: PROVIDER=$PROVIDER reaches the gateway over DNS - there is nothing to forward." >&2
  exit 1
fi

# Grafana's root_url names this port too. The render check pins that end; keep
# the two the same, or Grafana's own links point at a port nothing forwards.
LOCAL_PORT="${LOCAL_PORT:-8080}"
pidfile="$REPO_ROOT/.kube/$PROJECT_NAME-forward.pid"
logfile="$REPO_ROOT/.kube/$PROJECT_NAME-forward.log"

if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
  echo "FORWARD-UP: already forwarding on pid $(cat "$pidfile") - 'make forward-down' stops it."
  exit 0
fi
rm -f "$pidfile"

# Any loopback address, not just the one the forward will bind. A process
# holding the other one wins whenever the browser resolves localhost its way,
# and the forward would still report success.
if command -v lsof >/dev/null 2>&1; then
  # lsof exits non-zero when nothing holds the port, which pipefail propagates.
  holder="$(lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN -F c 2>/dev/null | sed -n 's/^c//p' | head -1 || true)"
  if [ -n "$holder" ]; then
    echo "forward-up-local.sh: port $LOCAL_PORT is already held by '$holder'." >&2
    echo "forward-up-local.sh: stop it, or choose another port with LOCAL_PORT=<n>." >&2
    exit 1
  fi
fi

use_isolated_kubeconfig
require_local_context

# The Service name carries a hash of the Gateway it serves, so it is found by
# the label its controller sets rather than named.
service="$(kubectl get svc -n envoy \
  -l gateway.envoyproxy.io/owning-gateway-name=platform-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$service" ]; then
  echo "forward-up-local.sh: no gateway Service in namespace envoy - has 'make up' finished?" >&2
  exit 1
fi

mkdir -p "$REPO_ROOT/.kube"
: >"$logfile"
# One explicit address, not kubectl's default of every loopback address. On a
# dual-stack host it binds whichever are free, so a port half-taken by another
# process leaves the client to pick, and it can pick the other one.
KUBECONFIG="$KUBECONFIG" nohup kubectl port-forward -n envoy --address 127.0.0.1 \
  "svc/$service" "$LOCAL_PORT:80" >"$logfile" 2>&1 &
pid=$!
echo "$pid" >"$pidfile"

for _ in $(seq 1 30); do
  if grep -q "Forwarding from 127.0.0.1:$LOCAL_PORT" "$logfile" 2>/dev/null; then
    echo "FORWARD-UP: Argo CD is http://localhost:$LOCAL_PORT - admin / '${LOCAL_ARGOCD_PASSWORD:-test}'."
    echo "FORWARD-UP: Grafana is http://localhost:$LOCAL_PORT/grafana - admin / '${LOCAL_GRAFANA_PASSWORD:-test}'."
    echo "FORWARD-UP: 'make forward-down' stops it. Log: $logfile"
    exit 0
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done

rm -f "$pidfile"
kill "$pid" 2>/dev/null || true
echo "forward-up-local.sh: the forward did not come up on 127.0.0.1:$LOCAL_PORT." >&2
echo "forward-up-local.sh: LOCAL_PORT=<n> picks another port. Last lines:" >&2
tail -5 "$logfile" >&2
exit 1
