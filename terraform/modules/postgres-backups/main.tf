resource "aws_s3_bucket" "this" {
  bucket        = "${var.project}-${var.provider_region}-postgres-backups"
  force_destroy = var.force_destroy
}

# Default SSE-S3 (AES-256); no dedicated KMS key - a physical backup is not a
# credential, and a key would add a must-exist-first ordering dependency.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.this.json
}

data "aws_iam_policy_document" "this" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Backstop only. The in-cluster backup operator prunes on its own recovery
# window; this bounds storage for the periods when no cluster is running.
# Expiring sooner than that window would cut write-ahead log segments out
# from under a base backup that still needs them.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.backstop_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_ssm_parameter" "bucket_name" {
  name        = "/${var.project}/${var.ssm_layer}/backups/bucket_name"
  type        = "String"
  value       = aws_s3_bucket.this.id
  description = "This project's PostgreSQL backup bucket."
}
