#!/usr/bin/env bash
# Covers hetzner_fetch_k3s_kubeconfig's two different waits: a connection that
# is refused while the server boots, and a connection that opens onto a machine
# where k3s.yaml never arrives. hetzner_ssh is stubbed, so nothing reaches a
# network or a key.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=scripts/lib/provider.sh
PROVIDER=hetzner . scripts/lib/provider.sh

fail=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*" >&2; fail=1; }

export HETZNER_K3S_WAIT_SECONDS=6
export HETZNER_K3S_POLL_INTERVAL=1

# ssh exits 255 when it cannot open a connection at all. The stub counts calls
# so a test can refuse the first few and then answer.
SSH_CALLS=0
REFUSE_UNTIL=0
KUBECONFIG_BODY="apiVersion: v1"
hetzner_ssh() {
  SSH_CALLS=$((SSH_CALLS + 1))
  if [ "$SSH_CALLS" -le "$REFUSE_UNTIL" ]; then
    return 255
  fi
  if [ -z "$KUBECONFIG_BODY" ]; then
    return 1
  fi
  printf '%s\n' "$KUBECONFIG_BODY"
  return 0
}

# Not a command substitution: that runs the function in a subshell, where the
# stub's call counter increments and is then thrown away.
run_fetch() {
  SSH_CALLS=0
  REFUSE_UNTIL="$1"
  KUBECONFIG_BODY="$2"
  out="$(mktemp)"
  errfile="$(mktemp)"
  hetzner_fetch_k3s_kubeconfig 1.2.3.4 "$out" 2>"$errfile" >/dev/null
  rc=$?
  body="$(cat "$out")"
  err="$(cat "$errfile")"
  rm -f "$out" "$errfile"
}

# A connection that opens on the first try is the ordinary case.
run_fetch 0 "apiVersion: v1"
[ "$rc" -eq 0 ] && ok "connects first try: exit 0" || bad "connects first try: exit $rc"
[ "$body" = "apiVersion: v1" ] && ok "connects first try: kubeconfig written" || bad "connects first try: body '$body'"
[ "$SSH_CALLS" -eq 1 ] && ok "connects first try: one ssh call" || bad "connects first try: $SSH_CALLS ssh calls"

# The regression this function exists for: sshd is not up yet, ssh exits 255,
# and the old code reported a k3s timeout it had never waited for.
run_fetch 2 "apiVersion: v1"
[ "$rc" -eq 0 ] && ok "retries a refused connection: exit 0" || bad "retries a refused connection: exit $rc"
[ "$SSH_CALLS" -eq 3 ] && ok "retries a refused connection: retried twice" || bad "retries a refused connection: $SSH_CALLS ssh calls"
[ "$body" = "apiVersion: v1" ] && ok "retries a refused connection: kubeconfig written" || bad "retries a refused connection: body '$body'"

# A connection that never opens must say so, not blame k3s.
run_fetch 999 "apiVersion: v1"
[ "$rc" -ne 0 ] && ok "never connects: non-zero exit" || bad "never connects: exit 0"
case "$err" in
  *"no ssh connection"*) ok "never connects: names the connection, not k3s" ;;
  *) bad "never connects: message was '$err'" ;;
esac

# A connection that opens onto a server without k3s.yaml keeps the old message,
# and must not be retried as though it were a connection failure.
run_fetch 0 ""
[ "$rc" -ne 0 ] && ok "connects but no file: non-zero exit" || bad "connects but no file: exit 0"
[ "$SSH_CALLS" -eq 1 ] && ok "connects but no file: not retried" || bad "connects but no file: $SSH_CALLS ssh calls"
case "$err" in
  *"did not appear"*) ok "connects but no file: names k3s.yaml" ;;
  *) bad "connects but no file: message was '$err'" ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "hetzner-kubeconfig-fetch-test: ok"
else
  echo "hetzner-kubeconfig-fetch-test: FAILED" >&2
fi
exit "$fail"
