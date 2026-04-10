provider "aws" {
  region = "us-east-1"
}

module "iam_wildcard_action_policy" {
  source = "../../"

  name_prefix              = var.name_prefix
  tags                     = var.tags
  automatic_remediation    = var.automatic_remediation
  excluded_resource_ids    = var.excluded_resource_ids
  cloudtrail_lookback_days = var.cloudtrail_lookback_days
  min_actions_threshold    = var.min_actions_threshold
  report_s3_bucket         = var.report_s3_bucket
}

output "config_rule_name" {
  value = module.iam_wildcard_action_policy.config_rule_name
}

output "ssm_document_name" {
  value = module.iam_wildcard_action_policy.ssm_document_name
}

output "iam_role_arn" {
  value = module.iam_wildcard_action_policy.iam_role_arn
}

output "non_compliant_resources_cli_command" {
  value = module.iam_wildcard_action_policy.non_compliant_resources_cli_command
}
