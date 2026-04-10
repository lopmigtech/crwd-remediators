variables {
  name_prefix            = "test"
  log_destination_bucket = "my-central-logging-bucket"
}

run "plan_resources" {
  command = plan

  assert {
    condition     = length(aws_config_config_rule.this) == 1
    error_message = "Module must create exactly one Config rule"
  }

  assert {
    condition     = aws_config_config_rule.this.source[0].source_identifier == "S3_BUCKET_LOGGING_ENABLED"
    error_message = "Config rule source_identifier must be S3_BUCKET_LOGGING_ENABLED"
  }

  assert {
    condition     = contains(data.aws_iam_policy_document.ssm_assume_role.statement[0].principals[0].identifiers, "ssm.amazonaws.com")
    error_message = "SSM automation role trust policy must allow ssm.amazonaws.com"
  }

  assert {
    condition     = length(aws_config_remediation_configuration.this) == 1
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
    condition     = aws_config_config_rule.this.scope[0].compliance_resource_types[0] == "AWS::S3::Bucket"
    error_message = "Config rule scope must target AWS::S3::Bucket resource type"
  }
}
