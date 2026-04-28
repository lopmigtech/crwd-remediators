variable "name_prefix" {
  type        = string
  description = "Prefix for resource names."
  default     = "example"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default     = {}
}

variable "config_rule_name" {
  type        = string
  description = "Name of the deployed iam-wildcard-action-policy Config rule."
}

variable "refresh_schedule_minutes" {
  type        = number
  description = "Refresh cadence in minutes."
  default     = 15
}

variable "presigned_url_ttl_seconds" {
  type        = number
  description = "Presigned URL TTL in seconds."
  default     = 3600
}

variable "log_retention_days" {
  type        = number
  description = "CloudWatch Logs retention."
  default     = 30
}

variable "access_log_bucket" {
  type        = string
  description = "Optional S3 access log target bucket."
  default     = null
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "Policy IDs to filter out of the dashboard."
  default     = []
}
