data "aws_kms_secrets" "this" {
  dynamic "secret" {
    for_each = var.secrets
    content {
      name    = secret.key
      payload = filebase64(secret.value)
    }
  }
}

resource "aws_secretsmanager_secret" "this" {
  name                    = var.name
  recovery_window_in_days = 0
}

# All entries in var.secrets are bundled into one Secrets Manager secret as
# a JSON object, one key per entry - AWS Secrets Manager bills per secret
# (~$0.40/month each), not per key, so this holds every runtime secret this
# platform has instead of paying for one secret per value.
resource "aws_secretsmanager_secret_version" "this" {
  secret_id     = aws_secretsmanager_secret.this.id
  secret_string = jsonencode(data.aws_kms_secrets.this.plaintext)
}
