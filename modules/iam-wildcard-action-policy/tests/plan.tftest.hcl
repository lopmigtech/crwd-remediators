variables {
  name_prefix = "test"
}

run "plan_resources" {
  command = plan

  assert {
    condition     = aws_config_config_rule.this.name != ""
    error_message = "Module must create exactly one Config rule"
  }

  assert {
    condition     = one(aws_config_config_rule.this.source).owner == "CUSTOM_LAMBDA"
    error_message = "Config rule source owner must be CUSTOM_LAMBDA"
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
    condition     = contains(one(data.aws_iam_policy_document.lambda_assume_role.statement[0].principals).identifiers, "lambda.amazonaws.com")
    error_message = "Lambda role trust policy must allow lambda.amazonaws.com"
  }

  assert {
    condition     = aws_lambda_function.rule_evaluator.function_name != ""
    error_message = "Module must create exactly one Lambda function for Config rule evaluation"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "Action"][0] == "analyze"
    error_message = "Action parameter must default to 'analyze' (dry-run-safe)"
  }

  assert {
    condition     = length([for p in aws_config_remediation_configuration.this.parameter : p if p.name == "FlapWindowDays"]) == 1
    error_message = "Remediation config must pass FlapWindowDays parameter to SSM document"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "FlapWindowDays"][0] == "7"
    error_message = "Default flap_window_days must be 7"
  }
}

run "invalid_remediation_action_rejected" {
  command = plan

  variables {
    name_prefix        = "test"
    remediation_action = "delete-everything"
  }

  expect_failures = [
    var.remediation_action,
  ]
}

run "scheduled_notification_enabled_by_default" {
  command = plan

  variables {
    name_prefix = "test"
  }

  assert {
    condition     = length([for sd in aws_config_config_rule.this.source[0].source_detail : sd if sd.message_type == "ScheduledNotification"]) == 1
    error_message = "Config rule must have exactly one ScheduledNotification source_detail when evaluation_frequency != 'Off'"
  }

  assert {
    condition     = [for sd in aws_config_config_rule.this.source[0].source_detail : sd.maximum_execution_frequency if sd.message_type == "ScheduledNotification"][0] == "TwentyFour_Hours"
    error_message = "Default evaluation_frequency must be TwentyFour_Hours"
  }
}

run "scheduled_notification_disabled_when_off" {
  command = plan

  variables {
    name_prefix          = "test"
    evaluation_frequency = "Off"
  }

  assert {
    condition     = length([for sd in aws_config_config_rule.this.source[0].source_detail : sd if sd.message_type == "ScheduledNotification"]) == 0
    error_message = "Config rule must not have a ScheduledNotification source_detail when evaluation_frequency = 'Off'"
  }
}
