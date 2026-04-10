terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {}

module "s3_access_logging" {
  source = "../../"

  name_prefix            = var.name_prefix
  log_destination_bucket = var.log_destination_bucket
  log_destination_prefix = var.log_destination_prefix
  automatic_remediation  = var.automatic_remediation
  excluded_resource_ids  = var.excluded_resource_ids
}

output "config_rule_arn" {
  description = "ARN of the Config rule created by this example"
  value       = module.s3_access_logging.config_rule_arn
}

output "config_rule_name" {
  description = "Name of the Config rule created by this example"
  value       = module.s3_access_logging.config_rule_name
}

output "ssm_document_name" {
  description = "Name of the SSM Automation document"
  value       = module.s3_access_logging.ssm_document_name
}

output "iam_role_arn" {
  description = "ARN of the SSM automation IAM role"
  value       = module.s3_access_logging.iam_role_arn
}

output "non_compliant_resources_cli_command" {
  description = "Run this command to see all S3 buckets currently flagged as non-compliant"
  value       = module.s3_access_logging.non_compliant_resources_cli_command
}
