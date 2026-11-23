#!/usr/bin/env bash
# Pins state-up's region-change guard for hetzner: a bucket named after a
# location, from before REGION became the zone, must still block a second
# platform. Needs no credentials - aws and terragrunt are fakes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo/scripts/lib" "$TMP/repo/terraform/live/state"
cp "$REPO_ROOT/scripts/state-up.sh" "$TMP/repo/scripts/"
cp "$REPO_ROOT"/scripts/lib/*.sh "$TMP/repo/scripts/lib/"
touch "$TMP/repo/terraform/live/state/terragrunt.hcl"
CALLS="$TMP/calls"
export CALLS

# LEGACY: full - the fsn1 bucket holds objects; empty - it exists but is empty;
# absent - it does not exist. The zone bucket always exists.
cat > "$TMP/bin/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
bucket=""
prev=""
for a in "$@"; do
  [ "$prev" = "--bucket" ] && bucket="$a"
  prev="$a"
done
case "$1 $2" in
  "sts get-caller-identity") echo '{}' ;;
  "s3api head-bucket")
    case "$bucket" in
      vk-fake-hz-eu-central-tf-state) exit 0 ;;
      vk-fake-hz-fsn1-tf-state) [ "$LEGACY" != absent ] && exit 0 ;;
    esac
    echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2
    exit 254 ;;
  "s3api list-objects-v2")
    if [ "$bucket" = vk-fake-hz-fsn1-tf-state ] && [ "$LEGACY" = full ]; then echo 3; else echo None; fi ;;
  *) echo "fake aws: unexpected $*" >&2; exit 2 ;;
esac
FAKE_AWS
cat > "$TMP/bin/terragrunt" <<'FAKE_TG'
#!/usr/bin/env bash
echo "terragrunt $*" >> "$CALLS"
FAKE_TG
chmod +x "$TMP/bin/aws" "$TMP/bin/terragrunt"

fails=0
run_case() {
  rm -f "$CALLS"
  ( cd "$TMP/repo" && PATH="$TMP/bin:/usr/bin:/bin" LEGACY="$1" CALLS="$CALLS" \
      PROVIDER=hetzner PROJECT_NAME=vk-fake-hz REGION=eu-central AWS_PROFILE=fake \
      ./scripts/state-up.sh 2>&1 )
}

out="$(run_case full)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "s3://vk-fake-hz-fsn1-tf-state" \
  && printf '%s' "$out" | grep -q "318ba5c" && [ ! -s "$CALLS" ]; then
  echo "ok   a location-named bucket with objects refuses, names the old checkout, applies nothing"
else
  echo "FAIL legacy bucket with objects: rc=$rc"; echo "$out"; fails=$((fails + 1))
fi

for mode in empty absent; do
  out="$(run_case "$mode")"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q "terragrunt apply" "$CALLS"; then
    echo "ok   legacy bucket $mode: the guard lets state-up apply"
  else
    echo "FAIL legacy bucket $mode: rc=$rc"; echo "$out"; fails=$((fails + 1))
  fi
done

# Calls the function directly, as argo-down.sh/cluster-down.sh do on hetzner,
# rather than through the whole of state-up.sh.
run_guard_directly() {
  ( cd "$TMP/repo" && PATH="$TMP/bin:/usr/bin:/bin" LEGACY="$1" \
      PROVIDER=hetzner PROJECT_NAME=vk-fake-hz REGION=eu-central AWS_PROFILE=fake bash -c '
      set -euo pipefail
      source scripts/lib/region.sh
      source scripts/lib/catalog.sh
      source scripts/lib/region-guard.sh
      require_no_other_region_state' 2>&1 )
}

out="$(run_guard_directly full)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "s3://vk-fake-hz-fsn1-tf-state"; then
  echo "ok   require_no_other_region_state called directly refuses on a full legacy bucket"
else
  echo "FAIL require_no_other_region_state direct call, full: rc=$rc"; echo "$out"; fails=$((fails + 1))
fi

out="$(run_guard_directly absent)"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "ok   require_no_other_region_state called directly returns 0 with no legacy bucket"
else
  echo "FAIL require_no_other_region_state direct call, absent: rc=$rc"; echo "$out"; fails=$((fails + 1))
fi

if [ "$fails" -gt 0 ]; then
  echo "state-up-guard-test: $fails case(s) failed" >&2
  exit 1
fi
echo "state-up-guard-test: all 5 cases passed"
