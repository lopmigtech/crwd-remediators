variables {
  name_prefix      = "test"
  config_rule_name = "test-iam-wildcard-action-policy"
}

run "plan_resources" {
  command = plan

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
}
