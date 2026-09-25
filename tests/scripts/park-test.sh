#!/usr/bin/env bash
# Exercises park.sh against fake CLIs on PATH, with no credentials and no cloud.
# The case that matters most is that a park leaves Argo CD's root Application
# alone: root is what makes cluster-down refuse, and a parked cluster's servers
# and volumes still carry the labels a teardown sweep matches on - so a park that
# removed root would quietly arm the next `make down` to delete a live cluster.
# Usage: tests/scripts/park-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/real"

# yq is the real one: configure_kubeconfig rewrites the fetched kubeconfig with
# it, and what is under test is park.sh, not yq.
for tool in jq yq sed awk grep; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && ln -sf "$real" "$TMP/real/$tool"
done
PATH_FAKE="$TMP/bin:$TMP/real:/usr/bin:/bin"

# Every fake records what it was asked to do, so an assertion can check that a
# command was NOT issued - which is the whole point of the root-Application case.
CALLS="$TMP/calls"
: > "$CALLS"

cat > "$TMP/bin/hcloud" <<'EOF'
#!/usr/bin/env bash
echo "hcloud $*" >> "$CALLS"
if [ "$1 $2" = "server list" ]; then
  case "$*" in
    *role=control-plane*) echo '[{"name":"vk-fake-hz-cp-1"}]' ;;
    *managed_by=autoscaler*) echo '[]' ;;
    *role=worker*)
      if [ "${FAKE_PARKED:-no}" = yes ]; then echo '[]'
      else echo '[{"name":"vk-fake-hz-worker-1"}]'; fi ;;
    *) echo '[]' ;;
  esac
  exit 0
fi
exit 0
EOF

# The control-plane IP comes from SSM; nothing else here reads AWS.
cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
case "$*" in
  *"ssm get-parameter"*) echo "203.0.113.10" ;;
  *) echo "None" ;;
esac
EOF

# cluster_exists sshes the control plane to confirm k3s really installed.
# configure_kubeconfig fetches k3s.yaml off the control plane over ssh, so the
# fake has to serve one: a park runs against a live control plane by definition.
cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$CALLS"
case "$*" in
  *k3s.yaml*)
    cat <<'YAML'
apiVersion: v1
kind: Config
clusters:
- cluster: {server: https://127.0.0.1:6443}
  name: default
contexts:
- context: {cluster: default, user: default}
  name: default
current-context: default
users:
- name: default
  user: {token: fake}
YAML
    ;;
esac
exit "${FAKE_SSH_RC:-0}"
EOF

cat > "$TMP/bin/secret-decrypt.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake-secret"
EOF

# The marker lets the fake kubectl model the one thing that matters to unpark:
# the worker Node exists only after the apply that creates its server.
cat > "$TMP/bin/terragrunt" <<'EOF'
#!/usr/bin/env bash
echo "terragrunt $* MIN_WORKER_NODES=${MIN_WORKER_NODES:-unset}" >> "$CALLS"
touch "$APPLIED"
exit 0
EOF

# One worker Node beside the tainted control plane, so the drain and the stale
# Node deletion both have something to act on.
cat > "$TMP/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$CALLS"
case "$*" in
  *"cluster-info"*) exit "${FAKE_API_RC:-0}" ;;
  *"get application root"*) exit "${FAKE_ROOT_RC:-0}" ;;
  *"get nodes"*)
    worker=yes
    [ "${FAKE_PARKED:-no}" = yes ] && worker=no
    [ -f "$APPLIED" ] && worker=yes
    case "$*" in
      *'!node-role.kubernetes.io/control-plane'*)
        [ "$worker" = yes ] && echo "vk-fake-hz-worker-1" ;;
      *)
        echo "vk-fake-hz-cp-1   Ready   control-plane   1d   v1.36.4+k3s1"
        [ "$worker" = yes ] && echo "vk-fake-hz-worker-1   Ready   <none>   1d   v1.36.4+k3s1" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF

