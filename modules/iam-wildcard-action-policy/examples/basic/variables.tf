variable "name_prefix" {
  type        = string
  description = "Prefix used for naming Config rule, IAM role, and SSM document."
  default     = "example"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources created by this module."
  default     = {}
}

variable "automatic_remediation" {
  type        = bool
  description = "Whether AWS Config automatically invokes the SSM remediation on non-compliant resources."
  default     = false
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "Policy ARNs to exempt from remediation."
  default     = []
}

variable "cloudtrail_lookback_days" {
  type        = number
  description = "Number of days of CloudTrail history to analyze."
  default     = 90
}

variable "min_actions_threshold" {
  type        = number
  description = "Minimum distinct actions from CloudTrail before auto-scoping."
  default     = 3
}

variable "report_s3_bucket" {
  type        = string
  description = "Optional S3 bucket for writing detailed analysis reports."
  default     = ""
}
