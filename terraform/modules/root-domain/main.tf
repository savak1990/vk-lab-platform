data "aws_kms_secrets" "domain" {
  secret {
    name    = "root_domain"
    payload = filebase64(var.root_domain_secret_path)
  }
}

locals {
  root_domain = data.aws_kms_secrets.domain.plaintext["root_domain"]
}

# The existence check: this data source fails the apply if the root domain
# isn't a reachable Route53 hosted zone with these credentials - no custom
# validation logic needed, and it now fails at account-up instead of much
# later inside a project's own bootstrap/route53 apply.
data "aws_route53_zone" "root" {
  name         = local.root_domain
  private_zone = false
}

# SecureString, not String: treated as sensitive at the storage layer even
# though it's also derivable from public DNS once a project's zone is
# delegated (the NS records for lab.<root-domain> name the parent).
resource "aws_ssm_parameter" "root_domain" {
  name        = "/account/root_domain"
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  value       = local.root_domain
  description = "Account-global root domain every project's lab subdomain delegates from."
}

resource "aws_ssm_parameter" "main_account_region" {
  name        = "/account/main_account_region"
  type        = "String"
  value       = var.main_account_region
  description = "Account-global region the account lifecycle (kms/lab-role/root-domain) applies in."
}
