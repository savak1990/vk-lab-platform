#!/usr/bin/env bash
# Watches the root Application until it is Synced/Healthy. Sourced by
# argo-up.sh; every kubectl call here is guarded, because the caller runs
# under set -e and an API blip mid-watch must be reported, never fatal.

argo_root_json() {
  kubectl get application root -n argocd -o json 2>/dev/null
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

# The autoscaler's own status ConfigMap names the pool's current and target
# sizes and any ScaleUp in progress - the one place that shows whether a
# bring-up scaled the pool or settled at the floor.
argo_autoscaler_summary() {
  [ "${PROVIDER:-}" = civo ] || return 0
  echo "ARGO-UP: cluster-autoscaler status:"
  kubectl -n kube-system get configmap cluster-autoscaler-status \
    -o jsonpath='{.data.status}' 2>/dev/null | head -25 | sed 's/^/  /' || echo "  (unavailable)"
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
  local elapsed=0 since_print=0 last_state="" api_down_since="" json="{}"
  local overall="" pending="" conditions="" op_phase="" op_started="" op_retries="" op_message="" state=""

  while [ "$elapsed" -lt "$watch" ]; do
    if json="$(argo_root_json)"; then
      if [ -n "$api_down_since" ]; then
        echo "ARGO-UP: [+${elapsed}s] API reachable again after $((elapsed - api_down_since))s."
        api_down_since=""
      fi
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
        since_print=0
      fi

      if [ "$overall" = "Synced/Healthy" ]; then
        argo_print_nodes
        argo_autoscaler_summary
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
        return 1
      fi
    elif [ -z "$api_down_since" ]; then
      api_down_since="$elapsed"
      echo "ARGO-UP: [+${elapsed}s] API unreachable (kubectl get application failed) - keeping the watch alive."
    fi

    if [ "$since_print" -ge "$heartbeat" ]; then
      echo "ARGO-UP: [+${elapsed}s] waiting - root ${overall:-pending} op=${op_phase:-none}(retries=${op_retries:-0}) pending=$(wc -w <<< "$pending" | tr -d ' ')"
      since_print=0
    fi
    sleep "$poll"
    elapsed=$((elapsed + poll))
    since_print=$((since_print + poll))
  done

  {
    echo "ARGO-UP: timed out after ${watch}s waiting for root to become Synced/Healthy - still reconciling: ${pending:-none}"
    echo "ARGO-UP: applications:"
    argo_print_app_status
    argo_dump_diagnostics "$json"
  } >&2
  return 1
}
