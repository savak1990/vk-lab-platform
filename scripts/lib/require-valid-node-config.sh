# Guards NODE_COUNT, NODE_TYPE, CONTROL_PLANE_NODE_TYPE and REGION before
# anything reaches a cloud.
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
  printf '  %-8s: %s (fixed - not an input)\n' aws "$(catalog_regions aws)"
  local p
  for p in civo hetzner; do
    printf '  %-8s: %s\n' "$p" "$(catalog_regions "$p")"
  done
}

require_valid_node_config() {
  local provider="${PROVIDER:-aws}"
  local region="${REGION:-}" node_type="${NODE_TYPE:-}" node_count="${NODE_COUNT:-}"
  local cp_node_type="${CONTROL_PLANE_NODE_TYPE:-}"
  local errors=()

  # Ignored rather than refused: these are commonly left exported in a shell
  # while switching targets, and local owns no cloud resources for them to
  # describe. region.sh discards them the same way.
  if ! catalog_takes_node_inputs "$provider"; then
    return 0
  fi

  region="${region:-$(catalog_default_region "$provider")}"
  node_count="${node_count:-$(catalog_default_node_count "$provider")}"

  local canonical_region=""
  # Fixed rather than merely unlisted: the shared secrets key, lab-role and
  # the OIDC provider all live in it, so a project elsewhere fails deep in an
  # apply instead of here. Resolved anyway, so NODE_TYPE is still checked.
  if [ "$provider" = "aws" ]; then
    canonical_region="$(catalog_default_region aws)"
    if [ -n "${REGION:-}" ] && [ "$(catalog_lower "$REGION")" != "$canonical_region" ]; then
      errors+=("REGION is not an input for PROVIDER=aws; the AWS region is fixed at $canonical_region. REGION selects a region only on civo and hetzner")
    fi
  elif ! canonical_region="$(catalog_canonical_region "$provider" "$region")"; then
    errors+=("REGION '$region' is not valid for PROVIDER '$provider'")
  fi

  if [ -n "$canonical_region" ]; then
    local allowed
    allowed="$(catalog_node_types "$provider" "$canonical_region")"
    node_type="${node_type:-$(catalog_default_node_type "$provider" "$canonical_region")}"
    if [ -z "$allowed" ]; then
      errors+=("REGION '$canonical_region' has no node type this platform will order; see scripts/lib/catalog.sh")
    elif ! catalog_canonical_node_type "$provider" "$canonical_region" "$node_type" >/dev/null; then
      errors+=("NODE_TYPE '$node_type' is not allowed in '$canonical_region'; there: $allowed")
    fi
  elif [ -n "$node_type" ]; then
    errors+=("NODE_TYPE '$node_type' was not checked, because REGION is invalid")
  fi

  # The only control plane the platform creates and pays for is hetzner's, so
  # elsewhere a value is refused rather than ignored - nothing would read it.
  if [ "$provider" = "hetzner" ]; then
    if [ -n "$canonical_region" ]; then
      local cp_allowed
      cp_allowed="$(catalog_node_types "$provider" "$canonical_region")"
      cp_node_type="${cp_node_type:-$(catalog_default_control_plane_node_type "$provider")}"
      if [ -n "$cp_allowed" ] && ! catalog_canonical_node_type "$provider" "$canonical_region" "$cp_node_type" >/dev/null; then
        errors+=("CONTROL_PLANE_NODE_TYPE '$cp_node_type' is not allowed in '$canonical_region'; there: $cp_allowed")
      fi
    fi
  elif [ -n "$cp_node_type" ]; then
    errors+=("CONTROL_PLANE_NODE_TYPE is not an input for PROVIDER=$provider; only hetzner creates a control plane this platform sizes")
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
