# Guards RECOVER_FROM, the operator input that starts a bring-up from another
# target's backup archive instead of this project's own last generation.
# Offline and credential-free by design: a typo must fail in under a second,
# not after a cluster exists and the copy is attempted.
#
# Failing closed matters more here than in most guards. A recovery handle that
# does not resolve renders initdb, and a bring-up that quietly initialises an
# empty database over a recoverable archive looks healthy until the rows are
# missing.
#
# Not sourced standalone - the caller sets PROVIDER and RECOVER_FROM first,
# then calls require_valid_recover_from.

# Splits s3://<bucket>/<generation> into RECOVER_BUCKET and
# RECOVER_SERVER_NAME. Returns non-zero when the value carries no scheme or
# names no generation; the caller decides how loudly to complain.
recover_from_parse() {
  local raw="${1%/}" rest
  rest="${raw#s3://}"
  [ "$rest" = "$raw" ] && return 1
  RECOVER_BUCKET="${rest%%/*}"
  RECOVER_SERVER_NAME="${rest#*/}"
  [ -n "$RECOVER_BUCKET" ] || return 1
  [ "$RECOVER_SERVER_NAME" != "$RECOVER_BUCKET" ]
}

require_valid_recover_from() {
  local provider="${PROVIDER:-aws}"
  local raw="${RECOVER_FROM:-}"
  local errors=()

  # The ordinary bring-up sets nothing and must cost nothing.
  if [ -z "$raw" ]; then
    return 0
  fi

  if [ "$provider" = "local" ]; then
    echo "Refusing: invalid RECOVER_FROM" >&2
    echo "  - RECOVER_FROM is not an input for PROVIDER 'local'; that target takes no backups" >&2
    exit 1
  fi

  if ! recover_from_parse "$raw"; then
    echo "Refusing: invalid RECOVER_FROM" >&2
    echo "  - RECOVER_FROM '$raw' must look like s3://<bucket>/<generation>" >&2
    exit 1
  fi

  if ! printf '%s' "$RECOVER_BUCKET" | grep -Eq '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'; then
    errors+=("bucket '$RECOVER_BUCKET' is not a valid S3 bucket name")
  fi

  if ! printf '%s' "$RECOVER_SERVER_NAME" | grep -Eq '^lab-postgres-[0-9]{8}T[0-9]{6}Z$'; then
    errors+=("generation '$RECOVER_SERVER_NAME' must look like lab-postgres-20260101T000000Z")
  fi

  # Reported together: an operator who cannot see what they typed should not
  # need a second run to find the second mistake.
  if [ "${#errors[@]}" -gt 0 ]; then
    echo "Refusing: invalid RECOVER_FROM" >&2
    printf '  - %s\n' "${errors[@]}" >&2
    echo "" >&2
    echo "  List a source project's generations with:" >&2
    echo "    aws s3 ls s3://<project>-<region>-postgres-backups/" >&2
    exit 1
  fi
}
