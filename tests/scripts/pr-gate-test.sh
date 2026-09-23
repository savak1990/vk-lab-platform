#!/usr/bin/env bash
# Exercises pr-gate's decision step (.github/workflows/lifecycle-test.yml)
# against label and job-result combinations, by extracting its `run:` block and
# running it with the same environment Actions would give it.
#
# WANTS_<cloud> is what the `changes` job's label step emits: one
# `ci:lifecycle-<cloud>` label, one output. There is no separate trigger.
# KIND_INTEGRATION is a result, never a request - that job is not selectable.
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
      LIFECYCLE_AWS=skipped LIFECYCLE_CIVO=skipped LIFECYCLE_HETZNER=skipped \
      KIND_INTEGRATION=success \
      EVENT_NAME=pull_request \
      HEAD_REPO=owner/repo GITHUB_REPOSITORY=owner/repo \
      WANTS_SKIP=false WANTS_AWS=false WANTS_CIVO=false WANTS_HETZNER=false \
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

# --- kind, which is mandatory and not selectable ----------------------------

# The whole point of the change: no label, and the platform still came up.
run "kind must pass even with no label" 1 "one cloud must run" \
  KIND_INTEGRATION=success
run "a failed kind run blocks the merge" 1 "kind-integration did not pass" \
  KIND_INTEGRATION=failure WANTS_CIVO=true LIFECYCLE_CIVO=success
# Skipping is allowed for exactly one reason, and must be stated.
run "kind skipped on a docs-only change" 0 "kind-integration: skipped" \
  KIND_INTEGRATION=skipped DOCS_ONLY=true INFRA=false \
  R_TERRAFORM=skipped R_GITOPS=skipped R_YAML=skipped R_ACTIONS=skipped
run "kind skipped on an infrastructure change" 1 "it must run" \
  KIND_INTEGRATION=skipped

# --- nothing asked for ------------------------------------------------------

run "no label on an infrastructure change" 1 "one cloud must run"
run "no label, no infrastructure change" 0 "no cloud run is required" \
  INFRA=false

# --- one label per cloud ----------------------------------------------------

run "ci:lifecycle-civo runs civo only" 0 "Not exercised: aws" \
  WANTS_CIVO=true LIFECYCLE_CIVO=success
run "ci:lifecycle-civo, civo fails" 1 "the civo lifecycle did not pass" \
  WANTS_CIVO=true LIFECYCLE_CIVO=failure
run "ci:lifecycle-aws runs aws only" 0 "Not exercised: civo" \
  WANTS_AWS=true LIFECYCLE_AWS=success
run "both cloud labels" 0 "aws: came up" \
  WANTS_AWS=true WANTS_CIVO=true LIFECYCLE_AWS=success LIFECYCLE_CIVO=success
run "both labels, one fails" 1 "the aws lifecycle did not pass" \
  WANTS_AWS=true WANTS_CIVO=true LIFECYCLE_AWS=failure LIFECYCLE_CIVO=success
# The case result-inference could not tell apart from an unlabelled pull
# request: both report skipped, and only one of them may merge.
run "a requested cloud whose job did not run" 1 "the aws lifecycle did not pass" \
  WANTS_AWS=true
# A requested cloud is judged whether or not the change is infrastructure:
# a failed run nobody asked to ignore is worse than one nobody asked for.
run "a cloud label on a non-infrastructure change, it fails" 1 "the civo lifecycle did not pass" \
  INFRA=false WANTS_CIVO=true LIFECYCLE_CIVO=failure

run "ci:lifecycle-hetzner runs hetzner" 0 "hetzner: came up" \
  WANTS_HETZNER=true LIFECYCLE_HETZNER=success
run "a failed hetzner lifecycle blocks the merge" 1 "the hetzner lifecycle did not pass" \
  WANTS_HETZNER=true LIFECYCLE_HETZNER=failure
# Asked for and never run is a hole, not a pass - the same rule as the others.
run "hetzner wanted but skipped" 1 "the hetzner lifecycle did not pass" \
  WANTS_HETZNER=true LIFECYCLE_HETZNER=skipped

# --- the waiver -------------------------------------------------------------

run "a cloud label and the skip label" 1 "opposite things" \
  WANTS_CIVO=true WANTS_SKIP=true
run "skip label alone waives the cloud half" 0 "WAIVED" \
  WANTS_SKIP=true
# The waiver covers clouds only. kind is free, so nothing excuses it.
run "the skip label does not waive kind" 1 "kind-integration did not pass" \
  WANTS_SKIP=true KIND_INTEGRATION=failure

# --- everything else --------------------------------------------------------

