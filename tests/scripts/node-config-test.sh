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
# Every input is cleared, not inherited: run under `make` they arrive already
# set for whichever provider the Makefile defaulted to, and a civo case would
# then fail on an aws node type instead of on its region. Empty means "unset"
# to the gate, which fills in the catalogue default.
run_case() {
  ( cd "$REPO_ROOT" && PROVIDER="$1" REGION="$2" WORKER_NODE_TYPE="" \
      CONTROL_PLANE_NODE_TYPE="${3:-}" \
      MIN_WORKER_NODES="${4:-}" MAX_WORKER_NODES="${5:-}" bash -c '
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

# MIN_WORKER_NODES and MAX_WORKER_NODES count worker nodes only. The pair must
# be whole and ordered; hetzner carries a ceiling as well, because a run that
# takes four of the account's five servers leaves CI unable to start.
expect_mm() {
  local want="$1" provider="$2" region="$3" mn="$4" mx="$5" match="${6:-}" out rc
  out="$(run_case "$provider" "$region" "" "$mn" "$mx")"
  rc=$?
  if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: $provider MIN='$mn' MAX='$mx' should pass, rc=$rc"
    echo "$out"
    fails=$((fails + 1))
    return
  fi
  if [ "$want" = refuse ] && [ "$rc" -eq 0 ]; then
    echo "FAIL: $provider MIN='$mn' MAX='$mx' should be refused"
    fails=$((fails + 1))
    return
  fi
  if [ -n "$match" ] && ! printf '%s' "$out" | grep -q "$match"; then
    echo "FAIL: $provider MIN='$mn' MAX='$mx' missing '$match'"
    echo "$out"
    fails=$((fails + 1))
    return
  fi
  echo "ok: $provider MIN='$mn' MAX='$mx' -> $want"
}

# Blank on both sides takes the catalogue defaults.
expect_mm pass   hetzner ""   ""  ""
expect_mm pass   civo    ""   ""  ""
expect_mm pass   aws     ""   ""  ""
expect_mm pass   local   ""   ""  ""

expect_mm pass   hetzner fsn1 1   2
expect_mm pass   hetzner fsn1 1   3
expect_mm pass   hetzner fsn1 2   2
expect_mm refuse hetzner fsn1 1   4 "5 server"
expect_mm refuse hetzner fsn1 2   1 "at least MIN_WORKER_NODES"
expect_mm refuse hetzner fsn1 0   2 "positive integer"
expect_mm refuse hetzner fsn1 one 2 "positive integer"
expect_mm refuse hetzner fsn1 1   x "positive integer"

# civo and aws have no per-account server cap, so only the pair is checked.
expect_mm pass   civo    FRA1 3   4
expect_mm pass   civo    FRA1 3   9
expect_mm refuse civo    FRA1 4   3 "at least MIN_WORKER_NODES"
expect_mm pass   aws     ""   1   3
expect_mm refuse aws     ""   3   1 "at least MIN_WORKER_NODES"

# local owns no cloud resources and ignores these too.
expect_mm pass   local   ""   9   1

# lab.yml lists the node types in two dropdowns. That list is a second copy of
# the catalogue and drifts silently, so it is compared here rather than trusted.
lab_options() {
  awk -v key="      $1:" '
    $0 == key { in_input = 1; next }
    in_input && /^        options:$/ { in_opts = 1; next }
    in_opts && /^          - / {
      line = $0
      sub(/^          - "/, "", line)
      sub(/"$/, "", line)
      print line
      next
    }
    in_opts { exit }
  ' "$REPO_ROOT/.github/workflows/lab.yml"
}

catalogue_options() {
  ( cd "$REPO_ROOT" && bash -c '
    source scripts/lib/catalog.sh
    for provider in aws civo hetzner; do
      seen=""
      for region in $(catalog_regions "$provider"); do
        for type in $(catalog_node_types "$provider" "$region"); do
          case " $seen " in *" $type "*) continue ;; esac
          seen="$seen $type"
          echo "$provider: $type"
        done
      done
    done' )
}

want="$(catalogue_options)"
got="$(lab_options worker_node_type | grep -v '^default')"
if [ "$want" != "$got" ]; then
  echo "FAIL: lab.yml worker_node_type options differ from scripts/lib/catalog.sh"
  diff <(echo "$want") <(echo "$got") || true
  fails=$((fails + 1))
fi

want="$(catalogue_options | grep '^hetzner: ')"
got="$(lab_options control_plane_node_type | grep -v '^default')"
if [ "$want" != "$got" ]; then
  echo "FAIL: lab.yml control_plane_node_type options differ from the hetzner catalogue"
  diff <(echo "$want") <(echo "$got") || true
  fails=$((fails + 1))
fi

# The first option of each dropdown must reduce to empty, or make's ?= default
# stops winning and every run is pinned to one type.
for input in worker_node_type control_plane_node_type; do
  first="$(lab_options "$input" | head -1)"
  case "$first" in
    default*) ;;
    *)
      echo "FAIL: lab.yml $input first option '$first' does not start with 'default'"
      fails=$((fails + 1))
      ;;
  esac
done

# The same normaliser lab.yml runs on the two dropdown values, kept in step by
# eye: a label that stops reducing to empty would pin every run to one type.
node_type_of() {
  case "$1" in
    default*) echo "" ;;
    *) echo "${1##* }" ;;
  esac
}

expect_strip() {
  local got
  got="$(node_type_of "$1")"
  if [ "$got" != "$2" ]; then
    echo "FAIL: node_type_of '$1' gave '$got', want '$2'"
    fails=$((fails + 1))
  else
    echo "ok: node_type_of '$1' -> '$got'"
  fi
}

for input in worker_node_type control_plane_node_type; do
  while IFS= read -r option; do
    case "$option" in
      default*) expect_strip "$option" "" ;;
      *) expect_strip "$option" "${option##* }" ;;
    esac
  done < <(lab_options "$input")
done
expect_strip "" ""

[ "$fails" -eq 0 ] || {
  echo "$fails case(s) failed"
  exit 1
}
echo "all node-config cases passed"
