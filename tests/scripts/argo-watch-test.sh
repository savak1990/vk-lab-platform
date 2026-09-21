#!/usr/bin/env bash
# Exercises argo_watch_root (scripts/lib/argo-watch.sh) against a fake `kubectl`
# on PATH whose answers to `get application root` follow FAKE_ROOT_SEQUENCE:
# one token per poll (`fail`, `<sync>/<health>`, or `Failed`), the last token
# repeating. Node and autoscaler answers follow FAKE_NODES_SEQUENCE and
# FAKE_SCALEUP_SEQUENCE the same way. Every other call returns a fixed stub.
# Usage: tests/scripts/argo-watch-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
args="$*"
# Sequence helper: $1 counter file, $2 sequence; prints the token for this call.
tok() {
  local n; n=$(( $(cat "$1" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$1"
  read -r -a seq <<< "$2"; local i=$(( n - 1 )); [ "$i" -ge "${#seq[@]}" ] && i=$(( ${#seq[@]} - 1 ))
  echo "${seq[$i]}"
}
root_calls() { cat "$FAKE_CALLS" 2>/dev/null || echo 0; }
case "$args" in
  *"get application root"*"-o json"*)
    token="$(tok "$FAKE_CALLS" "$FAKE_ROOT_SEQUENCE")"
    case "$token" in
      fail) echo "Unable to connect to the server: dial tcp 10.0.0.1:6443: i/o timeout" >&2; exit 1 ;;
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
  *"get nodes"*"-o json"*)
    token="$(tok "$FAKE_NODE_CALLS" "${FAKE_NODES_SEQUENCE:-2}")"
    node() { jq -n --arg n "$1" --arg c "$2" --arg r "$3" --arg t "$4" '{metadata:{name:$n,creationTimestamp:$c},status:{conditions:[{type:"Ready",status:$r,lastTransitionTime:$t}]}}'; }
    { node node-a 2026-01-01T00:00:00Z True 2026-01-01T00:00:30Z; node node-b 2026-01-01T00:00:00Z True 2026-01-01T00:00:30Z
      case "$token" in
        3nr) node node-c 2026-01-01T00:06:00Z False 2026-01-01T00:06:00Z ;;
        3r)  node node-c 2026-01-01T00:06:00Z True  2026-01-01T00:07:00Z ;;
      esac; } | jq -s '{items:.}' ;;
  *"get nodes"*) echo "node-a   Ready   <none>   10m   v1.35.0"; echo "node-b   Ready   <none>   10m   v1.35.0" ;;
  *"get events"*"reason=TriggeredScaleUp"*) echo "2026-01-01T00:05:30Z  prometheus-0  pod triggered scale-up: [{workers 2->3 (max: 3)}]" ;;
  *"get events"*"involvedObject.name=cluster-autoscaler-status"*) echo "2026-01-01T00:05:32Z  ScaledUpGroup  Scale-up: setting group workers size to 3" ;;
  *"get configmap cluster-autoscaler-status"*)
    token="$(tok "$FAKE_CM_CALLS" "${FAKE_SCALEUP_SEQUENCE:-NoActivity}")"
    printf 'autoscalerStatus: Running\nclusterWide:\n  health:\n    status: Healthy\n'; for _ in $(seq 1 30); do echo "  filler: line"; done
    printf '  scaleUp:\n    lastProbeTime: "2026-01-01T00:05:40Z"\n    lastTransitionTime: "2026-01-01T00:05:30Z"\n    status: %s\n' "$token"
    printf 'nodeGroups:\n- name: workers\n  scaleUp:\n    status: %s\n' "$token" ;;
  *"get pods"*"status.phase=Pending"*) echo "observability   prometheus-0   0/2   Pending   0   30s" ;;
  *"config view"*) echo "https://10.0.0.1:6443" ;;
  *"get --raw /metrics"*)
    if [ "$(root_calls)" -ge "${FAKE_RESTART_AFTER:-999}" ]; then s=2000; else s=1000; fi
    echo "process_start_time_seconds{job=\"apiserver\"} $s"
    echo 'apiserver_current_inflight_requests{request_kind="mutating"} 3'
    echo 'apiserver_current_inflight_requests{request_kind="readOnly"} 5' ;;
  *"get --raw /readyz"*) printf '[+]etcd ok\n[-]poststarthook/priority-and-fairness-config-consumer failed: reason withheld\nreadyz check failed\n' ;;
  *"get lease"*"-o json"*)
    if [ "$(root_calls)" -ge "${FAKE_RESTART_AFTER:-999}" ]; then h=host_bbb; else h=host_aaa; fi
    jq -n --arg h "$h" '{items:[{metadata:{name:"kube-controller-manager"},spec:{holderIdentity:$h,acquireTime:"2026-01-01T00:00:00Z"}},
                                {metadata:{name:"kube-scheduler"},spec:{holderIdentity:"sched_1",acquireTime:"2026-01-01T00:00:00Z"}}]}' ;;
  *"logs"*)
    echo "I0101 00:04:59 noise: unrelated line"
    echo "I0101 00:04:59 civo_manager.go:166] adding node pool: \"workers\""
    echo "I0101 00:05:30 scale_up.go:600] Final scale-up plan: [{workers 2->3 (max: 3)}]"
    echo "I0101 00:05:31 clusterstate.go:400] Scale-up: setting group workers size to 3" ;;
  *) exit 0 ;;