chmod +x "$TMP/bin"/*

fail=0
err() { echo "PARK-TEST: $*" >&2; fail=1; }

# The real script, run from a copy whose secret-decrypt.sh is the stub above, so
# nothing reaches KMS.
WORK="$TMP/repo"
mkdir -p "$WORK/scripts/lib" "$WORK/terraform/live/cluster-hetzner"
cp "$REPO_ROOT/scripts/park.sh" "$WORK/scripts/"
cp "$REPO_ROOT"/scripts/lib/*.sh "$WORK/scripts/lib/"
cp "$TMP/bin/secret-decrypt.sh" "$WORK/scripts/secret-decrypt.sh"

APPLIED="$TMP/applied"
export APPLIED

# Budgets are cut to seconds, not their 600s and 10s production values: a
# regression here must fail in a few seconds rather than look like a hang.
run() {
  local direction="$1" provider="$2"
  shift 2
  rm -f "$APPLIED"
  # The inherited Makefile exports are cleared, not overridden: provider.sh
  # derives each with ${X:-default}, so a value make already exported for
  # another provider would freeze and send this at the wrong stack directory.
  ( cd "$WORK" && env -u CLUSTER_DIR -u PERSISTENT_EXTRA_DIR -u SUBDOMAIN \
      -u BOOTSTRAP_EXCLUDE -u PERSISTENT_EXCLUDE -u CLUSTER_NAME \
      PATH="$PATH_FAKE" CALLS="$CALLS" APPLIED="$APPLIED" \
      PROVIDER="$provider" PROJECT_NAME=vk-fake-hz REGION=fsn1 \
      WORKER_NODE_TYPE=cx43 MIN_WORKER_NODES=1 MAX_WORKER_NODES=2 \
      CONTROL_PLANE_NODE_TYPE=cx23 AWS_PROFILE=fake \
      HETZNER_NODE_READY_SECONDS=10 ARGO_UP_POLL_INTERVAL=1 \
      API_REACHABLE_ATTEMPTS=1 API_REACHABLE_INTERVAL=1 \
      PARK_DRAIN_SECONDS=5 \
      "$@" ./scripts/park.sh "$direction" 2>&1 )
}

# 1. Every target except hetzner refuses, and the aws message names the spec that
#    costed the decline so the operator can read why rather than guess.
out="$(run park aws)"; rc=$?
[ "$rc" -ne 0 ] || err "aws: expected a refusal, got rc=0: $out"
case "$out" in
  *"not supported on aws"*) ;;
  *) err "aws: expected the refusal to name the provider, got: $out" ;;
esac
case "$out" in
  *Karpenter*) ;;
  *) err "aws: the refusal must say why, not just no: $out" ;;
esac

out="$(run park civo)"; rc=$?
[ "$rc" -ne 0 ] || err "civo: expected a refusal, got rc=0: $out"
case "$out" in
  *"not supported on civo"*) ;;
  *) err "civo: expected the refusal to name the provider, got: $out" ;;
esac

out="$(run park local)"; rc=$?
[ "$rc" -ne 0 ] || err "local: expected a refusal, got rc=0: $out"

# 2. An unreachable API refuses rather than destroying a worker it cannot drain.
: > "$CALLS"
out="$(run park hetzner FAKE_API_RC=1)"; rc=$?
[ "$rc" -ne 0 ] || err "unreachable API: expected a refusal, got rc=0: $out"
if grep -q '^terragrunt' "$CALLS"; then
  err "unreachable API: refused but still ran terragrunt: $(grep '^terragrunt' "$CALLS")"
fi

# 3. Root missing refuses too: that means a teardown is in progress, and parking
#    on top of it would leave a half-destroyed cluster wearing a parked shape.
: > "$CALLS"
out="$(run park hetzner FAKE_ROOT_RC=1)"; rc=$?
[ "$rc" -ne 0 ] || err "root missing: expected a refusal, got rc=0: $out"

# 4. The park itself: drains, applies at zero, reaps the Node - and never touches
#    the root Application.
: > "$CALLS"
out="$(run park hetzner)"; rc=$?
[ "$rc" -eq 0 ] || err "park: expected rc=0, got $rc: $out"
grep -q 'kubectl drain vk-fake-hz-worker-1' "$CALLS" \
  || err "park: the worker must be drained before its server goes: $(cat "$CALLS")"
grep -q 'terragrunt.*MIN_WORKER_NODES=0' "$CALLS" \
  || err "park: terragrunt must be applied with MIN_WORKER_NODES=0: $(grep '^terragrunt' "$CALLS")"
grep -q 'kubectl delete node vk-fake-hz-worker-1' "$CALLS" \
  || err "park: the stale Node object must be deleted, or the unpark's readiness wait never returns"
if grep -qE 'kubectl delete application|delete .*application root' "$CALLS"; then
  err "park: deleted Argo CD's root Application - that is what makes cluster-down refuse: $(cat "$CALLS")"
fi
# Ordering matters: a drain after the server is gone drains nothing.
drain_line="$(grep -n 'kubectl drain' "$CALLS" | head -1 | cut -d: -f1)"
tg_line="$(grep -n '^terragrunt' "$CALLS" | head -1 | cut -d: -f1)"
if [ -n "$drain_line" ] && [ -n "$tg_line" ] && [ "$drain_line" -gt "$tg_line" ]; then
  err "park: drained after the apply that destroys the server, so the drain was pointless"
fi

# 5. Idempotent. A second park must not try to drain a worker that is not there.
: > "$CALLS"
out="$(run park hetzner FAKE_PARKED=yes)"; rc=$?
[ "$rc" -eq 0 ] || err "park twice: expected rc=0, got $rc: $out"
case "$out" in
  *"already parked"*) ;;
  *) err "park twice: expected it to say it was already parked, got: $out" ;;
esac
if grep -q 'kubectl drain' "$CALLS"; then
  err "park twice: drained something on an already-parked cluster: $(cat "$CALLS")"
fi
if grep -q '^terragrunt' "$CALLS"; then
  err "park twice: re-applied on an already-parked cluster: $(cat "$CALLS")"
fi

# 6. unpark on a running cluster refuses; on a parked one it applies at the floor.
: > "$CALLS"
out="$(run unpark hetzner)"; rc=$?
[ "$rc" -ne 0 ] || err "unpark while running: expected a refusal, got rc=0: $out"
if grep -q '^terragrunt' "$CALLS"; then
  err "unpark while running: refused but still ran terragrunt"
fi

: > "$CALLS"
out="$(run unpark hetzner FAKE_PARKED=yes)"; rc=$?
[ "$rc" -eq 0 ] || err "unpark: expected rc=0, got $rc: $out"
grep -q 'terragrunt.*MIN_WORKER_NODES=1' "$CALLS" \
  || err "unpark: must apply at the real floor, not zero: $(grep '^terragrunt' "$CALLS")"

if [ "$fail" -eq 0 ]; then
  echo "PARK-TEST: ok - every non-hetzner target refuses with a reason, an unreachable API and a missing root both refuse before terragrunt, a park drains then applies at zero then reaps the Node without touching root, a second park is a no-op, and unpark refuses while running."
fi
exit "$fail"
