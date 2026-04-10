################################################################################
# Standard inputs (7 required by all crwd-remediator modules)
################################################################################

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
  description = "Resource IDs to exempt from remediation. Honored in-document by this Tier 1 module — the SSM wrapper checks this list before any action."
  default     = []
}

################################################################################
# Module-specific inputs
################################################################################

variable "kms_key_arn" {
  type        = string
  description = "ARN of the customer-managed KMS key for Phase 2 encryption. Used when manually triggering encryption on assessed tables. The module optionally creates a key if create_kms_key = true."
  default     = ""
}

variable "create_kms_key" {
  type        = bool
  description = "Whether to create a new customer-managed KMS key for DynamoDB encryption. If true, the module creates a key and uses it. If false, provide kms_key_arn."
  default     = true
}

variable "assessment_tag_key" {
  type        = string
  description = "Tag key applied to non-compliant tables during Phase 1 assessment."
  default     = "CrwdRemediation"
}

variable "sns_topic_arn" {
  type        = string
  description = "Optional SNS topic ARN for notifications when tables are assessed. Leave empty to skip notifications."
  default     = ""
}
