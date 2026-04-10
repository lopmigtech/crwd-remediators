variable "name_prefix" {
  type        = string
  description = "Prefix used for naming Config rule, IAM role, and SSM document."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources created by this module."
  default     = {}
}

variable "automatic_remediation" {
  type        = bool
  description = "Whether AWS Config automatically invokes the SSM remediation on non-compliant resources. Defaults to false (dry-run). Flip to true after reviewing the non-compliance list."
  default     = false
}

variable "maximum_automatic_attempts" {
  type        = number
  description = "Maximum number of automatic remediation attempts per resource. Valid range: 1-25."
  default     = 3
  validation {
    condition     = var.maximum_automatic_attempts >= 1 && var.maximum_automatic_attempts <= 25
    error_message = "maximum_automatic_attempts must be between 1 and 25."
  }
}

variable "retry_attempt_seconds" {
  type        = number
  description = "Seconds between retry attempts. Valid range: 1-2678000."
  default     = 300
  validation {
    condition     = var.retry_attempt_seconds >= 1 && var.retry_attempt_seconds <= 2678000
    error_message = "retry_attempt_seconds must be between 1 and 2678000."
  }
}

variable "config_rule_input_parameters" {
  type        = map(string)
  description = "Optional additional parameters for the Config rule (JSON-encoded automatically)."
  default     = {}
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "Resource IDs to exempt from remediation. Honored in-document by Tier 1 modules; Tier 2 modules delegate exclusion to the operator via aws configservice put-remediation-exceptions."
  default     = []
}

# --- Module-specific inputs ---

variable "use_custom_ssm_document" {
  type        = bool
  description = "Whether the module creates its own SSM Automation document with exclusion support. Defaults to true (Tier 1)."
  default     = true
}

variable "aws_managed_ssm_document_name" {
  type        = string
  description = "Name of the AWS managed SSM Automation document to use when use_custom_ssm_document is false."
  default     = "AWS-ConfigureS3BucketLogging"
}

variable "log_destination_bucket" {
  type        = string
  description = "Name of the S3 bucket that receives server access logs. This bucket is inherently excluded from remediation to prevent an infinite logging loop."
}

variable "log_destination_prefix" {
  type        = string
  description = "Prefix for log objects in the destination bucket. Leave empty for no prefix."
  default     = ""
}
