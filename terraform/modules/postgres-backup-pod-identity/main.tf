module "pod_identity" {
  source = "../pod-identity"

  cluster_name              = var.cluster_name
  role_name                 = "${var.cluster_name}-postgres-backup"
  service_account_name      = var.service_account_name
  service_account_namespace = var.service_account_namespace
}

locals {
  # A literal rather than a dependency: the bucket lives in the persistent
  # stack, which this disposable unit must not reach into.
  bucket_arn = "arn:aws:s3:::${var.project}-postgres-backups"
}

# Scoped to this project's backup bucket only. DeleteObject lets the backup
# plugin enforce its retention window; the multipart actions let a base
# backup larger than a single PutObject complete.
data "aws_iam_policy_document" "backup" {
  statement {
    sid       = "AllowBackupBucketDiscovery"
    actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"]
    resources = [local.bucket_arn]
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
    resources = ["${local.bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "backup" {
  name   = "backup"
  role   = module.pod_identity.role_name
  policy = data.aws_iam_policy_document.backup.json
}
