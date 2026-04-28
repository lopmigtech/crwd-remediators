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