esac
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Prints the -w format's fields as the watch expects: code connect appconnect total.
echo "000 0.000 0.000 5.001"
EOF
cat > "$TMP/bin/civo_cli" <<'EOF'
#!/usr/bin/env bash
# Answers only when asked for the right cluster in the right region, so a
# missing --region or the wrong name shows up as a failure, not as silence.
[ -n "${FAKE_CIVO_FAIL:-}" ] && { echo "Error: ZeroMatchesError" >&2; exit 1; }
case "$*" in
  *"kubernetes show test-cluster"*--region\ LON1*) ;;
  *) echo "Error: Kubernetes ZeroMatchesError: unable to find, zero matches" >&2; exit 1 ;;
esac
echo '{"status":"ACTIVE","ready":true,"num_target_nodes":3,"instances":[{"hostname":"node-a","status":"ACTIVE"},{"hostname":"node-b","status":"ACTIVE"}]}'
EOF
chmod +x "$TMP/bin/kubectl" "$TMP/bin/curl" "$TMP/bin/civo_cli"
export PATH="$TMP/bin:$PATH"
export FAKE_CALLS="$TMP/calls" FAKE_NODE_CALLS="$TMP/node-calls" FAKE_CM_CALLS="$TMP/cm-calls"
export ARGO_UP_POLL_INTERVAL=1
export ARGO_UP_WATCH_SECONDS=30
export ARGO_UP_HEARTBEAT_SECONDS=1000
export PRIOR_OPERATION_STARTED_AT=""
export PROVIDER=civo
export PROJECT_NAME=test-project
export CLUSTER_NAME=test-cluster
export CIVO_REGION=LON1

fail=0
err() { echo "ARGO-WATCH-TEST: $*" >&2; fail=1; }

