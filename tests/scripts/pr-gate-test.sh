#!/usr/bin/env bash
# Exercises pr-gate's decision step (.github/workflows/lifecycle-test.yml)
# against label and job-result combinations, by extracting its `run:` block and
# running it with the same environment Actions would give it.
#
# TRIGGERED and WANTS_<provider> are what the `changes` job's label step emits:
# TRIGGERED is the `ci:lifecycle` trigger, and WANTS_<provider> already folds
# the trigger together with the provider selectors.
# Usage: tests/scripts/pr-gate-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/lifecycle-test.yml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

yq '.jobs.pr-gate.steps[0].run' "$WORKFLOW" > "$TMP/gate.sh"
if [ ! -s "$TMP/gate.sh" ]; then
  echo "pr-gate-test: could not extract the decision step from $WORKFLOW" >&2
  exit 1
fi

PASS=0
FAIL=0

# run <name> <expected-rc> <expected-substring> [VAR=value ...]
run() {
  local name="$1" want_rc="$2" want_text="$3"
  shift 3
  local out rc
  out="$(
    env -i \
      PATH="$PATH" \
      CHANGES_RESULT=success DOCS_ONLY=false TERRAFORM=true INFRA=true \
      INFRA_FILES=gitops/values.yaml \
      R_TERRAFORM=success R_GITOPS=success R_YAML=success \
      R_ACTIONS=success R_SECRETS=success R_REPO=success \
      LIFECYCLE_AWS=skipped LIFECYCLE_CIVO=skipped \
      EVENT_NAME=pull_request \
      HEAD_REPO=owner/repo GITHUB_REPOSITORY=owner/repo \
      TRIGGERED=false WANTS_SKIP=false WANTS_AWS=false WANTS_CIVO=false \
      WANTS_HETZNER=false WANTS_LOCAL=false \
      GITHUB_STEP_SUMMARY=/dev/null \
      "$@" \
      bash "$TMP/gate.sh" 2>&1
  )"
  rc=$?
  if [ "$rc" = "$want_rc" ] && [[ "$out" == *"$want_text"* ]]; then
    PASS=$((PASS + 1))
    printf 'ok   %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL %s: rc=%s (want %s), expected to see %q\n' "$name" "$rc" "$want_rc" "$want_text"
    printf '%s\n' "$out" | sed 's/^/       /'
  fi
}

# --- nothing asked for ------------------------------------------------------

run "no label on an infrastructure change" 1 "needs the lifecycle check"
run "no label, no infrastructure change" 0 "not required" \
  INFRA=false
# A selector on its own is inert, so this is the same state as no label at all.
# That is what lets two selectors be added without starting two runs.
run "a selector alone starts nothing" 1 "needs the lifecycle check" \
  TRIGGERED=false WANTS_AWS=false WANTS_CIVO=false

# --- ci:lifecycle, with and without selectors -------------------------------

run "ci:lifecycle alone runs every provider" 0 "civo: came up" \
  TRIGGERED=true WANTS_AWS=true WANTS_CIVO=true \
  LIFECYCLE_AWS=success LIFECYCLE_CIVO=success
run "ci:lifecycle alone, aws fails" 1 "the aws lifecycle did not pass" \
  TRIGGERED=true WANTS_AWS=true WANTS_CIVO=true \
  LIFECYCLE_AWS=failure LIFECYCLE_CIVO=success
run "ci:lifecycle + ci:civo runs civo only" 0 "Not exercised: aws" \
  TRIGGERED=true WANTS_CIVO=true LIFECYCLE_CIVO=success
run "ci:lifecycle + ci:civo, civo fails" 1 "the civo lifecycle did not pass" \
  TRIGGERED=true WANTS_CIVO=true LIFECYCLE_CIVO=failure
run "ci:lifecycle + ci:aws runs aws only" 0 "Not exercised: civo" \
  TRIGGERED=true WANTS_AWS=true LIFECYCLE_AWS=success
run "ci:lifecycle + both selectors" 0 "aws: came up" \
  TRIGGERED=true WANTS_AWS=true WANTS_CIVO=true \
  LIFECYCLE_AWS=success LIFECYCLE_CIVO=success
# The case result-inference could not tell apart from an unlabelled pull
# request: both report skipped, and only one of them may merge.
run "a selected provider whose job did not run" 1 "the aws lifecycle did not pass" \
  TRIGGERED=true WANTS_AWS=true
# A requested provider is judged whether or not the change is infrastructure:
# a failed run nobody asked to ignore is worse than one nobody asked for.
run "ci:lifecycle + ci:aws on a non-infrastructure change, aws fails" 1 "the aws lifecycle did not pass" \
  INFRA=false TRIGGERED=true WANTS_AWS=true LIFECYCLE_AWS=failure

# --- selectors with no job behind them --------------------------------------

run "ci:lifecycle + ci:hetzner, which has no job" 1 "no hetzner lifecycle job exists" \
  TRIGGERED=true WANTS_HETZNER=true
run "ci:lifecycle + ci:local, which has no job" 1 "no local lifecycle job exists" \
  TRIGGERED=true WANTS_LOCAL=true

# --- the waiver -------------------------------------------------------------

run "ci:lifecycle and the skip label" 1 "opposite things" \
  TRIGGERED=true WANTS_CIVO=true WANTS_SKIP=true
# A selector is not a request, so it does not contradict the waiver.
run "a selector and the skip label" 0 "WAIVED" \
  WANTS_SKIP=true
run "skip label alone" 0 "WAIVED" \
  WANTS_SKIP=true

# --- everything else --------------------------------------------------------

