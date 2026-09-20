#!/usr/bin/env bash
# Exercises argo_watch_root (scripts/lib/argo-watch.sh) against a fake `kubectl`
# on PATH whose answers to `get application root` follow FAKE_ROOT_SEQUENCE:
# one token per poll (`fail`, `<sync>/<health>`, or `Failed`), the last token
# repeating. Every other kubectl call returns a fixed stub.
# Usage: tests/scripts/argo-watch-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"get application root"*"-o json"*)
    n=$(( $(cat "$FAKE_CALLS" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_CALLS"
    read -r -a seq <<< "$FAKE_ROOT_SEQUENCE"
    idx=$(( n - 1 )); [ "$idx" -ge "${#seq[@]}" ] && idx=$(( ${#seq[@]} - 1 ))
    token="${seq[$idx]}"
    case "$token" in
      fail) exit 1 ;;
      Failed)
        jq -n '{status:{sync:{status:"OutOfSync"},health:{status:"Degraded"},
          conditions:[{type:"SyncError",message:"one or more objects failed to apply"}],
          operationState:{phase:"Failed",startedAt:"2026-01-01T00:00:00Z",retryCount:3,
            message:"boom",
            syncResult:{resources:[
              {kind:"Deployment",name:"grafana",status:"SyncFailed",message:"http2: client connection lost"},
              {kind:"ConfigMap",name:"ok",status:"Synced",message:"configured"}]}},
          resources:[{kind:"Deployment",name:"grafana",status:"OutOfSync",health:{status:"Missing"}}]}}' ;;
      *)
        jq -n --arg s "${token%%/*}" --arg h "${token##*/}" '{status:{sync:{status:$s},health:{status:$h},
          operationState:{phase:"Running",startedAt:"2026-01-01T00:00:00Z",retryCount:0},
          resources:(if $h == "Healthy" then [] else [{kind:"Gateway",name:"platform",status:"Synced",health:{status:"Progressing"}}] end)}}' ;;
    esac ;;
  *"get applications"*"-o json"*)
    echo '{"items":[{"metadata":{"name":"root"},"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}]}' ;;
  *"get nodes"*) echo "node-a   Ready   <none>   10m   v1.35.0"; echo "node-b   Ready   <none>   10m   v1.35.0" ;;
  *"get events"*"reason=TriggeredScaleUp"*) echo "2026-01-01T00:05:00Z  prometheus-0  pod triggered scale-up: [{workers 2->3 (max: 3)}]" ;;
  *"get events"*"reason=ScaledUpGroup"*) echo "2026-01-01T00:05:02Z  cluster-autoscaler-status  Scale-up: setting group workers size to 3" ;;
  *"logs"*)
    echo "I0101 00:04:59 noise: unrelated line"
    echo "I0101 00:05:00 scale_up.go:600] Final scale-up plan: [{workers 2->3 (max: 3)}]"
    echo "I0101 00:05:00 civo_node_group.go:99] adding node pool: \"workers\"" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/kubectl"
export PATH="$TMP/bin:$PATH"
export FAKE_CALLS="$TMP/calls"
export ARGO_UP_POLL_INTERVAL=1
export ARGO_UP_WATCH_SECONDS=30
export ARGO_UP_HEARTBEAT_SECONDS=1000
export PRIOR_OPERATION_STARTED_AT=""
export PROVIDER=civo

fail=0
err() { echo "ARGO-WATCH-TEST: $*" >&2; fail=1; }

