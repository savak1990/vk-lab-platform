# shellcheck shell=bash
# State is keyed by region, so changing REGION migrates nothing - it only
# points this project's commands at a different bucket. Callers must have
# sourced region.sh and catalog.sh already.

# A new region means a new bucket while the old platform keeps billing, unseen.
# Candidates come from the catalogue, not a name prefix that could match a longer
# project name; hetzner buckets were once named after a location, so those too.
require_no_other_region_state() {
  local candidates zone candidate_region candidate_lower other_bucket other_count

  candidates="$(catalog_regions "$PROVIDER")"
  if [ "$PROVIDER" = hetzner ]; then
    for zone in $(catalog_regions hetzner); do
      candidates="$candidates $(catalog_zone_locations "$zone")"
    done
  fi
  for candidate_region in $candidates; do
    candidate_lower="$(catalog_lower "$candidate_region")"
    [ "$candidate_lower" = "$LAB_PROVIDER_REGION" ] && continue
    other_bucket="${PROJECT_NAME}-${candidate_lower}-tf-state"
    aws s3api head-bucket --bucket "$other_bucket" --region "$LAB_REGION" >/dev/null 2>&1 || continue

    other_count="$(aws s3api list-objects-v2 --bucket "$other_bucket" --region "$LAB_REGION" \
      --query 'length(Contents)' --output text 2>/dev/null || echo 0)"
    [ "$other_count" = "None" ] && other_count=0
    [ "$other_count" -gt 0 ] || continue

    {
      echo "Refusing: this project already exists in $candidate_region."
      echo "  s3://$other_bucket still holds $other_count object(s)."
      echo "This code cannot see that state: a bring-up would build a second platform,"
      echo "and a teardown would act on the wrong one."
      echo "Destroy the existing one first:"
      if [ "$PROVIDER" = hetzner ] && catalog_zone_of "$candidate_region" >/dev/null; then
        echo "  (a location-named bucket: only main before REGION became a zone can name it)"
        echo "  git worktree add /tmp/platform-318ba5c 318ba5c && cd /tmp/platform-318ba5c"
        echo "  PROVIDER=hetzner REGION=$candidate_region PROJECT_NAME=$PROJECT_NAME CONFIRM_DESTROY=$PROJECT_NAME make full-down"
      else
        echo "  REGION=$candidate_region CONFIRM_DESTROY=$PROJECT_NAME make full-down"
      fi
    } >&2
    return 1
  done
  return 0
}
