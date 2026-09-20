data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_kms_alias" "secrets" {
  name = "alias/lab-secrets"
}

locals {
  create           = var.ca_cert_pem != ""
  x509_issuer_cn   = coalesce(var.x509_issuer_cn, "${var.project}-${var.provider_name}-workload-ca")
  trust_anchor_arn = try(aws_rolesanywhere_trust_anchor.this[0].arn, "")

  postgres_password_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/postgres/app_password"
  grafana_password_arn  = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/grafana/admin_password"

  # Built as a literal rather than read from the bucket's own state: the
  # bucket lives in the persistent stack, which is applied after this one.
  backups_bucket_arn = "arn:aws:s3:::${var.project}-postgres-backups"

  consumers = local.create ? {
    eso            = data.aws_iam_policy_document.eso.json
    "external-dns" = data.aws_iam_policy_document.external_dns.json
    "cert-manager" = data.aws_iam_policy_document.cert_manager.json
    pgbackup       = data.aws_iam_policy_document.pgbackup.json
  } : {}
}

resource "aws_rolesanywhere_trust_anchor" "this" {
  count = local.create ? 1 : 0

  name    = "${var.project}-${var.provider_name}-workload-ca"
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = var.ca_cert_pem
    }
  }
}

data "aws_iam_policy_document" "trust" {
  for_each = local.consumers

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]

    principals {
      type        = "Service"
      identifiers = ["rolesanywhere.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.trust_anchor_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Subject/CN"
      values   = ["${var.project}-${var.provider_name}-${each.key}"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Issuer/CN"
      values   = [local.x509_issuer_cn]
    }
  }
}

resource "aws_iam_role" "consumer" {
  for_each = local.consumers

  name               = "${var.project}-ra-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.trust[each.key].json
}

resource "aws_iam_role_policy" "consumer" {
  for_each = local.consumers

  name   = "consumer"
  role   = aws_iam_role.consumer[each.key].name
  policy = each.value
}

# No AWS-managed policy exists for ExternalDNS - scoped to the single hosted
# zone it's allowed to touch. ListHostedZones has no resource-level permission
# support in AWS IAM, so it stays "*" - not a scoping gap this module can close.
data "aws_iam_policy_document" "external_dns" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }

  statement {
    actions   = ["route53:ListHostedZones", "route53:GetChange"]
    resources = ["*"]
  }
}

# TXT-only, scoped to the lab zone. No ListHostedZones needed - zone ID
# is provided via SSM parameter, not looked up dynamically.
data "aws_iam_policy_document" "cert_manager" {
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
  }

  statement {
    actions   = ["route53:GetChange"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "eso" {
  statement {
    sid       = "AllowReadPlatformSecretParameters"
    actions   = ["ssm:GetParameter"]
    resources = [local.postgres_password_arn, local.grafana_password_arn]
  }

  # alias/lab-secrets also encrypts other projects' password parameters -
  # SSM sets an EncryptionContext of the parameter's own ARN, so this
  # condition keeps Decrypt scoped to just the two parameters this role can
  # read, not the whole shared key.
  statement {
    sid       = "AllowDecryptPlatformSecretParameters"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.secrets.target_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [local.postgres_password_arn, local.grafana_password_arn]
    }
  }
}

# Scoped to this project's backup bucket only. DeleteObject is what lets the
# backup operator enforce its own retention window; the multipart actions are
# what a base backup larger than a single PutObject needs to complete.
data "aws_iam_policy_document" "pgbackup" {
  statement {
    sid       = "AllowBackupBucketDiscovery"
    actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
    resources = [local.backups_bucket_arn]
  }

  statement {
    sid = "AllowBackupObjectAccess"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${local.backups_bucket_arn}/*"]
  }
}

resource "aws_rolesanywhere_profile" "this" {
  count = local.create ? 1 : 0

  name             = "${var.project}-${var.provider_name}"
  enabled          = true
  role_arns        = [for k, r in aws_iam_role.consumer : r.arn]
  duration_seconds = var.session_duration
}

# Terraform owns AWS, Argo CD owns Kubernetes - these values are read by a
# later Argo-deployed credential-helper sidecar, not by anything in this
# state, so they're handed off via SSM (the same pattern as root_domain/fqdn).
resource "aws_ssm_parameter" "trust_anchor_arn" {
  count = local.create ? 1 : 0

  name  = "/${var.project}/bootstrap/rolesanywhere/trust_anchor_arn"
  type  = "String"
  value = aws_rolesanywhere_trust_anchor.this[0].arn
}

resource "aws_ssm_parameter" "profile_arn" {
  count = local.create ? 1 : 0

  name  = "/${var.project}/bootstrap/rolesanywhere/profile_arn"
  type  = "String"
  value = aws_rolesanywhere_profile.this[0].arn
}

resource "aws_ssm_parameter" "role_arn" {
  for_each = local.consumers

  name  = "/${var.project}/bootstrap/rolesanywhere/role_arn/${each.key}"
  type  = "String"
  value = aws_iam_role.consumer[each.key].arn
}
