################################################################################
# Standard outputs (6 required by all crwd-remediator modules)
################################################################################

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

################################################################################
# Module-specific outputs
################################################################################

output "kms_key_arn" {
  description = "ARN of the KMS key used for DynamoDB encryption (created by module or provided via input)"
  value       = local.effective_kms_key_arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = local.effective_kms_key_id
}

output "phase2_encrypt_command" {
  description = "Pre-built CLI command to manually trigger Phase 2 encryption on a specific table"
  value       = "aws ssm start-automation-execution --document-name ${aws_ssm_document.this.name} --parameters '{\"TableName\":[\"<TABLE_NAME>\"],\"Action\":[\"encrypt\"],\"AutomationAssumeRole\":[\"${aws_iam_role.ssm_automation.arn}\"],\"KmsKeyArn\":[\"${local.effective_kms_key_arn}\"],\"ExcludedResourceIds\":[],\"AssessmentTagKey\":[\"${var.assessment_tag_key}\"]}'"
}
