data "aws_kms_secrets" "domain" {
  secret {
    name    = "root_domain"
    payload = filebase64(var.root_domain_secret_path)
  }
}

locals {
  root_domain = data.aws_kms_secrets.domain.plaintext["root_domain"]
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
