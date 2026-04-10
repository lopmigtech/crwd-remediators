provider "aws" {
  region = "us-east-1"
}

module "s3_access_logging" {
  source = "../../modules/s3-access-logging"

  name_prefix            = "demo"
  log_destination_bucket = "demo-s3-access-logs-934791682619"
  log_destination_prefix = "s3-logs/"

  # Dry-run: Config detects, SSM does NOT auto-remediate
  # automatic_remediation = false  (this is the default)

  # Operational exclusions (in addition to the inherent exclusion
  # of the log destination bucket, which is auto-handled by the
  # SSM wrapper's CheckExclusion step)
  excluded_resource_ids = []

  tags = {
    Environment = "demo"
    Project     = "crwd-remediators-test"
  }
}

output "config_rule_name" {
  value = module.s3_access_logging.config_rule_name
}

output "ssm_document_name" {
  value = module.s3_access_logging.ssm_document_name
}

output "non_compliant_resources_cli_command" {
  value = module.s3_access_logging.non_compliant_resources_cli_command
}

output "iam_role_arn" {
  value = module.s3_access_logging.iam_role_arn
}
