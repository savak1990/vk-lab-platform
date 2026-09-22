#!/usr/bin/env bash
# Pins argo-up's provider dispatch: every `case "$PROVIDER"` must name every
# supported provider, so a target can never reach a `*)` arm and exit 1 in the
# middle of a bring-up. That is exactly how hetzner failed in four places
# before HETZ-045, and the failure only ever showed up against a live cluster.
#
# Needs no credentials and no cluster - it reads the script, it never runs it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/argo-up.sh"
PROVIDERS="aws civo hetzner local"
fails=0

# A block may legitimately omit an arm when an enclosing guard already excluded
# that provider - the fast-path switch sits inside `[ "$PROVIDER" != local ]`.
# Parsed from the guard itself rather than pinned to a line number, so moving
# the block does not silently turn the exception into a blind spot.

# Walks the file once, collecting the arm labels of each `case "$PROVIDER" in`
# block. Nested case statements would break this; there are none, and a new one
# would show up as a missing arm rather than as a silent pass.
check_block() {
  local label="$1" arms="$2" excluded="$3" p
  for p in $PROVIDERS; do
    if printf '%s' "$arms" | grep -qw "$p"; then continue; fi
    if printf '%s' "$excluded" | grep -qw "$p"; then
      echo "ok: $label has no $p arm - an enclosing guard excludes $p"
      continue
    fi
    echo "FAIL: $label has no '$p)' arm - PROVIDER=$p would hit its \`*)\` and exit 1"
    fails=$((fails + 1))
  done
}

blocks=0
in_case=0
arms=""
excluded=""
start_line=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  if [ "$in_case" = 0 ]; then
    # Collected between blocks: a guard like `[ "$PROVIDER" != local ]` means
    # the next block never sees that provider.
    # Single-quoted on purpose: this matches the literal text "$PROVIDER" in
    # the script being read, so nothing here should expand.
    # shellcheck disable=SC2016
    case "$line" in
      *'"$PROVIDER" != '*)
        guarded="${line#*\"\$PROVIDER\" != }"
        excluded="$excluded ${guarded%% *}"
        ;;
    esac
    # shellcheck disable=SC2016
    case "$line" in
      *'case "$PROVIDER" in'*) in_case=1; arms=""; start_line=$lineno ;;
    esac
    continue
  fi
  case "$line" in
    *esac*)
      blocks=$((blocks + 1))
      check_block "the case at line $start_line" "$arms" "$excluded"
      in_case=0
      excluded=""
      ;;
    *')'*)
      # An arm label, e.g. `  civo)` or `  civo|hetzner)`. Anything with a
      # leading `$` or a space before the paren is a command, not a label.
      trimmed="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
      case "$trimmed" in
        [a-z]*')'*) arms="$arms ${trimmed%%)*}" ;;
      esac
      ;;
  esac
done < "$SCRIPT"

if [ "$blocks" -eq 0 ]; then
  echo "FAIL: found no 'case \"\$PROVIDER\"' block in $SCRIPT - has it been renamed?"
  fails=$((fails + 1))
fi

echo "checked $blocks provider dispatch block(s)"
[ "$fails" -eq 0 ] || {
  echo "$fails missing arm(s)"
  exit 1
}
echo "all provider dispatch cases name every supported provider"
