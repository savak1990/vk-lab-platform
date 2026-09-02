# root_domain is written by the account-level root-domain unit, which
# applies in ACCOUNT_MAIN_REGION - not this unit's own PROJECT_REGION, so
# the lookup must target that region explicitly rather than inherit the
# provider's.
data "aws_ssm_parameter" "root_domain" {
  name   = "/account/root_domain"
  region = var.account_main_region
}

locals {
  root_domain = data.aws_ssm_parameter.root_domain.value
  fqdn        = "${var.subdomain}.${local.root_domain}"
}

resource "aws_route53_zone" "this" {
  name = local.fqdn
}

# Route53 auto-creates an SOA record with the account's default 24h negative-
# cache TTL; this record overrides just that, keeping the other SOA fields
# (they only govern zone-transfer semantics, irrelevant here) at their defaults.
resource "aws_route53_record" "soa" {
  zone_id = aws_route53_zone.this.zone_id
  name    = local.fqdn
  type    = "SOA"
  ttl     = 900
  # AWS auto-creates a default SOA record the instant the zone exists, so this
  # is always an overwrite of an already-existing record, never a fresh create.
  allow_overwrite = true

  records = [
    "${aws_route53_zone.this.name_servers[0]} awsdns-hostmaster.amazon.com. 1 7200 900 1209600 ${var.negative_cache_ttl}"
  ]
}

# Looked up by name rather than an explicit zone ID - the parent zone is
# never created or deleted, only read for its ID and given this one NS
# record delegating the subdomain (constitution §14).
data "aws_route53_zone" "parent" {
  name         = local.root_domain
  private_zone = false
}

resource "aws_route53_record" "delegation" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = local.fqdn
  type    = "NS"
  ttl     = 172800
  records = aws_route53_zone.this.name_servers
}

resource "aws_ssm_parameter" "subdomain" {
  name        = "/${var.project}/bootstrap/route53/subdomain"
  type        = "String"
  value       = var.subdomain
  description = "The subdomain this project delegated from the account's root domain, e.g. \"lab\" in lab.<root-domain>. Read back on later applies so a forgotten SUBDOMAIN re-export can't silently move the zone."
}

# Plain String, same rationale as root_domain (root-domain module): private/
# hygiene data, not a credential, and this also avoids the cross-region
# SecureString/KMS-key coupling when PROJECT_REGION != ACCOUNT_MAIN_REGION.
resource "aws_ssm_parameter" "fqdn" {
  name        = "/${var.project}/bootstrap/route53/fqdn"
  type        = "String"
  value       = local.fqdn
  description = "This project's fully-qualified lab domain."
}
