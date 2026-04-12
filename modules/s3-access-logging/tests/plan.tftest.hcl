variables {
  name_prefix            = "test"
  log_destination_bucket = "my-central-logging-bucket"
}

run "plan_resources" {
  command = plan

  assert {
    condition     = aws_config_config_rule.this.name != ""
    error_message = "Module must create exactly one Config rule"
  }

  assert {
    condition     = one(aws_config_config_rule.this.source).source_identifier == "S3_BUCKET_LOGGING_ENABLED"
    error_message = "Config rule source_identifier must be S3_BUCKET_LOGGING_ENABLED"
  }

  assert {
    condition     = contains(one(data.aws_iam_policy_document.ssm_assume_role.statement[0].principals).identifiers, "ssm.amazonaws.com")
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

  assert {
    condition     = aws_ssm_document.this.document_type == "Automation"
    error_message = "SSM document must be of type Automation"
  }

  assert {
    condition     = contains(one(aws_config_config_rule.this.scope).compliance_resource_types, "AWS::S3::Bucket")
    error_message = "Config rule scope must target AWS::S3::Bucket resource type"
  }
}
