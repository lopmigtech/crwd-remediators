provider "aws" {
  region = "us-east-1"
}

module "iam_wildcard_action_policy" {
  source = "../../"

  name_prefix                 = var.name_prefix
  tags                        = var.tags
  automatic_remediation       = var.automatic_remediation
  remediation_action          = var.remediation_action
  evaluation_frequency        = var.evaluation_frequency
  excluded_resource_ids       = var.excluded_resource_ids
  cloudtrail_lookback_days    = var.cloudtrail_lookback_days
  min_actions_threshold       = var.min_actions_threshold
  report_s3_bucket            = var.report_s3_bucket
  flap_window_days            = var.flap_window_days
  tag_based_exemption_enabled = var.tag_based_exemption_enabled
  exemption_tag_key           = var.exemption_tag_key
  require_exemption_reason    = var.require_exemption_reason
  auto_exempt_on_flap_enabled = var.auto_exempt_on_flap_enabled
  auto_exempt_flap_threshold  = var.auto_exempt_flap_threshold
  auto_exempt_duration_days   = var.auto_exempt_duration_days
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
