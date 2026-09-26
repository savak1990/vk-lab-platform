#!/usr/bin/env bash
# Cross-checks help.sh against the real Makefile: every name it prints must be
# a target that exists, and every documented target must appear exactly once.
# That one pair of assertions catches all three ways the parser can break - a
# doc block attached to the wrong target, a block dropped because an ifeq line
# separated it from its target, and a name printed twice because each ifeq
# branch repeats it. Needs no credentials and no cloud.
# Usage: tests/scripts/help-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail=0
err() { echo "HELP-TEST: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

./scripts/help.sh > "$TMP/listing" 2>"$TMP/err" \
  || err "help.sh exited non-zero: $(cat "$TMP/err")"

# Strip the SGR sequences the listing uses for the group headings and names.
sed -E 's/\x1b\[[0-9;]*m//g' "$TMP/listing" \
  | awk '/^  [a-z]/ { print $1 }' | sort > "$TMP/printed"

# Every target defined in the Makefile, ifeq branches collapsed.
grep -E '^[a-zA-Z0-9][a-zA-Z0-9_.-]*:' Makefile \
  | sed -E 's/:.*//' | sort -u > "$TMP/defined"

missing="$(comm -23 "$TMP/printed" "$TMP/defined" | tr '\n' ' ')"
[ -z "${missing// /}" ] || err "help prints names that are not targets: $missing"

dupes="$(uniq -d < "$TMP/printed" | tr '\n' ' ')"
[ -z "${dupes// /}" ] || err "help prints a target more than once: $dupes"

# Every documented target must be listed. A doc block that lost its target is
# invisible otherwise, which is how clear-cache's block came to sit above
# require-valid-project-name and print under the wrong name.
awk '
  /^### / { next }
  /^## /  { n++; next }
  /^[a-zA-Z0-9][a-zA-Z0-9_.-]*:/ { if (n) { split($0, f, ":"); print f[1] } n = 0; next }
' Makefile | sort -u > "$TMP/documented"
undocumented="$(comm -13 "$TMP/printed" "$TMP/documented" | tr '\n' ' ')"
[ -z "${undocumented// /}" ] || err "documented targets help never prints: $undocumented"

# The listing's first line must be a group heading, so a target can never be
# printed before the group it belongs to.
first="$(sed -E 's/\x1b\[[0-9;]*m//g' "$TMP/listing" | sed -n '1p')"
case "$first" in
  "  "*) err "the listing starts with a target, not a group heading: $first" ;;
esac

# One target in full: the whole block, not just its first line.
out="$(./scripts/help.sh clear-cache 2>&1)"
echo "$out" | grep -q "terragrunt-cache" \
  || err "help.sh clear-cache does not describe clear-cache: $out"
[ "$(echo "$out" | wc -l | tr -d ' ')" -ge 3 ] \
  || err "help.sh clear-cache printed only the first line: $out"

# The regression that motivated the test: one target's block must never be
# printed under another target's name.
out="$(./scripts/help.sh require-valid-project-name 2>&1)"
if echo "$out" | grep -q "terragrunt-cache"; then
  err "require-valid-project-name carries clear-cache's documentation: $out"
fi

# Redirected output must carry no escape sequence: a listing kept in a file or
# a CI log is read as text, not repainted by a terminal.
if LC_ALL=C grep -q $'\033' "$TMP/listing"; then
  err "the listing is not a terminal, so it must carry no escape sequence"
fi

# An unknown name must fail loudly rather than print an empty listing.
if ./scripts/help.sh no-such-target >"$TMP/out" 2>"$TMP/err"; then
  err "an unknown target must exit non-zero"
fi
grep -q "no documented target" "$TMP/err" \
  || err "an unknown target must say so on stderr: $(cat "$TMP/err")"

if [ "$fail" -eq 0 ]; then
  echo "HELP-TEST: ok - $(wc -l < "$TMP/printed" | tr -d ' ') targets listed, each one real, each one once, and every documented target reached."
fi
exit "$fail"