# Runs one scenario: $1 = root sequence; stdout/stderr land in $OUT / $ERR, status in $RC.
run() {
  rm -f "$FAKE_CALLS" "$FAKE_NODE_CALLS" "$FAKE_CM_CALLS"
  FAKE_ROOT_SEQUENCE="$1" bash -c '
    set -euo pipefail
    source "$1/scripts/lib/argo-watch.sh"
    argo_watch_root' _ "$REPO_ROOT" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}

# A transient API failure keeps the watch alive and is reported, not fatal.
# The pool grows during it: node-c registers, then becomes Ready.
FAKE_NODES_SEQUENCE="2 3nr 3r" FAKE_SCALEUP_SEQUENCE="NoActivity InProgress NoActivity" FAKE_RESTART_AFTER=3 \
  run "fail fail Synced/Healthy"
[ "$RC" -eq 0 ] || err "transient failure: expected exit 0, got $RC"
grep -q "API unreachable" <<< "$OUT" || err "transient failure: no 'API unreachable' line"
grep -q "reachable again" <<< "$OUT" || err "transient failure: no 'reachable again' line"
[ "$(cat "$FAKE_CALLS")" -eq 3 ] || err "transient failure: expected 3 polls, got $(cat "$FAKE_CALLS")"
# ARGO_WATCH_TEST_SHOW=1 prints this scenario's full output, to eyeball the format.
[ -z "${ARGO_WATCH_TEST_SHOW:-}" ] || printf '%s\n' "$OUT"

# The outage is characterised, not just counted: kubectl's own error, an
# endpoint probe, Civo's view of the cluster, and whether the control plane
# came back as a new process.
grep -q "i/o timeout" <<< "$OUT" || err "outage: kubectl error text not printed"
grep -q "API probe: livez=000" <<< "$OUT" || err "outage: endpoint probe line missing"
grep -q "civo cluster: status=ACTIVE ready=true" <<< "$OUT" || err "outage: Civo cluster state missing"
grep -q "node-a=ACTIVE" <<< "$OUT" || err "outage: Civo instance states missing"
grep -q "control plane restarted" <<< "$OUT" || err "recovery: API server restart not detected from process_start_time_seconds"
grep -q "kube-controller-manager holder changed host_aaa -> host_bbb" <<< "$OUT" || err "recovery: lease holder change not reported"
grep -q "kube-scheduler" <<< "$OUT" && err "recovery: unchanged lease reported as changed"
grep -q "priority-and-fairness-config-consumer failed" <<< "$OUT" || err "recovery: failing readyz check not printed"

# Node arrival and readiness are timestamped from the objects themselves.
grep -q "node node-c registered (created 2026-01-01T00:06:00Z)" <<< "$OUT" || err "nodes: registration line missing"
grep -q "node node-c Ready at 2026-01-01T00:07:00Z (60s after registration)" <<< "$OUT" || err "nodes: readiness line missing"

# The autoscaler's own status ConfigMap marks the trigger; the summary joins the three times.
grep -q "scale-up InProgress since 2026-01-01T00:05:30Z" <<< "$OUT" || err "scale-up: trigger line missing"
grep -q "prometheus-0" <<< "$OUT" || err "scale-up: pending pods at trigger time missing"
grep -q "scale-up timeline: triggered 2026-01-01T00:05:30Z, node-c registered +30s, Ready +90s" <<< "$OUT" || err "scale-up: timeline summary missing"

# Success reports the node inventory, so a CI log shows whether the pool scaled.
grep -q "node-b" <<< "$OUT" || err "success: node inventory not printed"

# Success also names the moment the autoscaler triggered, from events and its log.
grep -q "ARGO-UP: scale-up events:" <<< "$OUT" || err "success: no scale-up events header"
grep -q "pod triggered scale-up: \[{workers 2->3" <<< "$OUT" || err "success: TriggeredScaleUp event missing"
grep -q "Final scale-up plan" <<< "$OUT" || err "success: scale-up plan log line missing"
grep -q "setting group workers size to 3" <<< "$OUT" || err "success: group-size log line missing"
grep -q "unrelated line" <<< "$OUT" && err "success: unrelated autoscaler log line leaked through"
grep -q "adding node pool" <<< "$OUT" && err "success: the 10s refresh line 'adding node pool' leaked through"
grep -q "name: workers" <<< "$OUT" || err "success: status ConfigMap cut before its nodeGroups section"

# A failing Civo lookup says so. Silence here is what hid a wrong region for
# two CI runs, so the absence of this line must never be the failure mode.
FAKE_CIVO_FAIL=1 run "fail Synced/Healthy"
grep -q "civo cluster: unavailable" <<< "$OUT" || err "outage: a failed Civo lookup printed nothing"
unset FAKE_CIVO_FAIL

# No restart across a clean run: say so, once, on recovery only.
run "fail Synced/Healthy"
grep -q "control plane did not restart" <<< "$OUT" || err "recovery: unchanged process start time not reported"

# A non-Civo run has no autoscaler and no Civo API, so it prints none of that.
PROVIDER=aws run "Synced/Healthy"
grep -q "scale-up" <<< "$OUT" && err "aws: scale-up section printed on a target with no autoscaler"
grep -q "civo cluster" <<< "$OUT" && err "aws: Civo cluster state printed on aws"
export PROVIDER=civo

# The heartbeat carries the API server's in-flight request counts, so load
# before an outage is visible in the log.
ARGO_UP_HEARTBEAT_SECONDS=2 run "OutOfSync/Progressing OutOfSync/Progressing OutOfSync/Progressing OutOfSync/Progressing Synced/Healthy"
[ "$RC" -eq 0 ] || err "heartbeat: expected exit 0, got $RC"
grep -q "ARGO-UP: \[+[0-9]*s\] waiting" <<< "$OUT" || err "heartbeat: no heartbeat line"
grep -q "inflight=mutating:3,readOnly:5" <<< "$OUT" || err "heartbeat: in-flight request counts missing"

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

# The watch ceiling exits 1 with the pending list and a diagnostics dump.
ARGO_UP_WATCH_SECONDS=2 run "OutOfSync/Progressing"
[ "$RC" -eq 1 ] || err "timeout: expected exit 1, got $RC"
grep -q "timed out after 2s" <<< "$ERR" || err "timeout: no timeout line"
grep -q "Gateway/platform=Synced(Progressing)" <<< "$ERR" || err "timeout: pending resource missing"
grep -q "ARGO-UP: nodes:" <<< "$ERR" || err "timeout: diagnostics dump missing"
grep -q "ARGO-UP: scale-up events:" <<< "$ERR" || err "timeout: scale-up events missing from the dump"

[ "$fail" -eq 0 ] && echo "ARGO-WATCH-TEST: all checks passed."
exit "$fail"
