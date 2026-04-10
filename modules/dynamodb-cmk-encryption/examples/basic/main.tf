provider "aws" {}

module "dynamodb_cmk_encryption" {
  source = "../../"

  name_prefix           = var.name_prefix
  tags                  = var.tags
  automatic_remediation = var.automatic_remediation
  excluded_resource_ids = var.excluded_resource_ids
  create_kms_key        = var.create_kms_key
  kms_key_arn           = var.kms_key_arn
  assessment_tag_key    = var.assessment_tag_key
  sns_topic_arn         = var.sns_topic_arn
}

output "config_rule_name" {
  value = module.dynamodb_cmk_encryption.config_rule_name
}

output "ssm_document_name" {
  value = module.dynamodb_cmk_encryption.ssm_document_name
}

output "iam_role_arn" {
  value = module.dynamodb_cmk_encryption.iam_role_arn
}

output "kms_key_arn" {
  value = module.dynamodb_cmk_encryption.kms_key_arn
}

output "phase2_encrypt_command" {
  value = module.dynamodb_cmk_encryption.phase2_encrypt_command
}

output "non_compliant_resources_cli_command" {
  value = module.dynamodb_cmk_encryption.non_compliant_resources_cli_command
}
