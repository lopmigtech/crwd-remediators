provider "aws" {
  region = "us-east-1"
}

module "iam_wildcard_dashboard" {
  source = "../../"

  name_prefix               = var.name_prefix
  tags                      = var.tags
  config_rule_name          = var.config_rule_name
  refresh_schedule_minutes  = var.refresh_schedule_minutes
  presigned_url_ttl_seconds = var.presigned_url_ttl_seconds
  log_retention_days        = var.log_retention_days
  access_log_bucket         = var.access_log_bucket
  excluded_resource_ids     = var.excluded_resource_ids
}
