variables {
  name_prefix    = "test"
  create_kms_key = true
}

run "plan_resources" {
  command = plan

  assert {
    condition     = length(aws_config_config_rule.this) == 1
    error_message = "Module must create exactly one Config rule"
  }

  assert {
    condition     = aws_config_config_rule.this.source[0].source_identifier == "DYNAMODB_TABLE_ENCRYPTED_KMS"
    error_message = "Config rule source_identifier must be DYNAMODB_TABLE_ENCRYPTED_KMS"
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
    condition     = length(aws_ssm_document.this) == 1
    error_message = "Tier 1 module must create exactly one SSM document"
  }

  assert {
    condition     = length(aws_kms_key.dynamodb) == 1
    error_message = "Module must create a KMS key when create_kms_key is true"
  }
}
