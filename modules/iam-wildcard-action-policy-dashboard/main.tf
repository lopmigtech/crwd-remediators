locals {
  resource_prefix = "${var.name_prefix}-iam-wildcard-dashboard"
  bucket_name     = "${local.resource_prefix}-${data.aws_caller_identity.current.account_id}"
}

# -----------------------------------------------------------------------------
# S3 bucket — hosts the rendered dashboard.html. Private, encrypted, versioned.
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "dashboard" {
  bucket        = local.bucket_name
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}
