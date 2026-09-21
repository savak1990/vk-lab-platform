# shellcheck shell=bash
# The allowed shapes a cluster may take, per provider and per region.
#
# This is a COST GUARDRAIL, not a mirror of each cloud's catalogue. Entries
# are few and deliberate: widening one is a reviewed code change. Ceilings
# are per provider because the clouds are not comparable - EUR 25 buys a
# real range on Hetzner, while on AWS nothing under USD 27 has over 4 GiB.
#
# Keyed by (provider, region), never two independent lists: node-type
# availability varies by region, so flat lists would accept combinations
# that cannot be created. cx43 is orderable in nbg1 but not hel1.
#
# Prices, with their source and date, so the ceiling stays auditable:
#
#   aws, USD/month on-demand, eu-west-1, AWS Pricing API, 2026-09-21
#     t4g.medium   2 vCPU /  4 GiB   26.86   default
#     t4g.large    2 vCPU /  8 GiB   53.73   the memory upgrade
#     m6g.large    2 vCPU /  8 GiB   62.78   the non-burstable option
#   Excluded: t4g.small - not price but pod density. 17 pods fit a
#   t4g.medium (3 ENIs x 6 IPs); fewer ENIs cannot hold this platform.
#   m6g/m7g/m8g medium are all 1 vCPU and dearer per GiB than t4g.medium.
#
#   civo, USD/month, civo/research.md:29, recorded 2026-09-07
#     g4s.kube.medium  2 vCPU / 4 GiB  21.73   default
#   Excluded: g4s.kube.large 43.45 over ceiling; xsmall/small too small to
#   hold the platform - a Medium's measured allocatable is already 2308 MiB.
#
#   hetzner, EUR/month gross, Hetzner API, 2026-09-21
#     cx23   2 vCPU /  4 GiB    7.85
#     cx33   4 vCPU /  8 GiB   12.09   default
#     cx43   8 vCPU / 16 GiB   22.37
#   Excluded: cx53 42.34 and the ccx/cpx lines over ceiling.
#
# m6g.large costs 17% more than t4g.large for identical specs and exists
# for one reason: t4g is burstable and throttles to 20% baseline once CPU
# credits run out, while m6g does not. No credit exhaustion has ever been
# recorded here, so it is insurance and never the default. Do not delete
# it as poor value - that is the whole point of it.
#
# Region lists carry their own constraints. Hetzner is limited to the
# eu-central network zone because the private network HETZ-025 creates is
# eu-central, and a server outside that zone cannot attach to it. Hetzner
# region/type availability is HETZ-020's real creates on 2026-09-21
# (hetzner/research.md:144), not Hetzner's published catalogue, which
# proved unreliable in both directions. Civo regions are `civo region ls`,
# 2026-09-21, spelled uppercase to match CIVO_REGION in region.sh.
#
# Spellings differ between clouds - Civo answers lon1 from its own CLI but
# the platform has always passed LON1, while Hetzner and AWS are lowercase.
# Operator input is therefore matched case-insensitively and canonicalised
# back to the spelling below, which is what reaches a CLI and Terraform.

catalog_regions() {
  case "$1" in
    aws) echo "eu-west-1" ;;
    civo) echo "LON1 NYC1 FRA1 MUM1" ;;
    hetzner) echo "nbg1 hel1 fsn1" ;;
    *) echo "" ;;
  esac
}

# Empty for a region that exists but has nothing orderable, which is a
# different answer from an unknown region and is reported differently.
catalog_node_types() {
  case "$1:$2" in
    aws:eu-west-1) echo "t4g.medium t4g.large m6g.large" ;;
    civo:LON1 | civo:NYC1 | civo:FRA1 | civo:MUM1) echo "g4s.kube.medium" ;;
    hetzner:nbg1) echo "cx23 cx33 cx43" ;;
    hetzner:hel1) echo "cx23 cx33" ;;
    hetzner:fsn1) echo "" ;;
    *) echo "" ;;
  esac
}

catalog_default_region() {
  case "$1" in
    aws) echo "eu-west-1" ;;
    civo) echo "LON1" ;;
    hetzner) echo "nbg1" ;;
    *) echo "" ;;
  esac
}

catalog_default_node_type() {
  case "$1" in
    aws) echo "t4g.medium" ;;
    civo) echo "g4s.kube.medium" ;;
    hetzner) echo "cx33" ;;
    *) echo "" ;;
  esac
}

# aws is 1 because Karpenter supplies workload capacity on top of the
# system node group; civo and hetzner pay for every node they run.
catalog_default_node_count() {
  case "$1" in
    aws) echo "1" ;;
    civo) echo "3" ;;
    hetzner) echo "3" ;;
    *) echo "" ;;
  esac
}

# True for a provider that owns cloud resources at all. local runs one kind
# cluster on this machine and takes none of the three inputs.
catalog_takes_node_inputs() {
  case "$1" in
    aws | civo | hetzner) return 0 ;;
    *) return 1 ;;
  esac
}

catalog_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Operator input is matched case-insensitively, but what comes back is the
# provider's own spelling - Civo wants LON1, Hetzner wants nbg1, and the
# value is passed on to a CLI and to Terraform. Empty means no match.
catalog_canonical_region() {
  local provider="$1" want candidate
  want="$(catalog_lower "$2")"
  for candidate in $(catalog_regions "$provider"); do
    if [ "$(catalog_lower "$candidate")" = "$want" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

catalog_canonical_node_type() {
  local provider="$1" region="$2" want candidate
  want="$(catalog_lower "$3")"
  for candidate in $(catalog_node_types "$provider" "$region"); do
    if [ "$(catalog_lower "$candidate")" = "$want" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}
