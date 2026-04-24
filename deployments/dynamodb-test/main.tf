provider "aws" {
  region = "us-east-1"
}

module "dynamodb_cmk_encryption" {
  source = "../../modules/dynamodb-cmk-encryption"

  name_prefix           = "demo"
  create_kms_key        = true
  automatic_remediation = true

  tags = {
    Environment = "demo"
    Project     = "crwd-remediators-test"
  }
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

output "kms_key_id" {
  value = module.dynamodb_cmk_encryption.kms_key_id
}

output "phase2_encrypt_command" {
  value = module.dynamodb_cmk_encryption.phase2_encrypt_command
}

output "non_compliant_resources_cli_command" {
  value = module.dynamodb_cmk_encryption.non_compliant_resources_cli_command
}

output "config_rule_arn" {
  value = module.dynamodb_cmk_encryption.config_rule_arn
}

output "remediation_configuration_id" {
  value = module.dynamodb_cmk_encryption.remediation_configuration_id
}
