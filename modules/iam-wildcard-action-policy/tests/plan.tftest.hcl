variables {
  name_prefix = "test"
}

run "plan_resources" {
  command = plan

  assert {
    condition     = length(aws_config_config_rule.this) == 1
    error_message = "Module must create exactly one Config rule"
  }

  assert {
    condition     = aws_config_config_rule.this.source[0].owner == "CUSTOM_LAMBDA"
    error_message = "Config rule source owner must be CUSTOM_LAMBDA"
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
    condition     = contains(data.aws_iam_policy_document.lambda_assume_role.statement[0].principals[0].identifiers, "lambda.amazonaws.com")
    error_message = "Lambda role trust policy must allow lambda.amazonaws.com"
  }

  assert {
    condition     = length(aws_lambda_function.rule_evaluator) == 1
    error_message = "Module must create exactly one Lambda function for Config rule evaluation"
  }
}
