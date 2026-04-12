variables {
  name_prefix    = "test"
  create_kms_key = true
}

run "plan_resources" {
  command = plan

  assert {
    condition     = aws_config_config_rule.this.name != ""
    error_message = "Module must create exactly one Config rule"
  }

  assert {
    condition     = one(aws_config_config_rule.this.source).source_identifier == "DYNAMODB_TABLE_ENCRYPTED_KMS"
    error_message = "Config rule source_identifier must be DYNAMODB_TABLE_ENCRYPTED_KMS"
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
    condition     = aws_ssm_document.this.name != ""
    error_message = "Tier 1 module must create exactly one SSM document"
  }

  assert {
    condition     = aws_kms_key.dynamodb[0].description != ""
    error_message = "Module must create a KMS key when create_kms_key is true"
  }
}
