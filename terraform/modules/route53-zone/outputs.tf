output "zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "name_servers" {
  value = aws_route53_zone.this.name_servers
}

output "root_domain" {
  value     = local.root_domain
  sensitive = true
}

output "fqdn" {
  value     = local.fqdn
  sensitive = true
}
