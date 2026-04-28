variable "name_prefix" {
  type        = string
  description = "Prefix used for naming the S3 bucket, Lambdas, IAM roles, and EventBridge rule."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources created by this module."
  default     = {}
}

# --- Module-specific inputs ---

variable "config_rule_name" {
  type        = string
  description = "Name of the AWS Config rule deployed by the iam-wildcard-action-policy module. Wire this from module.iam_wildcard_action_policy.config_rule_name."
}

variable "refresh_schedule_minutes" {
  type        = number
  description = "How often the refresh Lambda renders the dashboard. Lower values give fresher data; higher values reduce Config API call rate."
  default     = 15
  validation {
    condition     = var.refresh_schedule_minutes >= 5 && var.refresh_schedule_minutes <= 60
    error_message = "refresh_schedule_minutes must be between 5 and 60."
  }
}

variable "presigned_url_ttl_seconds" {
  type        = number
  description = "TTL of the presigned S3 URL the redirect Lambda generates. Stakeholders following the URL after expiry get an AWS-side 403."
  default     = 3600
  validation {
    condition     = var.presigned_url_ttl_seconds >= 60 && var.presigned_url_ttl_seconds <= 43200
    error_message = "presigned_url_ttl_seconds must be between 60 (1 minute) and 43200 (12 hours)."
  }
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention in days for both Lambdas. Must be one of AWS-supported values."
  default     = 30
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "log_retention_days must be one of: 1, 3, 5, 7, 14, 30, 60, 90, 180, 365, 400, 545, 731, 1827, 3653."
  }
}

variable "access_log_bucket" {
  type        = string
  description = "Optional S3 bucket name to receive server-access logs. If null, server-access logging is disabled and the consumer accepts the resulting s3-access-logging finding."
  default     = null
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "IAM policy IDs to filter out of the dashboard display. Honored by the refresh Lambda's collect step (Tier 2 exclusion per Rule 11)."
  default     = []
}
