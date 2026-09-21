# Guards NODE_COUNT, NODE_TYPE and REGION before anything reaches a cloud.
# Offline and credential-free by design: the point is to fail on a typo in
# under a second, not twenty minutes into an apply. Whether a type is in
# stock right now is a different question, answered by HETZ-175's probe.
#
# Lives here rather than in a workflow so a local `REGION=x make up` hits
# the identical check CI does.
#
# Not sourced standalone - the caller sets PROVIDER and the three inputs
# first, then calls require_valid_node_config.

REQUIRE_NODE_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=catalog.sh
source "$REQUIRE_NODE_CONFIG_DIR/catalog.sh"

# Providers are listed with their regions so an operator who aimed one
# cloud's region at another can see where it actually belongs.
node_config_legal_regions() {
  local p
  for p in aws civo hetzner; do
    printf '  %-8s: %s\n' "$p" "$(catalog_regions "$p")"
  done
}

require_valid_node_config() {
  local provider="${PROVIDER:-aws}"
  local region="${REGION:-}" node_type="${NODE_TYPE:-}" node_count="${NODE_COUNT:-}"
  local errors=()

  if ! catalog_takes_node_inputs "$provider"; then
    local set_vars=()
    [ -n "$region" ] && set_vars+=("REGION")
    [ -n "$node_type" ] && set_vars+=("NODE_TYPE")
    [ -n "$node_count" ] && set_vars+=("NODE_COUNT")
    if [ "${#set_vars[@]}" -gt 0 ]; then
      echo "Refusing: PROVIDER=$provider owns no cloud resources and accepts none of these: ${set_vars[*]}" >&2
      exit 1
    fi
    return 0
  fi

  region="${region:-$(catalog_default_region "$provider")}"
  node_count="${node_count:-$(catalog_default_node_count "$provider")}"

  local canonical_region=""
  if ! canonical_region="$(catalog_canonical_region "$provider" "$region")"; then
    errors+=("REGION '$region' is not valid for PROVIDER '$provider'")
  fi

  if [ -n "$canonical_region" ]; then
    local allowed
    allowed="$(catalog_node_types "$provider" "$canonical_region")"
    node_type="${node_type:-$(catalog_default_node_type "$provider")}"
    if [ -z "$allowed" ]; then
      errors+=("REGION '$canonical_region' has no node type this platform will order; see scripts/lib/catalog.sh")
    elif ! catalog_canonical_node_type "$provider" "$canonical_region" "$node_type" >/dev/null; then
      errors+=("NODE_TYPE '$node_type' is not allowed in '$canonical_region'; there: $allowed")
    fi
  elif [ -n "$node_type" ]; then
    errors+=("NODE_TYPE '$node_type' was not checked, because REGION is invalid")
  fi

  if ! printf '%s' "$node_count" | grep -Eq '^[1-9][0-9]*$'; then
    errors+=("NODE_COUNT '$node_count' must be a positive integer")
  fi

  # Reported together: an operator who cannot see what they typed should
  # not need a second run to find the second mistake.
  if [ "${#errors[@]}" -gt 0 ]; then
    echo "Refusing: invalid node configuration for PROVIDER=$provider" >&2
    printf '  - %s\n' "${errors[@]}" >&2
    echo "" >&2
    node_config_legal_regions >&2
    exit 1
  fi
}
