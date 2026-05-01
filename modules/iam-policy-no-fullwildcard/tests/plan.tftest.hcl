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
    condition     = one(aws_config_config_rule.this.source).owner == "AWS"
    error_message = "Config rule source owner must be AWS (managed rule per Rule 10)"
  }

  assert {
    condition     = one(aws_config_config_rule.this.source).source_identifier == "IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS"
    error_message = "Config rule must wrap the AWS-managed IAM_POLICY_NO_STATEMENTS_WITH_FULL_ACCESS rule"
  }

  assert {
    condition     = contains(one(aws_config_config_rule.this.scope).compliance_resource_types, "AWS::IAM::Policy")
    error_message = "Config rule scope must include AWS::IAM::Policy"
  }

  assert {
    condition     = contains(one(data.aws_iam_policy_document.ssm_assume_role.statement[0].principals).identifiers, "ssm.amazonaws.com")
    error_message = "SSM automation role trust policy must allow ssm.amazonaws.com"
  }

  assert {
    condition     = aws_config_remediation_configuration.this.automatic == false
    error_message = "automatic_remediation must default to false (dry-run, per Rule 8)"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "Action"][0] == "tag-and-route"
    error_message = "Action parameter must default to 'tag-and-route'"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "TagBasedExemptionEnabled"][0] == "true"
    error_message = "tag_based_exemption_enabled must default to true"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "ExemptionTagKey"][0] == "CrwdRemediatorExempt"
    error_message = "exemption_tag_key must default to CrwdRemediatorExempt"
  }

  assert {
    condition     = [for p in aws_config_remediation_configuration.this.parameter : p.static_value if p.name == "RequireExemptionReason"][0] == "true"
    error_message = "require_exemption_reason must default to true"
  }
}

run "invalid_remediation_action_rejected" {
  command = plan

  variables {
    name_prefix        = "test"
    remediation_action = "auto-scope"
  }

  expect_failures = [
    var.remediation_action,
  ]
}
