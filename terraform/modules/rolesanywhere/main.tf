data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_kms_alias" "secrets" {
  name = "alias/lab-secrets"
}

locals {
  create           = var.ca_cert_pem != ""
  x509_issuer_cn   = coalesce(var.x509_issuer_cn, "${var.project}-civo-workload-ca")
  trust_anchor_arn = try(aws_rolesanywhere_trust_anchor.this[0].arn, "")

  postgres_password_arn = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/postgres/app_password"
  grafana_password_arn  = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project}/persistent/grafana/admin_password"

  consumers = local.create ? {
    eso            = data.aws_iam_policy_document.eso.json
    "external-dns" = data.aws_iam_policy_document.external_dns.json
    "cert-manager" = data.aws_iam_policy_document.cert_manager.json
  } : {}
}

resource "aws_rolesanywhere_trust_anchor" "this" {
  count = local.create ? 1 : 0

  name    = "${var.project}-civo-workload-ca"
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
      values   = ["${var.project}-civo-${each.key}"]
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

# TXT-only, scoped to the Civo zone - cert-manager's DNS-01 solver never
# needs to touch the A records ExternalDNS owns, so the change permission
# is restricted by record type, not just by zone. No ListHostedZones*: the
# zone ID reaches this workload as a value (see route53-zone's zone_id SSM
# parameter), it never has to look the zone up.
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

resource "aws_rolesanywhere_profile" "this" {
  count = local.create ? 1 : 0

  name             = "${var.project}-civo"
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
