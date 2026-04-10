output "config_rule_arn" {
  description = "ARN of the Config rule"
  value       = aws_config_config_rule.this.arn
}

output "config_rule_name" {
  description = "Name of the Config rule"
  value       = aws_config_config_rule.this.name
}

output "ssm_document_name" {
  description = "Name of the SSM Automation document used for remediation"
  value       = aws_ssm_document.this.name
}

output "remediation_configuration_id" {
  description = "ID of the Config remediation configuration"
  value       = aws_config_remediation_configuration.this.id
}

output "iam_role_arn" {
  description = "ARN of the SSM automation IAM role"
  value       = aws_iam_role.ssm_automation.arn
}

output "non_compliant_resources_cli_command" {
  description = "Copy-pasteable AWS CLI command to list resources currently flagged as non-compliant by this module's Config rule"
  value       = "aws configservice get-compliance-details-by-config-rule --config-rule-name ${aws_config_config_rule.this.name} --compliance-types NON_COMPLIANT --query 'EvaluationResults[].EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId' --output text"
}

output "lambda_function_arn" {
  description = "ARN of the Lambda function used for Config rule evaluation"
  value       = aws_lambda_function.rule_evaluator.arn
}

output "lambda_role_arn" {
  description = "ARN of the IAM role used by the Lambda Config rule evaluator"
  value       = aws_iam_role.lambda_config_rule.arn
}
