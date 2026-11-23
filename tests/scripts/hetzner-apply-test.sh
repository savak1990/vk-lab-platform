#!/usr/bin/env bash
# Pins hetzner_apply's location fallback: which errors move on to the next
# location, which stop at once, and which locations are tried at all.
# Needs no credentials - terragrunt is a fake that fails as each case scripts.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo/terraform/live/cluster-hetzner"

# PLAN is a comma list, one outcome per attempt: ok, stock, withdrawn, other.
cat > "$TMP/bin/terragrunt" <<'EOF'
#!/usr/bin/env bash
echo "$HCLOUD_LOCATION" >> "$ATTEMPTS"
n="$(grep -c . "$ATTEMPTS")"
case "$(echo "$PLAN" | cut -d, -f"$n")" in
  ok) exit 0 ;;
  stock) echo "Error: error during placement (resource_unavailable, 0a1b2c)"; exit 1 ;;
  withdrawn) echo "Error: unsupported location for server type (invalid_input, 0a1b2c)"; exit 1 ;;
  *) echo "Error: image not found (invalid_input, 0a1b2c)"; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/terragrunt"

fails=0
run_case() {
  local plan="$1" worker="$2" cp="$3"
  rm -f "$TMP/attempts"
  ( cd "$REPO_ROOT" && PATH="$TMP/bin:$PATH" ATTEMPTS="$TMP/attempts" PLAN="$plan" \
      PROVIDER_SH_REPO_ROOT="$TMP/repo" CLUSTER_DIR=cluster-hetzner REGION=eu-central \
      WORKER_NODE_TYPE="$worker" CONTROL_PLANE_NODE_TYPE="$cp" bash -c '
      set -euo pipefail
      source scripts/lib/catalog.sh
      eval "$(awk "/^hetzner_apply\\(\\) \\{/,/^\\}/" scripts/lib/provider.sh)"
      hetzner_apply' 2>&1 )
}
attempts() { tr '\n' ' ' < "$TMP/attempts" | sed 's/ $//'; }

check() {
  local label="$1" want_rc="$2" want_attempts="$3" got_rc="$4" out="$5" match="${6:-}"
  local got_attempts rc_ok=0
  got_attempts="$(attempts)"
  if [ "$want_rc" = 0 ]; then
    [ "$got_rc" -eq 0 ] && rc_ok=1
  else
    [ "$got_rc" -ne 0 ] && rc_ok=1
  fi
  if [ "$rc_ok" = 1 ] && [ "$got_attempts" = "$want_attempts" ] \
    && { [ -z "$match" ] || printf '%s' "$out" | grep -q "$match"; }; then
    echo "ok   $label"
  else
    echo "FAIL $label: rc=$got_rc attempts='$got_attempts' (want '$want_attempts')"
    echo "$out"
    fails=$((fails + 1))
  fi
}

out="$(run_case ok cx33 cx23)"; check "first location succeeds" 0 "fsn1" $? "$out"
out="$(run_case stock,ok cx43 cx23)"; check "stock-out moves to the next location" 0 "fsn1 nbg1" $? "$out"
out="$(run_case withdrawn,stock,ok cx33 cx23)"; check "a withdrawn type moves on too" 0 "fsn1 nbg1 hel1" $? "$out"
out="$(run_case other cx33 cx23)"; check "any other error stops at once" 1 "fsn1" $? "$out"
out="$(run_case stock,stock cx43 cx23)"; check "every location out of stock fails and says so" 1 "fsn1 nbg1" $? "$out" "try another WORKER_NODE_TYPE"
out="$(run_case ok cx53 cx23)"; check "only locations selling the worker type are tried" 0 "nbg1" $? "$out"
out="$(run_case ok cx33 cx53)"; check "only locations selling the control-plane type are tried" 0 "nbg1" $? "$out"

if [ "$fails" -gt 0 ]; then
  echo "hetzner-apply-test: $fails case(s) failed" >&2
  exit 1
fi
echo "hetzner-apply-test: all 7 cases passed"
