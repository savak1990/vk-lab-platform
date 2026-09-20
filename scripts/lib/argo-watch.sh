#!/usr/bin/env bash
# Watches the root Application until it is Synced/Healthy. Sourced by
# argo-up.sh; every kubectl call here is guarded, because the caller runs
# under set -e and an API blip mid-watch must be reported, never fatal.

ARGO_WATCH_ERR="${TMPDIR:-/tmp}/argo-watch-err.$$"

argo_root_json() {
  kubectl get application root -n argocd -o json 2>"$ARGO_WATCH_ERR"
}

# RFC3339 to epoch seconds on GNU or BSD date; empty when unparsable.
argo_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || true
}

# root's own directly-templated resources not yet Healthy. Kinds with no
# health concept (ServiceAccount, Role, ...) count only while not Synced.
argo_pending_from() {
  jq -r '
    [.status.resources[]?
      | select((.health.status // "") != "Healthy")
      | select((.health.status // "") != "" or .status != "Synced")
      | "\(.kind)/\(.name)=\(.status)(\(.health.status // "n/a"))"]
    | join(" ")' <<< "$1"
}

argo_conditions_from() {
  jq -r '[.status.conditions[]? | "\(.type): \(.message // "" | gsub("\n"; " "))"] | join(" | ")' <<< "$1"
}

argo_sync_failed_from() {
  jq -r '.status.operationState.syncResult.resources[]?
    | select(.status == "SyncFailed")
    | "  \(.kind)/\(.name): \(.message // "" | gsub("\n"; " "))"' <<< "$1"
}

argo_print_app_status() {
  kubectl get applications -n argocd -o json 2>/dev/null \
    | jq -r '.items[]? | "  \(.metadata.name): sync=\(.status.sync.status // "Unknown") health=\(.status.health.status // "Unknown")"' \
    || echo "  (applications unavailable - API unreachable)"
}

argo_print_nodes() {
  echo "ARGO-UP: nodes:"
  kubectl get nodes --no-headers 2>/dev/null | sed 's/^/  /' || echo "  (unavailable)"
}

# ---- outage characterisation -------------------------------------------

argo_api_server_url() {
  kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true
}

# Probes the endpoint without kubectl. A dead host times out on connect;
# a live but struggling one answers, refuses, or dies inside TLS.
argo_api_probe() {
  local url="$1" fmt='%{http_code} %{time_connect} %{time_appconnect} %{time_total}' livez readyz
  livez="$(curl -sk -o /dev/null --max-time 5 -w "$fmt" "$url/livez" 2>/dev/null || true)"
  readyz="$(curl -sk -o /dev/null --max-time 5 -w "$fmt" "$url/readyz" 2>/dev/null || true)"
  echo "livez=${livez%% *} (${livez##* }s) readyz=${readyz%% *} (${readyz##* }s)"
}

# Civo's own view of the cluster during an outage: a status other than
# ACTIVE, or an instance not ACTIVE, means Civo is doing something to it.
argo_civo_cluster_state() {
  [ "${PROVIDER:-}" = civo ] || return 0
  command -v civo_cli >/dev/null 2>&1 || return 0
  [ -n "${PROJECT_NAME:-}" ] || return 0
  civo_cli kubernetes show "$PROJECT_NAME" -o json 2>/dev/null \
    | jq -r '"ARGO-UP: civo cluster: status=\(.status // "?") ready=\(.ready // "?") target_nodes=\(.num_target_nodes // "?") instances: \([.instances[]? | "\(.hostname)=\(.status)"] | join(" "))"' 2>/dev/null \
    || true
}

# The API server's process start time plus the control-plane lease holders.
# Either changing across an outage proves the control plane restarted.
argo_control_plane_snapshot() {
  local start leases
  start="$(kubectl get --raw /metrics 2>/dev/null | grep -m1 '^process_start_time_seconds' | awk '{print $2}' || true)"
  leases="$(kubectl get lease -n kube-system -o json 2>/dev/null \
    | jq -r '.items[]? | "\(.metadata.name)=\(.spec.holderIdentity // "")"' 2>/dev/null || true)"
  printf 'start=%s\n%s\n' "$start" "$leases"
}

argo_control_plane_diff() {
  local before="$1" after="$2" b_start a_start name holder b_holder
  b_start="$(grep -m1 '^start=' <<< "$before" | cut -d= -f2 || true)"
  a_start="$(grep -m1 '^start=' <<< "$after" | cut -d= -f2 || true)"
  if [ -n "$b_start" ] && [ -n "$a_start" ] && [ "$b_start" != "$a_start" ]; then
    echo "ARGO-UP: API server process start time changed $b_start -> $a_start: the control plane restarted during the outage."
  elif [ -n "$a_start" ]; then
    echo "ARGO-UP: API server process start time unchanged ($a_start): the control plane did not restart."
  fi
  while IFS='=' read -r name holder; do
    [ -n "$name" ] && [ "$name" != start ] || continue
    b_holder="$(grep -m1 "^${name}=" <<< "$before" | cut -d= -f2- || true)"
    if [ -n "$b_holder" ] && [ "$b_holder" != "$holder" ]; then
      echo "ARGO-UP: lease $name holder changed $b_holder -> $holder"
    fi
  done <<< "$after"
}

argo_readyz_report() {
  local out
  out="$(kubectl get --raw '/readyz?verbose' 2>/dev/null || true)"
  if grep -q '^\[-\]' <<< "$out"; then
    echo "ARGO-UP: readyz failing checks:"
    grep '^\[-\]' <<< "$out" | sed 's/^/  /'
  elif [ -n "$out" ]; then
    echo "ARGO-UP: readyz: all checks ok"
  fi
}

argo_inflight() {
  kubectl get --raw /metrics 2>/dev/null \
    | awk '/^apiserver_current_inflight_requests/ { gsub(/.*request_kind="/, ""); gsub(/".*} /, ":"); printf "%s%s", sep, $0; sep="," } END { print "" }' \
    || true
}

# ---- node and scale-up tracking ----------------------------------------

ARGO_SEEN_NODES=""
ARGO_READY_NODES=""
ARGO_NODES_BASELINE_DONE=0
ARGO_NEW_NODE=""
ARGO_NEW_NODE_CREATED=""
ARGO_NEW_NODE_READY=""
ARGO_SCALEUP_STATUS=""
ARGO_SCALEUP_TRIGGERED=""

# Times come from the objects (creationTimestamp, the Ready condition's
# transition), not from when this loop happened to look.
argo_track_nodes() {
  local elapsed="$1" json name created ready rtime c r delay
  json="$(kubectl get nodes -o json 2>/dev/null)" || return 0
  while IFS=$'\t' read -r name created ready rtime; do
    [ -n "$name" ] || continue
    case " $ARGO_SEEN_NODES " in
      *" $name "*) ;;
      *)
        ARGO_SEEN_NODES="$ARGO_SEEN_NODES $name"
        if [ "$ARGO_NODES_BASELINE_DONE" = 1 ]; then
          echo "ARGO-UP: [+${elapsed}s] node $name registered (created $created)"
          ARGO_NEW_NODE="$name"
          ARGO_NEW_NODE_CREATED="$created"
        fi ;;
    esac
    [ "$ready" = True ] || continue
    case " $ARGO_READY_NODES " in
      *" $name "*) ;;
      *)
        ARGO_READY_NODES="$ARGO_READY_NODES $name"
        if [ "$ARGO_NODES_BASELINE_DONE" = 1 ]; then
          c="$(argo_epoch "$created")"; r="$(argo_epoch "$rtime")"; delay="unknown delay"
          if [ -n "$c" ] && [ -n "$r" ]; then delay="$((r - c))s after registration"; fi
          echo "ARGO-UP: [+${elapsed}s] node $name Ready at $rtime ($delay)"
          if [ "$name" = "$ARGO_NEW_NODE" ]; then ARGO_NEW_NODE_READY="$rtime"; fi
        fi ;;
    esac
  done < <(jq -r '.items[]? | [.metadata.name, .metadata.creationTimestamp,
      ((.status.conditions[]? | select(.type=="Ready") | .status) // ""),
      ((.status.conditions[]? | select(.type=="Ready") | .lastTransitionTime) // "")] | @tsv' <<< "$json")
  ARGO_NODES_BASELINE_DONE=1
}

# The autoscaler's status ConfigMap; its first scaleUp block is cluster-wide.
argo_track_scaleup() {
  [ "${PROVIDER:-}" = civo ] || return 0
  local elapsed="$1" text ttime="" status=""
  text="$(kubectl -n kube-system get configmap cluster-autoscaler-status -o jsonpath='{.data.status}' 2>/dev/null)" || return 0
  [ -n "$text" ] || return 0
  read -r ttime status < <(awk '/^ *scaleUp:/{f=1} f&&/lastTransitionTime:/{t=$2} f&&/status:/{print t, $2; exit}' <<< "$text") || true
  ttime="${ttime//\"/}"
  [ -n "$status" ] || return 0
  [ "$status" != "$ARGO_SCALEUP_STATUS" ] || return 0
  if [ "$status" = InProgress ]; then
    echo "ARGO-UP: [+${elapsed}s] scale-up InProgress since $ttime"
    ARGO_SCALEUP_TRIGGERED="$ttime"
    echo "ARGO-UP: pending pods at trigger:"
    kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | sed 's/^/  /' || true
  elif [ -n "$ARGO_SCALEUP_STATUS" ]; then
    echo "ARGO-UP: [+${elapsed}s] scale-up $status (was $ARGO_SCALEUP_STATUS) since $ttime"
  fi
  ARGO_SCALEUP_STATUS="$status"
}

argo_scaleup_timeline() {
  [ "${PROVIDER:-}" = civo ] || return 0
  if [ -z "$ARGO_SCALEUP_TRIGGERED" ]; then
    echo "ARGO-UP: scale-up timeline: no scale-up observed during the watch."
    return 0
  fi
  local t c r reg="?" rdy="?"
  t="$(argo_epoch "$ARGO_SCALEUP_TRIGGERED")"
  if [ -z "$ARGO_NEW_NODE" ]; then
    echo "ARGO-UP: scale-up timeline: triggered $ARGO_SCALEUP_TRIGGERED, no new node registered yet"
    return 0
  fi
  c="$(argo_epoch "$ARGO_NEW_NODE_CREATED")"
  if [ -n "$t" ] && [ -n "$c" ]; then reg="$((c - t))"; fi
  if [ -n "$ARGO_NEW_NODE_READY" ]; then
    r="$(argo_epoch "$ARGO_NEW_NODE_READY")"
    if [ -n "$t" ] && [ -n "$r" ]; then rdy="$((r - t))"; fi
  fi
  echo "ARGO-UP: scale-up timeline: triggered $ARGO_SCALEUP_TRIGGERED, $ARGO_NEW_NODE registered +${reg}s, Ready +${rdy}s"
}

# The autoscaler's own status ConfigMap names the pool's current and target
# sizes and any ScaleUp in progress - the one place that shows whether a
# bring-up scaled the pool or settled at the floor.
argo_autoscaler_summary() {
  [ "${PROVIDER:-}" = civo ] || return 0
  echo "ARGO-UP: cluster-autoscaler status:"
  kubectl -n kube-system get configmap cluster-autoscaler-status \
    -o jsonpath='{.data.status}' 2>/dev/null | head -80 | sed 's/^/  /' || echo "  (unavailable)"
}

# When the autoscaler decided to add a node: its events (kept only about an
# hour, so they must be read during the run) and the matching log lines.
argo_autoscaler_events() {
  [ "${PROVIDER:-}" = civo ] || return 0
  echo "ARGO-UP: scale-up events:"
  kubectl get events -A --field-selector reason=TriggeredScaleUp --sort-by=.lastTimestamp \
    -o custom-columns='TIME:.lastTimestamp,OBJECT:.involvedObject.name,MESSAGE:.message' --no-headers 2>/dev/null \
    | sed 's/^/  /' || true
  # Every event on the status ConfigMap, not one reason: ScaledUpGroup,
  # ScaleDown and any failure the autoscaler reports all land there.
  kubectl -n kube-system get events --field-selector involvedObject.name=cluster-autoscaler-status --sort-by=.lastTimestamp \
    -o custom-columns='TIME:.lastTimestamp,REASON:.reason,MESSAGE:.message' --no-headers 2>/dev/null \
    | sed 's/^/  /' || true
  # "adding node pool" is the provider's 10s cache refresh, not a scale-up.
  echo "ARGO-UP: autoscaler scale-up log lines:"
  kubectl -n kube-system logs -l app.kubernetes.io/instance=cluster-autoscaler --tail=2000 2>/dev/null \
    | grep -Ei 'scale-up|scale_up|scaleup|setting group|max size reached' | tail -15 | sed 's/^/  /' || true
}

argo_dump_diagnostics() {
  local failed
  argo_print_nodes
  echo "ARGO-UP: pending pods:"
  kubectl get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | sed 's/^/  /' || true
  echo "ARGO-UP: last FailedScheduling events:"
  kubectl get events -A --field-selector=reason=FailedScheduling --sort-by=.lastTimestamp \
    -o custom-columns='TIME:.lastTimestamp,POD:.involvedObject.name,MESSAGE:.message' --no-headers 2>/dev/null \
    | tail -5 | sed 's/^/  /' || true
  failed="$(argo_sync_failed_from "$1")"
  if [ -n "$failed" ]; then
    echo "ARGO-UP: resources SyncFailed in root's last operation:"
    echo "$failed"
  fi
  argo_autoscaler_summary
  argo_autoscaler_events
  argo_scaleup_timeline
  if [ "${PROVIDER:-}" = civo ]; then
    echo "ARGO-UP: cluster-autoscaler log tail:"
    kubectl -n kube-system logs -l app.kubernetes.io/instance=cluster-autoscaler --tail=20 2>/dev/null \
      | sed 's/^/  /' || true
  fi
}

# Returns 0 once root is Synced/Healthy, 1 on a failed sync or at the
# ceiling. Prints on every change, plus a heartbeat while nothing changes,
# so a silent log can only mean the script itself is gone.
argo_watch_root() {
  local watch="${ARGO_UP_WATCH_SECONDS:-2700}" poll="${ARGO_UP_POLL_INTERVAL:-5}"
  local heartbeat="${ARGO_UP_HEARTBEAT_SECONDS:-60}" prior="${PRIOR_OPERATION_STARTED_AT:-}"
  local start_ts elapsed=0 last_print_ts api_down_ts="" last_state="" json="{}" api_url cp_before cp_after
  local overall="" pending="" conditions="" op_phase="" op_started="" op_retries="" op_message="" state=""

  start_ts="$(date +%s)"
  last_print_ts="$start_ts"
  api_url="$(argo_api_server_url)"
  cp_before="$(argo_control_plane_snapshot)"

  while [ "$elapsed" -lt "$watch" ]; do
    if json="$(argo_root_json)"; then
      if [ -n "$api_down_ts" ]; then
        echo "ARGO-UP: [+${elapsed}s] API reachable again after $(( $(date +%s) - api_down_ts ))s."
        api_down_ts=""
        cp_after="$(argo_control_plane_snapshot)"
        argo_control_plane_diff "$cp_before" "$cp_after"
        cp_before="$cp_after"
        argo_readyz_report
        argo_civo_cluster_state
      fi
      argo_track_nodes "$elapsed"
      argo_track_scaleup "$elapsed"

      overall="$(jq -r '"\(.status.sync.status // "")/\(.status.health.status // "")"' <<< "$json")"
      pending="$(argo_pending_from "$json")"
      conditions="$(argo_conditions_from "$json")"
      IFS=$'\t' read -r op_phase op_started op_retries op_message < <(jq -r '
        (.status.operationState // {})
        | [.phase // "", .startedAt // "", ((.retryCount // 0) | tostring),
           (.message // "" | gsub("\n"; " "))]
        | @tsv' <<< "$json") || true

      state="$overall|$op_phase|$op_retries|$pending|$conditions"
      if [ "$state" != "$last_state" ]; then
        echo "ARGO-UP: [+${elapsed}s] root ${overall:-pending} op=${op_phase:-none}(retries=${op_retries:-0}) - still reconciling: ${pending:-none}"
        if [ -n "$conditions" ]; then echo "ARGO-UP: conditions: $conditions"; fi
        echo "ARGO-UP: applications:"
        argo_print_app_status
        last_state="$state"
        last_print_ts="$(date +%s)"
      fi

      if [ "$overall" = "Synced/Healthy" ]; then
        argo_print_nodes
        argo_autoscaler_summary
        argo_autoscaler_events
        argo_scaleup_timeline
        rm -f "$ARGO_WATCH_ERR"
        return 0
      fi

      # Argo keeps phase at Running through the whole syncPolicy.retry
      # sequence, so a terminal phase means the retry budget is spent.
      if { [ "$op_phase" = Failed ] || [ "$op_phase" = Error ]; } && [ "$op_started" != "$prior" ]; then
        {
          echo "ARGO-UP: root sync $op_phase after $op_retries retries - Argo will not re-run it for this revision."
          echo "ARGO-UP: $op_message"
          if [ -n "$conditions" ]; then echo "ARGO-UP: conditions: $conditions"; fi
          echo "ARGO-UP: still reconciling: ${pending:-none}"
          echo "ARGO-UP: applications:"
          argo_print_app_status
          argo_dump_diagnostics "$json"
        } >&2
        rm -f "$ARGO_WATCH_ERR"
        return 1
      fi
    else
      if [ -z "$api_down_ts" ]; then
        api_down_ts="$(date +%s)"
        echo "ARGO-UP: [+${elapsed}s] API unreachable (kubectl: $(head -n1 "$ARGO_WATCH_ERR" 2>/dev/null)) - keeping the watch alive."
        argo_civo_cluster_state
      fi
      echo "ARGO-UP: [+${elapsed}s] API probe: $(argo_api_probe "$api_url") kubectl: $(head -n1 "$ARGO_WATCH_ERR" 2>/dev/null)"
      argo_track_nodes "$elapsed"
      argo_track_scaleup "$elapsed"
    fi

    if [ $(( $(date +%s) - last_print_ts )) -ge "$heartbeat" ]; then
      echo "ARGO-UP: [+${elapsed}s] waiting - root ${overall:-pending} op=${op_phase:-none}(retries=${op_retries:-0}) pending=$(wc -w <<< "$pending" | tr -d ' ') inflight=$(argo_inflight)"
      last_print_ts="$(date +%s)"
    fi
    sleep "$poll"
    elapsed=$(( $(date +%s) - start_ts ))
  done

  {
    echo "ARGO-UP: timed out after ${watch}s waiting for root to become Synced/Healthy - still reconciling: ${pending:-none}"
    echo "ARGO-UP: applications:"
    argo_print_app_status
    argo_dump_diagnostics "$json"
  } >&2
  rm -f "$ARGO_WATCH_ERR"
  return 1
}
