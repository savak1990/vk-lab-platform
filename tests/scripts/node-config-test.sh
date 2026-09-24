#!/usr/bin/env bash
# Pins the offline node-configuration gate: which (PROVIDER, REGION) pairs it
# accepts, and that aws refuses a region rather than quietly ignoring one.
# Needs no credentials and no fake aws - the gate never calls a cloud, which
# is the whole point of it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fails=0

# The library ends in exit 1, not return 1, so a refused case would kill this
# script. Each case therefore runs in its own shell.
#
# NODE_TYPE and NODE_COUNT are cleared, not inherited: run under `make` they
# arrive already set for whichever provider the Makefile defaulted to, and a
# civo case would then fail on an aws node type instead of on its region.
# Empty means "unset" to the gate, which fills in the catalogue default.
run_case() {
  ( cd "$REPO_ROOT" && PROVIDER="$1" REGION="$2" NODE_TYPE="" NODE_COUNT="" \
      CONTROL_PLANE_NODE_TYPE="${3:-}" bash -c '
      source scripts/lib/require-valid-node-config.sh
      require_valid_node_config' ) 2>&1
}

expect() {
  local want="$1" provider="$2" region="$3" match="${4:-}" out rc
  out="$(run_case "$provider" "$region")"
  rc=$?
  if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: PROVIDER=$provider REGION='$region' should pass, rc=$rc"
    echo "$out"
    fails=$((fails + 1))
    return
  fi
  if [ "$want" = refuse ] && [ "$rc" -eq 0 ]; then
    echo "FAIL: PROVIDER=$provider REGION='$region' should be refused"
    fails=$((fails + 1))
    return
  fi
  if [ -n "$match" ] && ! printf '%s' "$out" | grep -q "$match"; then
    echo "FAIL: PROVIDER=$provider REGION='$region' missing '$match'"
    echo "$out"
    fails=$((fails + 1))
    return
  fi
  echo "ok: PROVIDER=$provider REGION='$region' -> $want"
}

AWS_RULE="not an input for PROVIDER=aws"

# aws: the region is fixed, so only the one legal value is accepted.
expect pass   aws     ""
expect pass   aws     eu-west-1
expect pass   aws     EU-WEST-1
expect refuse aws     us-east-1 "$AWS_RULE"
expect refuse aws     eu-west-2 "$AWS_RULE"
# The leftover-export case: a Civo region still set when the target changed.
expect refuse aws     FRA1      "$AWS_RULE"

# civo and hetzner: REGION selects, case-insensitively, within the catalogue.
expect pass   civo    ""
expect pass   civo    FRA1
expect pass   civo    fra1
expect refuse civo    nbg1
expect pass   hetzner ""
expect pass   hetzner hel1
expect pass   hetzner fsn1
expect refuse hetzner LON1

# local owns no cloud resources and ignores all three inputs.
expect pass   local   us-east-1
expect pass   local   FRA1

# CONTROL_PLANE_NODE_TYPE sizes the one server the platform owns itself, which
# exists on hetzner alone. Blank is inert everywhere; a value anywhere else is
# refused rather than ignored, the same way a REGION on aws is.
expect_cp() {
  local want="$1" provider="$2" region="$3" cp="$4" match="${5:-}" out rc
  out="$(run_case "$provider" "$region" "$cp")"
  rc=$?
  if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: PROVIDER=$provider CONTROL_PLANE_NODE_TYPE='$cp' should pass, rc=$rc"
    echo "$out"
    fails=$((fails + 1))
    return
  fi
  if [ "$want" = refuse ] && [ "$rc" -eq 0 ]; then
    echo "FAIL: PROVIDER=$provider CONTROL_PLANE_NODE_TYPE='$cp' should be refused"
    fails=$((fails + 1))
    return
  fi
  if [ -n "$match" ] && ! printf '%s' "$out" | grep -q "$match"; then
    echo "FAIL: PROVIDER=$provider CONTROL_PLANE_NODE_TYPE='$cp' missing '$match'"
    echo "$out"
    fails=$((fails + 1))
    return
  fi
  echo "ok: PROVIDER=$provider CONTROL_PLANE_NODE_TYPE='$cp' -> $want"
}

CP_RULE="CONTROL_PLANE_NODE_TYPE is not an input for PROVIDER"

expect_cp pass   hetzner fsn1      ""
expect_cp pass   hetzner fsn1      cx23
expect_cp pass   hetzner fsn1      CX23
expect_cp pass   hetzner hel1      cx23
expect_cp refuse hetzner hel1      cx43 "not allowed in 'hel1'"
expect_cp refuse hetzner fsn1      cax11 "not allowed in 'fsn1'"
expect_cp pass   aws     ""        ""
expect_cp refuse aws     ""        t4g.medium "$CP_RULE"
expect_cp pass   civo    FRA1      ""
expect_cp refuse civo    FRA1      g4s.kube.medium "$CP_RULE"
expect_cp pass   local   ""        ""
expect_cp pass   local   ""        cx23

[ "$fails" -eq 0 ] || {
  echo "$fails case(s) failed"
  exit 1
}
echo "all node-config cases passed"
