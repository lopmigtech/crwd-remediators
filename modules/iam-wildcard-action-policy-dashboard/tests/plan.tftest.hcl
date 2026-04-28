variables {
  name_prefix      = "test"
  config_rule_name = "test-iam-wildcard-action-policy"
}

run "plan_resources" {
  command = apply

  assert {
    condition     = aws_s3_bucket.dashboard.bucket != ""
    error_message = "Module must create exactly one S3 bucket for the dashboard"
  }

  assert {
    condition = (
      aws_s3_bucket_public_access_block.dashboard.block_public_acls &&
      aws_s3_bucket_public_access_block.dashboard.block_public_policy &&
      aws_s3_bucket_public_access_block.dashboard.ignore_public_acls &&
      aws_s3_bucket_public_access_block.dashboard.restrict_public_buckets
    )
    error_message = "All four Block Public Access flags must be enabled on the dashboard bucket"
  }

  assert {
    condition     = try(one(aws_s3_bucket_server_side_encryption_configuration.dashboard.rule).apply_server_side_encryption_by_default[0].sse_algorithm, null) == "AES256"
    error_message = "S3 bucket must have SSE-S3 (AES256) default encryption"
  }

  assert {
    condition     = aws_s3_bucket_versioning.dashboard.versioning_configuration[0].status == "Enabled"
    error_message = "S3 bucket versioning must be enabled"
  }

  assert {
    condition     = length(regexall("aws:SecureTransport", data.aws_iam_policy_document.dashboard_bucket.json)) > 0
    error_message = "Bucket policy must include a Deny statement on aws:SecureTransport=false"
  }

  assert {
    condition     = length(aws_s3_bucket_logging.dashboard) == (var.access_log_bucket == null ? 0 : 1)
    error_message = "Server-access logging must be configured if access_log_bucket is set, and absent otherwise"
  }
}
