provider "aws" {
  region = "us-east-1"
}

module "iam_overpermissive_inline_policy" {
  source = "../../"

  name_prefix                 = var.name_prefix
  tags                        = var.tags
  automatic_remediation       = var.automatic_remediation
  remediation_action          = var.remediation_action
  evaluation_frequency        = var.evaluation_frequency
  excluded_resource_ids       = var.excluded_resource_ids
  tag_based_exemption_enabled = var.tag_based_exemption_enabled
  exemption_tag_key           = var.exemption_tag_key
  require_exemption_reason    = var.require_exemption_reason
  enable_role_remediation     = var.enable_role_remediation
  enable_user_remediation     = var.enable_user_remediation
  enable_group_remediation    = var.enable_group_remediation
}

output "config_rule_name" {
  value = module.iam_overpermissive_inline_policy.config_rule_name
}

output "ssm_document_name" {
  value = module.iam_overpermissive_inline_policy.ssm_document_name
}

output "iam_role_arn" {
  value = module.iam_overpermissive_inline_policy.iam_role_arn
}

output "non_compliant_resources_cli_command" {
  value = module.iam_overpermissive_inline_policy.non_compliant_resources_cli_command
}
