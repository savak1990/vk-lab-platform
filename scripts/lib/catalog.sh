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
#   civo, USD/month, https://www.civo.com/pricing, 2026-09-22
#     g4s.kube.medium  2 vCPU /  4 GiB  21.73   default
#     g4s.kube.large   4 vCPU /  8 GiB  43.45
#     g4m.kube.small   2 vCPU / 16 GiB  78.21   memory without more cores
#     g4p.kube.small   4 vCPU / 16 GiB  86.91
#   Excluded: xsmall and small are too small to hold the platform - a Medium's
#   measured allocatable is already 2308 MiB. Every g4c starts at 8 vCPU, and
#   every step above g4p.kube.small doubles both dimensions at once.
#   The three entries above the ceiling are here for the same reason the
#   Hetzner ones below are: a CI run is minutes, not a month, and a shape that
#   can hold one more workload is worth more than a monthly figure suggests.
#   Every one of the four is orderable in all four Civo regions, checked
#   against `civo size ls` per region on 2026-09-22.
#
#   hetzner, EUR/month gross, Hetzner API, 2026-09-21
#     cx23   2 vCPU /  4 GiB    7.85
#     cx33   4 vCPU /  8 GiB   12.09   default
#     cx43   8 vCPU / 16 GiB   22.37
#     cx53  16 vCPU / 32 GiB   42.34   over the lab ceiling, see below
#     cpx32  4 vCPU /  8 GiB   50.81   over the lab ceiling, see below
#     cpx42  8 vCPU / 16 GiB   99.21   over the lab ceiling, see below
#   Excluded: cpx52, cpx62 and the whole ccx line, over ceiling with no
#   argument for them. cax* (ARM) are cheap but every real create has
#   failed since 2026-09-19, so listing them would only fail later.
#
# The three over-ceiling Hetzner entries are deliberate, for two reasons
# the monthly price hides.
#
# The Hetzner limit is on server COUNT, per account, not on spend - so when
# the cap binds, fewer-and-bigger is the only shape that fits, and a single
# cx53 or cpx42 beats three cx33 that will not be granted.
#
# And a CI run is minutes, not a month. cpx42 at 99.21/month is about 0.06
# EUR for a 25-minute lifecycle run. The ceiling was reasoned for a lab
# that stays up; it is the wrong metric for a cluster that is destroyed
# before the hour is out.
#
# cpx32 and cpx42 also matter for a reason unrelated to cost: on 2026-09-21
# every cx* type reads unavailable in every eu-central location while the
# cpx*2 generation reads available. That flag has been wrong in both
# directions (HETZ-020), so it is not proof - but the cheap line being
# unorderable for weeks is, and an allowlist with nothing orderable in it
# is worse than an expensive one.
#
# fsn1 stays empty regardless: HETZ-020's real creates found nothing there
# on 2026-09-21, and a flag is not evidence against a failed create.
#
# m6g.large costs 17% more than t4g.large for identical specs and exists
# for one reason: t4g is burstable and throttles to 20% baseline once CPU
# credits run out, while m6g does not. No credit exhaustion has ever been
# recorded here, so it is insurance and never the default. Do not delete
# it as poor value - that is the whole point of it.
#
# The aws list has exactly one entry and always will. That region is fixed
# platform-wide, not merely the only one tried: the shared secrets KMS key,
# lab-role and the OIDC provider all live in it, and REGION is refused on
# this provider rather than matched against the list. The entry stays rather
# than emptying because catalog_default_region, the aws:eu-west-1 node-type
# key and state-up's region-change guard all read it.
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
    civo:LON1 | civo:NYC1 | civo:FRA1 | civo:MUM1) echo "g4s.kube.medium g4s.kube.large g4m.kube.small g4p.kube.small" ;;
    hetzner:nbg1) echo "cx23 cx33 cx43 cx53 cpx32 cpx42" ;;
    hetzner:hel1) echo "cx23 cx33 cpx32 cpx42" ;;
    hetzner:fsn1) echo "cx23 cx33 cx43 cpx32 cpx42" ;;
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
