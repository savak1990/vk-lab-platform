#!/usr/bin/env bash
# Exercises verify-no-leaks.sh's S3 check against a fake `aws` on PATH, with
# no credentials and no cloud. The case that matters is the third: deleting a
# bucket is eventually consistent, so head-bucket can answer for a moment
# after bootstrap-down removed it, and a single check reads that as a leak.
# Usage: tests/scripts/verify-no-leaks-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

# The fake aws answers every call verify-no-leaks.sh makes. Only head-bucket
# varies per case; everything else reports a clean teardown, so a failure can
# only come from the bucket logic under test.
cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "s3api head-bucket")
    case "$HEAD_BUCKET_MODE" in
      absent) exit 1 ;;
      present) exit 0 ;;
      # Answers HEAD_BUCKET_ECHOES times, then reports the bucket gone.
      settling)
        n=0
        [ -f "$HEAD_BUCKET_COUNTER" ] && n="$(cat "$HEAD_BUCKET_COUNTER")"
        n=$((n + 1))
        echo "$n" > "$HEAD_BUCKET_COUNTER"
        [ "$n" -le "$HEAD_BUCKET_ECHOES" ] && exit 0
        exit 1 ;;
    esac ;;
  "route53 list-hosted-zones-by-name") echo "None" ;;
  "ssm describe-parameters") echo "None" ;;
  "eks describe-cluster") exit 1 ;;
  *) echo "fake aws: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/aws"

# The real one reaches KMS; the script only needs a root domain to build a
# hosted-zone name the fake route53 then reports absent.
cat > "$TMP/bin/secret-decrypt.sh" <<'EOF'
#!/usr/bin/env bash
echo "example.invalid"
EOF
chmod +x "$TMP/bin/secret-decrypt.sh"

export PATH="$TMP/bin:$PATH"
export AWS_PROFILE=fake
export HEAD_BUCKET_COUNTER="$TMP/state/count"
export HEAD_BUCKET_ECHOES=1

fail=0
err() { echo "VERIFY-NO-LEAKS-TEST: $*" >&2; fail=1; }

# Run the real script from a copy of the repo whose secret-decrypt.sh is the
# stub above, so nothing reaches KMS.
run_case() {
  local mode="$1" settle="$2"
  rm -f "$HEAD_BUCKET_COUNTER"
  ( cd "$WORK" \
    && HEAD_BUCKET_MODE="$mode" LEAK_BUCKET_SETTLE_SECONDS="$settle" \
       ./scripts/verify-no-leaks.sh aws 2>&1 )
}

WORK="$TMP/repo"
mkdir -p "$WORK/scripts/lib"
cp "$REPO_ROOT/scripts/verify-no-leaks.sh" "$WORK/scripts/"
cp "$REPO_ROOT"/scripts/lib/*.sh "$WORK/scripts/lib/"
cp "$TMP/bin/secret-decrypt.sh" "$WORK/scripts/secret-decrypt.sh"

# 1. A bucket that is already gone: clean, and it must not wait for it.
start="$(date +%s)"
out="$(run_case absent 60)"; rc=$?
elapsed=$(( $(date +%s) - start ))
[ "$rc" -eq 0 ] || err "absent bucket: expected rc=0, got $rc: $out"
[ "$elapsed" -lt 5 ] || err "absent bucket: waited ${elapsed}s; a clean teardown must not pay the settle window"

# 2. A bucket that never goes away is a real leak, and is still reported.
out="$(run_case present 1)"; rc=$?
[ "$rc" -eq 1 ] || err "present bucket: expected rc=1, got $rc: $out"
case "$out" in
  *"still exists"*) ;;
  *) err "present bucket: expected a leak message, got: $out" ;;
esac

# 3. The regression: a bucket that answers once and is then gone. Before the
#    settle window this exited 1 and failed the lifecycle run.
out="$(run_case settling 60)"; rc=$?
[ "$rc" -eq 0 ] || err "settling bucket: expected rc=0, got $rc: $out"
case "$out" in
  *"waiting for the delete to settle"*) ;;
  *) err "settling bucket: expected the settle notice, got: $out" ;;
esac

if [ "$fail" -eq 0 ]; then
  echo "VERIFY-NO-LEAKS-TEST: ok - absent, leaked and settling buckets all read correctly."
fi
exit "$fail"
