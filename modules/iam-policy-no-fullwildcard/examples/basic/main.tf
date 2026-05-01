provider "aws" {
  region = "us-east-1"
}

module "iam_policy_no_fullwildcard" {
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
}

output "config_rule_name" {
  value = module.iam_policy_no_fullwildcard.config_rule_name
}

output "ssm_document_name" {
  value = module.iam_policy_no_fullwildcard.ssm_document_name
}

output "iam_role_arn" {
  value = module.iam_policy_no_fullwildcard.iam_role_arn
}

output "non_compliant_resources_cli_command" {
  value = module.iam_policy_no_fullwildcard.non_compliant_resources_cli_command
}
