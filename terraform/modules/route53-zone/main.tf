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
