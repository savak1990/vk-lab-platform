#!/usr/bin/env bash
# Covers the RECOVER_FROM guard: the shapes it accepts, the shapes it refuses,
# and the two variables a accepted value parses into. Reaches no cloud API.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# shellcheck source=scripts/lib/require-valid-recover-from.sh
. scripts/lib/require-valid-recover-from.sh

fail=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*" >&2; fail=1; }

GOOD="s3://vk-hetzner-lab-fsn1-postgres-backups/lab-postgres-20260101T000000Z"

# require_valid_recover_from exits on a bad value, so it runs in a subshell.
# recover_from_parse sets variables, so it must not.
refuses() {
  local provider="$1" value="$2"
  ( PROVIDER="$provider" RECOVER_FROM="$value" require_valid_recover_from ) >/dev/null 2>&1
  [ $? -ne 0 ]
}

accepts() {
  local provider="$1" value="$2"
  ( PROVIDER="$provider" RECOVER_FROM="$value" require_valid_recover_from ) >/dev/null 2>&1
}

# An unset RECOVER_FROM is the ordinary case and must cost nothing.
if accepts hetzner ""; then ok "empty: accepted"; else bad "empty: refused"; fi

if accepts civo "$GOOD"; then ok "well-formed: accepted"; else bad "well-formed: refused"; fi
if accepts civo "$GOOD/"; then ok "trailing slash: accepted"; else bad "trailing slash: refused"; fi

# local takes no backups at all, so the variable is meaningless there.
if refuses local "$GOOD"; then ok "local: refused"; else bad "local: accepted"; fi
if accepts local ""; then ok "local with empty value: accepted"; else bad "local with empty value: refused"; fi

if refuses civo "vk-hetzner-lab-fsn1-postgres-backups/lab-postgres-20260101T000000Z"; then
  ok "no scheme: refused"
else
  bad "no scheme: accepted"
fi
if refuses civo "s3://vk-hetzner-lab-fsn1-postgres-backups"; then
  ok "no generation: refused"
else
  bad "no generation: accepted"
fi
if refuses civo "s3://vk-hetzner-lab-fsn1-postgres-backups/nonsense"; then
  ok "wrong generation shape: refused"
else
  bad "wrong generation shape: accepted"
fi
if refuses civo "s3://Not_A_Bucket/lab-postgres-20260101T000000Z"; then
  ok "invalid bucket name: refused"
else
  bad "invalid bucket name: accepted"
fi
if refuses civo "s3:///lab-postgres-20260101T000000Z"; then
  ok "empty bucket: refused"
else
  bad "empty bucket: accepted"
fi

# The parse is what argo-up.sh consumes, so its outputs are asserted directly.
RECOVER_BUCKET=""
RECOVER_SERVER_NAME=""
if recover_from_parse "$GOOD"; then
  [ "$RECOVER_BUCKET" = "vk-hetzner-lab-fsn1-postgres-backups" ] \
    && ok "parse: bucket" || bad "parse: bucket was '$RECOVER_BUCKET'"
  [ "$RECOVER_SERVER_NAME" = "lab-postgres-20260101T000000Z" ] \
    && ok "parse: generation" || bad "parse: generation was '$RECOVER_SERVER_NAME'"
else
  bad "parse: refused a well-formed value"
fi

RECOVER_BUCKET=""
RECOVER_SERVER_NAME=""
if recover_from_parse "$GOOD/"; then
  [ "$RECOVER_SERVER_NAME" = "lab-postgres-20260101T000000Z" ] \
    && ok "parse: trailing slash stripped" || bad "parse: trailing slash left '$RECOVER_SERVER_NAME'"
else
  bad "parse: refused a trailing slash"
fi

if [ "$fail" -eq 0 ]; then
  echo "recover-from-test: ok"
else
  echo "recover-from-test: FAILED" >&2
fi
exit "$fail"