run "a failed validate job" 1 "validate-gitops did not pass" \
  R_GITOPS=failure
run "workflow_dispatch runs every cloud" 0 "lifecycle passed" \
  EVENT_NAME=workflow_dispatch LIFECYCLE_AWS=success LIFECYCLE_CIVO=success \
  LIFECYCLE_HETZNER=success
# One cloud short is still short, even on a dispatch.
run "workflow_dispatch, hetzner fails" 1 "lifecycle did not pass" \
  EVENT_NAME=workflow_dispatch LIFECYCLE_AWS=success LIFECYCLE_CIVO=success \
  LIFECYCLE_HETZNER=failure
# kind is judged before the dispatch branch, so it reports its own failure.
run "workflow_dispatch, kind fails" 1 "kind-integration did not pass" \
  EVENT_NAME=workflow_dispatch LIFECYCLE_AWS=success LIFECYCLE_CIVO=success \
  LIFECYCLE_HETZNER=success KIND_INTEGRATION=failure

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
run_hetzner=false'
CIVO_ONLY='run_aws=false
run_civo=true
run_hetzner=false'
BOTH_CLOUDS='run_aws=true
run_civo=true
run_hetzner=false'
EVERY_CLOUD='run_aws=true
run_civo=true
run_hetzner=true'

labels "no labels" "$ALL_OFF" '[]'
labels "ci:lifecycle-civo selects civo" "$CIVO_ONLY" '["ci:lifecycle-civo"]'
labels "both cloud labels select both" "$BOTH_CLOUDS" '["ci:lifecycle-aws","ci:lifecycle-civo"]'
# The old bare trigger is gone. It must select nothing rather than everything.
labels "the old ci:lifecycle selects nothing" "$ALL_OFF" '["ci:lifecycle"]'
# The old selector names are gone too.
labels "the old ci:civo selects nothing" "$ALL_OFF" '["ci:civo"]'
labels "ci:lifecycle-hetzner selects hetzner" 'run_aws=false
run_civo=false
run_hetzner=true' '["ci:lifecycle-hetzner"]'
# Exact string equality, not a substring test: an unrelated label that merely
# contains a cloud name must not select that cloud.
labels "an unrelated label is not a label" "$ALL_OFF" '["ci:lifecycle-aws-migration"]'
# Every cloud now has a job, so a dispatch reaches for all three.
labels "workflow_dispatch selects every cloud" "$EVERY_CLOUD" '[]' DISPATCH=true

# --- the two steps composed ------------------------------------------------
#
# The bug this guards against: each step was correct alone, and the pair was
# not. The label step emitted a request for a cloud with no job, the gate
# refuses one, and the gate's own tests set those variables by hand - so both
# suites passed while the commonest label combination failed in CI. Feed one
# step's real output into the other.

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
    esac
  done < <(env -i PATH="$PATH" DISPATCH=false LABELS="$json" \
             GITHUB_OUTPUT=/dev/null bash "$TMP/labels.sh" 2>/dev/null)

  local skip=false
  if printf '%s' "$json" | jq -e 'any(.[]?; . == "ci:skip-lifecycle")' > /dev/null; then
    skip=true
  fi
  env_args+=("WANTS_SKIP=$skip")

  run "composed: $name" "$want_rc" "$want_text" "${env_args[@]}" "$@"
}

compose "ci:lifecycle-civo runs civo only" 0 "Not exercised: aws" \
  '["ci:lifecycle-civo"]' LIFECYCLE_CIVO=success
compose "ci:lifecycle-aws runs aws only" 0 "Not exercised: civo" \
  '["ci:lifecycle-aws"]' LIFECYCLE_AWS=success
compose "both cloud labels" 0 "aws: came up" \
  '["ci:lifecycle-aws","ci:lifecycle-civo"]' LIFECYCLE_AWS=success LIFECYCLE_CIVO=success
compose "ci:lifecycle-hetzner runs hetzner only" 0 "Not exercised: aws civo" \
  '["ci:lifecycle-hetzner"]' LIFECYCLE_HETZNER=success
compose "no label at all" 1 "one cloud must run" '[]'
compose "the old bare ci:lifecycle no longer starts anything" 1 "one cloud must run" \
  '["ci:lifecycle"]'
compose "the skip label waives the cloud half" 0 "WAIVED" '["ci:skip-lifecycle"]'

echo
if [ "$FAIL" -ne 0 ]; then
  echo "pr-gate-test: $FAIL of $((PASS + FAIL)) cases failed"
  exit 1
fi
echo "pr-gate-test: all $PASS cases passed"
