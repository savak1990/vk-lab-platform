resource "aws_acm_certificate" "this" {
  domain_name               = var.fqdn
  subject_alternative_names = ["*.${var.fqdn}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# The apex and wildcard SAN share one validation CNAME, so exactly one
# record is needed - a single static resource, not for_each. On a fresh
# certificate, domain_validation_options' resource_record_name isn't known
# until apply, so a for_each keyed by it fails ("keys derived from
# resource attributes that cannot be determined until apply"); indexing
# into element 0 of the set has no such restriction.
locals {
  validation = tolist(aws_acm_certificate.this.domain_validation_options)[0]
}

resource "aws_route53_record" "validation" {
  zone_id = var.zone_id
  name    = local.validation.resource_record_name
  type    = local.validation.resource_record_type
  records = [local.validation.resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]

  timeouts {
    create = "10m"
  }
}

resource "aws_ssm_parameter" "certificate_arn" {
  name        = "/${var.project}/bootstrap/acm/certificate_arn"
  type        = "String"
  value       = aws_acm_certificate_validation.this.certificate_arn
  description = "This project's ACM certificate ARN for the lab domain."
}
