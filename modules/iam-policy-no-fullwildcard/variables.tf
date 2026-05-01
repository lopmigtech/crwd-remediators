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
  description = "Whether AWS Config automatically invokes the SSM remediation. Defaults to false (dry-run)."
  default     = false
}

variable "maximum_automatic_attempts" {
  type        = number
  description = "Maximum number of automatic remediation attempts per resource."
  default     = 3
  validation {
    condition     = var.maximum_automatic_attempts >= 1 && var.maximum_automatic_attempts <= 25
    error_message = "maximum_automatic_attempts must be between 1 and 25."
  }
}

variable "retry_attempt_seconds" {
  type        = number
  description = "Seconds between retry attempts."
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
  description = "Customer-managed policy ARNs to exempt from remediation. Honored in-document by CheckExclusion."
  default     = []
}

variable "remediation_action" {
  type        = string
  description = "SSM document Action mode. v1.0 supports 'tag-and-route' only — auto-scoping full wildcards from CloudTrail produces low-confidence results, so the design intentionally does not auto-rewrite full-wildcard customer-managed policies."
  default     = "tag-and-route"
  validation {
    condition     = contains(["tag-and-route"], var.remediation_action)
    error_message = "remediation_action must be 'tag-and-route' in this release."
  }
}

variable "evaluation_frequency" {
  type        = string
  description = "How often Config re-evaluates all in-scope IAM policies. Use 'Off' to disable scheduled evaluation (change-triggered only)."
  default     = "TwentyFour_Hours"
  validation {
    condition     = contains(["Off", "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"], var.evaluation_frequency)
    error_message = "evaluation_frequency must be one of: Off, One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}

variable "tag_based_exemption_enabled" {
  type        = bool
  description = "If true, the SSM document reads policy tags and skips remediation when the exemption tag is present."
  default     = true
}

variable "exemption_tag_key" {
  type        = string
  description = "Tag key checked on the policy for exemption."
  default     = "CrwdRemediatorExempt"
}

variable "require_exemption_reason" {
  type        = bool
  description = "If true, exemption is only honored when CrwdRemediatorExemptReason tag is non-empty."
  default     = true
}
