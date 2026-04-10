variables {
  name_prefix            = "test"
  log_destination_bucket = "test-access-logs-bucket"
}

run "plan_resources" {
  command = plan

  assert {
    condition     = aws_config_config_rule.this.name != ""
    error_message = "Module must create exactly one Config rule"
  }

  assert {
    condition     = aws_config_config_rule.this.source[0].source_identifier == "S3_BUCKET_LOGGING_ENABLED"
    error_message = "Config rule source_identifier must be S3_BUCKET_LOGGING_ENABLED"
  }

  assert {
    condition     = anytrue([for p in data.aws_iam_policy_document.ssm_assume_role.statement[0].principals : contains(p.identifiers, "ssm.amazonaws.com")])
    error_message = "SSM automation role trust policy must allow ssm.amazonaws.com"
  }

  assert {
    condition     = aws_config_remediation_configuration.this.config_rule_name != ""
    error_message = "Module must create exactly one remediation configuration"
  }

  assert {
    condition     = aws_config_remediation_configuration.this.automatic == false
    error_message = "automatic_remediation must default to false (dry-run)"
  }
}