# Runs one scenario: $1 = sequence; stdout/stderr land in $OUT / $ERR, status in $RC.
run() {
  rm -f "$FAKE_CALLS"
  FAKE_ROOT_SEQUENCE="$1" bash -c '
    set -euo pipefail
    source "$1/scripts/lib/argo-watch.sh"
    argo_watch_root' _ "$REPO_ROOT" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

# A transient API failure keeps the watch alive and is reported, not fatal.
run "fail fail Synced/Healthy"
[ "$RC" -eq 0 ] || err "transient failure: expected exit 0, got $RC"
grep -q "API unreachable" <<< "$OUT" || err "transient failure: no 'API unreachable' line"
grep -q "reachable again" <<< "$OUT" || err "transient failure: no 'reachable again' line"
[ "$(cat "$FAKE_CALLS")" -eq 3 ] || err "transient failure: expected 3 polls, got $(cat "$FAKE_CALLS")"

# Success reports the node inventory, so a CI log shows whether the pool scaled.
grep -q "node-b" <<< "$OUT" || err "success: node inventory not printed"

# Success also names the moment the autoscaler triggered, from events and its log.
grep -q "ARGO-UP: scale-up events:" <<< "$OUT" || err "success: no scale-up events header"
grep -q "pod triggered scale-up: \[{workers 2->3" <<< "$OUT" || err "success: TriggeredScaleUp event missing"
grep -q "Scale-up: setting group workers size to 3" <<< "$OUT" || err "success: ScaledUpGroup event missing"
grep -q "adding node pool" <<< "$OUT" || err "success: autoscaler log line missing"
grep -q "unrelated line" <<< "$OUT" && err "success: unrelated autoscaler log line leaked through"

# A non-Civo run has no autoscaler, so it prints none of this.
PROVIDER=aws run "Synced/Healthy"
grep -q "scale-up" <<< "$OUT" && err "aws: scale-up section printed on a target with no autoscaler"
export PROVIDER=civo

# A sync that ends Failed exits 1 with Argo's message and the failed resources.
run "Failed"
[ "$RC" -eq 1 ] || err "failed sync: expected exit 1, got $RC"
grep -q "root sync Failed after 3 retries" <<< "$ERR" || err "failed sync: no failure headline"
grep -q "boom" <<< "$ERR" || err "failed sync: operation message missing"
grep -q "Deployment/grafana: http2: client connection lost" <<< "$ERR" || err "failed sync: SyncFailed resource missing"
grep -q "SyncError: one or more objects failed to apply" <<< "$ERR" || err "failed sync: root condition missing"

# A Failed operation that predates this run is not this run's failure.
PRIOR_OPERATION_STARTED_AT="2026-01-01T00:00:00Z" ARGO_UP_WATCH_SECONDS=2 run "Failed"
[ "$RC" -eq 1 ] || err "prior failure: expected exit 1 (timeout), got $RC"
grep -q "timed out" <<< "$ERR" || err "prior failure: expected a timeout, not a sync failure"

# Nothing changing still produces a heartbeat, so a silent log means a dead script.
ARGO_UP_HEARTBEAT_SECONDS=2 run "OutOfSync/Progressing OutOfSync/Progressing OutOfSync/Progressing OutOfSync/Progressing Synced/Healthy"
[ "$RC" -eq 0 ] || err "heartbeat: expected exit 0, got $RC"
grep -q "ARGO-UP: \[+[0-9]*s\] waiting" <<< "$OUT" || err "heartbeat: no heartbeat line"

# The watch ceiling exits 1 with the pending list and a diagnostics dump.
ARGO_UP_WATCH_SECONDS=2 run "OutOfSync/Progressing"
[ "$RC" -eq 1 ] || err "timeout: expected exit 1, got $RC"
grep -q "timed out after 2s" <<< "$ERR" || err "timeout: no timeout line"
grep -q "Gateway/platform=Synced(Progressing)" <<< "$ERR" || err "timeout: pending resource missing"
grep -q "ARGO-UP: nodes:" <<< "$ERR" || err "timeout: diagnostics dump missing"
grep -q "ARGO-UP: scale-up events:" <<< "$ERR" || err "timeout: scale-up events missing from the dump"

[ "$fail" -eq 0 ] && echo "ARGO-WATCH-TEST: all checks passed."
exit "$fail"