run "a failed validate job" 1 "validate-gitops did not pass" \
  R_GITOPS=failure
run "workflow_dispatch runs every provider" 0 "lifecycle passed" \
  EVENT_NAME=workflow_dispatch LIFECYCLE_AWS=success LIFECYCLE_CIVO=success

# --- the label step in `changes`, which decides what pr-gate is given -------

yq '.jobs.changes.steps[] | select(.id == "labels") | .run' "$WORKFLOW" > "$TMP/labels.sh"
if [ ! -s "$TMP/labels.sh" ]; then
  echo "pr-gate-test: could not extract the label step from $WORKFLOW" >&2
  exit 1
fi

# labels <name> <expected-output-lines> <labels-json> [DISPATCH=true]
labels() {
  local name="$1" want="$2" json="$3"
  shift 3
  local out rc
  out="$(
    env -i PATH="$PATH" DISPATCH=false LABELS="$json" \
      GITHUB_OUTPUT=/dev/null "$@" bash "$TMP/labels.sh" 2>&1
  )"
  rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "$want" ]; then
    PASS=$((PASS + 1))
    printf 'ok   labels: %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL labels: %s (rc=%s)\n  want:\n%s\n  got:\n%s\n' \
      "$name" "$rc" "$(printf '%s' "$want" | sed 's/^/    /')" \
      "$(printf '%s' "$out" | sed 's/^/    /')"
  fi
}

ALL_OFF='run_aws=false
run_civo=false
run_hetzner=false
run_local=false'
# Every provider that HAS A JOB. hetzner and local stay false unless a label
# names them, because the gate refuses a provider with no job - defaulting to
# them would refuse the commonest case of all.
AVAILABLE_ON='run_aws=true
run_civo=true
run_hetzner=false
run_local=false'
CIVO_ONLY='run_aws=false
run_civo=true
run_hetzner=false
run_local=false'

labels "no labels" "$ALL_OFF" '[]'
labels "a selector alone is inert" "$ALL_OFF" '["ci:aws"]'
labels "two selectors alone are inert" "$ALL_OFF" '["ci:aws","ci:civo"]'
labels "ci:lifecycle alone selects the providers that have jobs" "$AVAILABLE_ON" '["ci:lifecycle"]'
labels "ci:lifecycle + ci:civo selects civo" "$CIVO_ONLY" '["ci:lifecycle","ci:civo"]'
labels "ci:lifecycle + two selectors" "$AVAILABLE_ON" '["ci:lifecycle","ci:aws","ci:civo"]'
# Naming a provider with no job is an explicit request, and stays visible so
# the gate can refuse it. Only the default avoids reaching for these.
labels "ci:lifecycle + ci:hetzner keeps the request visible" 'run_aws=false
run_civo=false
run_hetzner=true
run_local=false' '["ci:lifecycle","ci:hetzner"]'
# Exact string equality, not a substring test: an unrelated label that merely
# contains a provider name must not select that provider.
labels "an unrelated label is not a selector" "$AVAILABLE_ON" '["ci:lifecycle","ci:aws-migration"]'
labels "workflow_dispatch selects the providers that have jobs" "$AVAILABLE_ON" '[]' DISPATCH=true

# --- the two steps composed ------------------------------------------------
#
# The bug this guards against: each step was correct alone, and the pair was
# not. The label step emitted run_hetzner=true for a bare `ci:lifecycle`, the
# gate refuses a selected provider with no job, and the gate's own tests set
# those variables by hand - so both suites passed while the commonest label
# combination failed in CI. Feed one step's real output into the other.

compose() {
  local name="$1" want_rc="$2" want_text="$3" json="$4"
  shift 4
  local env_args=() line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      run_aws=*)     env_args+=("WANTS_AWS=${line#*=}") ;;
      run_civo=*)    env_args+=("WANTS_CIVO=${line#*=}") ;;
      run_hetzner=*) env_args+=("WANTS_HETZNER=${line#*=}") ;;
      run_local=*)   env_args+=("WANTS_LOCAL=${line#*=}") ;;
    esac
  done < <(env -i PATH="$PATH" DISPATCH=false LABELS="$json" \
             GITHUB_OUTPUT=/dev/null bash "$TMP/labels.sh" 2>/dev/null)

  local triggered=false
  if printf '%s' "$json" | jq -e 'any(.[]?; . == "ci:lifecycle")' > /dev/null; then
    triggered=true
  fi
  env_args+=("TRIGGERED=$triggered")

  run "composed: $name" "$want_rc" "$want_text" "${env_args[@]}" "$@"
}

compose "ci:lifecycle alone, both providers pass" 0 "civo: came up" \
  '["ci:lifecycle"]' LIFECYCLE_AWS=success LIFECYCLE_CIVO=success
compose "ci:lifecycle + ci:civo runs civo only" 0 "Not exercised: aws" \
  '["ci:lifecycle","ci:civo"]' LIFECYCLE_CIVO=success
compose "ci:lifecycle + ci:aws runs aws only" 0 "Not exercised: civo" \
  '["ci:lifecycle","ci:aws"]' LIFECYCLE_AWS=success
compose "ci:lifecycle + ci:hetzner is refused" 1 "no hetzner lifecycle job exists" \
  '["ci:lifecycle","ci:hetzner"]'
compose "no label at all" 1 "needs the lifecycle check" '[]'
compose "a selector alone starts nothing" 1 "needs the lifecycle check" '["ci:civo"]'

echo
if [ "$FAIL" -ne 0 ]; then
  echo "pr-gate-test: $FAIL of $((PASS + FAIL)) cases failed"
  exit 1
fi
echo "pr-gate-test: all $PASS cases passed"
