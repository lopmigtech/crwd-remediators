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
}
