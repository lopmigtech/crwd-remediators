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
  description = "Resource IDs to exempt from remediation. Honored in-document by the SSM wrapper's CheckExclusion step (Tier 1)."
  default     = []
}

# --- Module-specific inputs ---

variable "cloudtrail_lookback_days" {
  type        = number
  description = "Number of days of CloudTrail history to analyze when determining which specific actions a role uses. More days = more confidence, but slower queries."
  default     = 90
  validation {
    condition     = var.cloudtrail_lookback_days >= 1 && var.cloudtrail_lookback_days <= 365
    error_message = "cloudtrail_lookback_days must be between 1 and 365."
  }
}

variable "min_actions_threshold" {
  type        = number
  description = "Minimum number of distinct actions found in CloudTrail before auto-scoping. Below this threshold, the policy is tagged as NeedsManualReview instead of auto-scoped."
  default     = 3
  validation {
    condition     = var.min_actions_threshold >= 1 && var.min_actions_threshold <= 100
    error_message = "min_actions_threshold must be between 1 and 100."
  }
}

variable "report_s3_bucket" {
  type        = string
  description = "Optional S3 bucket for writing detailed analysis reports. Leave empty to store results in policy tags only."
  default     = ""
}

variable "remediation_action" {
  type        = string
  description = "SSM document Action parameter that Config invokes when automatic_remediation = true. Valid: 'analyze' (tag-only), 'scope-simple' (auto-rewrite single-wildcard policies), 'suggest-moderate' (generate suggestions for multi-wildcard policies)."
  default     = "analyze"
  validation {
    condition     = contains(["analyze", "scope-simple", "suggest-moderate"], var.remediation_action)
    error_message = "remediation_action must be one of: analyze, scope-simple, suggest-moderate."
  }
}

variable "evaluation_frequency" {
  type        = string
  description = "How often Config re-evaluates all in-scope IAM policies. Valid AWS Config MaximumExecutionFrequency values, or 'Off' to disable scheduled evaluation (change-triggered only)."
  default     = "TwentyFour_Hours"
  validation {
    condition     = contains(["Off", "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"], var.evaluation_frequency)
    error_message = "evaluation_frequency must be one of: Off, One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}
