data "aws_kms_secrets" "this" {
  secret {
    name    = "postgres_app_password"
    payload = filebase64(var.postgres_app_password_secret_path)
  }
  secret {
    name    = "grafana_admin_password"
    payload = filebase64(var.grafana_admin_password_secret_path)
  }
}

resource "aws_ssm_parameter" "postgres_app_password" {
  name        = "/${var.project}/persistent/postgres/app_password"
  value       = data.aws_kms_secrets.this.plaintext["postgres_app_password"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Postgres app-user (vkdb) password. Never regenerated once set (ADR 0014) - must stay byte-identical across a CNPG snapshot recovery."
}

resource "aws_ssm_parameter" "grafana_admin_password" {
  name        = "/${var.project}/persistent/grafana/admin_password"
  value       = data.aws_kms_secrets.this.plaintext["grafana_admin_password"]
  type        = "SecureString"
  key_id      = "alias/lab-secrets"
  description = "Grafana admin password."
}

# A one-way bcrypt hash, never encrypted before or after this - it isn't a
# reversible credential, so a plain String parameter (not SecureString) is
# the right fit, same reasoning as fqdn/root_domain elsewhere in this plan.
resource "aws_ssm_parameter" "argocd_admin_password_bcrypt" {
  name        = "/${var.project}/persistent/argocd/admin_password_bcrypt"
  value       = trimspace(file(var.argocd_admin_password_bcrypt_path))
  type        = "String"
  description = "Bcrypt hash of the Argo CD admin password, injected by scripts/argo-up.sh before Argo CD (and External Secrets Operator) exist - ADR 0012."
}
