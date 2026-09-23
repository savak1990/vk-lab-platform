#!/usr/bin/env bash
# Exercises clusters.sh's civo and hetzner arms against fake CLIs on PATH, with
# no credentials and no cloud. The case that matters is the first: a provider
# whose CLI is missing must say so, because a bill-safety command that stays
# silent reads as "nothing is running" - the one answer that costs money.
# Usage: tests/scripts/clusters-test.sh
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/civobin" "$TMP/real"

# A controlled PATH, so "civo is not installed" can be tested at all: the
# operator's real civo would otherwise be found whatever is put in $TMP/bin.
# jq and kubectl are symlinked rather than faked - the script's parsing is
# what is under test, not jq's.
for tool in jq kubectl; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] && ln -sf "$real" "$TMP/real/$tool"
done
BASE_PATH="$TMP/bin:$TMP/real:/usr/bin:/bin"

# The fake aws reports an empty account, so the aws arm is a no-op and any
# failure can only come from the two arms under test.
cat > "$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "eks list-clusters") echo "None" ;;
  *) echo "fake aws: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/aws"

# Three servers in one project, one of them off: the group must collapse to a
# single row whose STATUS is "mixed" and whose NODES is 3. AGE comes from the
# oldest .created, which is the control plane's.
cat > "$TMP/bin/hcloud" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "server list" ]; then
  case "${FAKE_HCLOUD_MODE:-servers}" in
    empty) echo "[]" ;;
    servers) cat <<'JSON'
[
 {"name":"vk-fake-lab-cp-1","status":"running","created":"2026-09-23T10:00:00+00:00",
  "datacenter":{"location":{"name":"fsn1"}},
  "labels":{"scope":"platform","project":"vk-fake-lab","role":"control-plane"}},
 {"name":"vk-fake-lab-worker-1","status":"running","created":"2026-09-23T10:05:00+00:00",
  "datacenter":{"location":{"name":"fsn1"}},
  "labels":{"scope":"platform","project":"vk-fake-lab","role":"worker"}},
 {"name":"vk-fake-lab-worker-2","status":"off","created":"2026-09-23T10:06:00+00:00",
  "datacenter":{"location":{"name":"fsn1"}},
  "labels":{"scope":"platform","project":"vk-fake-lab","role":"worker"}},
 {"name":"somebody-elses-box","status":"running","created":"2026-09-23T09:00:00+00:00",
  "datacenter":{"location":{"name":"fsn1"}},
  "labels":{"role":"unrelated"}}
]
JSON
      ;;
  esac
  exit 0
fi
echo "fake hcloud: unexpected $*" >&2
exit 2
EOF
chmod +x "$TMP/bin/hcloud"

# One cluster, deliberately with no created_at: the Civo CLI's documented
# field list does not include it, so the row must still appear with AGE "-".
# Only LON1 answers, so a region loop that stops early is visible too.
cat > "$TMP/civobin/civo" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "kubernetes ls" ]; then
  region=""
  while [ $# -gt 0 ]; do
    [ "$1" = "--region" ] && region="$2"
    shift
  done
  if [ "$region" = "LON1" ]; then
    echo '[{"name":"vk-fake-civo","status":"ACTIVE","num_target_nodes":3}]'
  else
    echo "No resources found in region $region. For a list of regions use the command 'civo region ls'"
  fi
  exit 0
fi
exit 1
EOF
chmod +x "$TMP/civobin/civo"

# The real one reaches KMS. The tokens are never used against a real API here.
cat > "$TMP/bin/secret-decrypt.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake-token"
EOF
chmod +x "$TMP/bin/secret-decrypt.sh"

fail=0
err() { echo "CLUSTERS-TEST: $*" >&2; fail=1; }

# The real script, run from a copy whose secret-decrypt.sh is the stub above.
WORK="$TMP/repo"
mkdir -p "$WORK/scripts/lib"
cp "$REPO_ROOT/scripts/clusters.sh" "$WORK/scripts/"
cp "$REPO_ROOT"/scripts/lib/*.sh "$WORK/scripts/lib/"
cp "$TMP/bin/secret-decrypt.sh" "$WORK/scripts/secret-decrypt.sh"

# PROVIDER and PROJECT_NAME are exported by the Makefile into every recipe, so
# the hostile case is the realistic one: they must not steer the sweep.
run_case() {
  ( cd "$WORK" && PATH="$1" FAKE_HCLOUD_MODE="$2" \
      PROVIDER=hetzner PROJECT_NAME=vk-hetzner-lab REGION=fsn1 \
      AWS_PROFILE=fake ./scripts/clusters.sh 2>&1 )
}

# 1 and 3. civo missing from PATH, three hetzner servers in one project.
out="$(run_case "$BASE_PATH" servers)"; rc=$?
[ "$rc" -eq 0 ] || err "civo absent: expected rc=0, got $rc: $out"
case "$out" in
  *"(civo: CLI not installed - skipped)"*) ;;
  *) err "civo absent: expected the skip notice, got: $out" ;;
esac

hz="$(echo "$out" | awk '$1 == "vk-fake-lab" { print; exit }')"
if [ -z "$hz" ]; then
  err "hetzner grouping: no row for vk-fake-lab in: $out"
else
  [ "$(echo "$out" | awk '$1 == "vk-fake-lab"' | wc -l | tr -d ' ')" = "1" ] \
    || err "hetzner grouping: three servers must collapse to one row, got: $hz"
  [ "$(echo "$hz" | awk '{print $3}')" = "mixed" ] \
    || err "hetzner grouping: one server is off, so STATUS must be mixed: $hz"
  [ "$(echo "$hz" | awk '{print $4}')" = "3" ] \
    || err "hetzner grouping: NODES must count all three servers: $hz"
fi

# An unlabelled server in the same account is somebody else's and must not
# become a row - scope=platform is the only thing that makes it ours.
case "$out" in
  *somebody-elses-box*) err "hetzner grouping: listed a server with no scope=platform label: $out" ;;
esac

# 2. A civo cluster with no created_at still gets a row, with AGE "-".
out="$(run_case "$TMP/civobin:$BASE_PATH" empty)"; rc=$?
[ "$rc" -eq 0 ] || err "civo present: expected rc=0, got $rc: $out"
cv="$(echo "$out" | awk '$1 == "vk-fake-civo" { print; exit }')"
if [ -z "$cv" ]; then
  err "civo listing: no row for vk-fake-civo in: $out"
else
  [ "$(echo "$cv" | awk '{print $5}')" = "-" ] \
    || err "civo listing: created_at is absent, so AGE must be '-': $cv"
  [ "$(echo "$cv" | awk '{print $4}')" = "3" ] \
    || err "civo listing: NODES must come from num_target_nodes: $cv"
  case "$cv" in
    *LON1*) ;;
    *) err "civo listing: the row must name the region it was found in: $cv" ;;
  esac
fi

if [ "$fail" -eq 0 ]; then
  echo "CLUSTERS-TEST: ok - a missing CLI is reported, hetzner servers group by project, civo ages degrade."
fi
exit "$fail"
