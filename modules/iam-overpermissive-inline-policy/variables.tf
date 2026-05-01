variable "name_prefix" {
  type        = string
  description = "Prefix used for naming Config rule, IAM role, Lambda function, and SSM document."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all taggable resources created by this module."
  default     = {}
}

variable "automatic_remediation" {
  type        = bool
  description = "Whether AWS Config automatically invokes the SSM remediation on non-compliant resources. Defaults to false (dry-run)."
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
  description = "Composite resource IDs (<principal-type>/<name>[#<inline-policy-name>]) to exempt from remediation. Honored in-document by CheckExclusion."
  default     = []
}

variable "remediation_action" {
  type        = string
  description = "SSM document Action mode invoked by Config when automatic_remediation = true. Valid in v1.0: 'analyze' (tag-only). Future: backup-only, scope-and-backup, delete-and-backup."
  default     = "analyze"
  validation {
    condition     = contains(["analyze"], var.remediation_action)
    error_message = "remediation_action must be 'analyze' in this release. Mutating modes ship in a later version."
  }
}

variable "evaluation_frequency" {
  type        = string
  description = "How often Config re-evaluates all in-scope IAM principals. Use 'Off' to disable scheduled evaluation (change-triggered only)."
  default     = "TwentyFour_Hours"
  validation {
    condition     = contains(["Off", "One_Hour", "Three_Hours", "Six_Hours", "Twelve_Hours", "TwentyFour_Hours"], var.evaluation_frequency)
    error_message = "evaluation_frequency must be one of: Off, One_Hour, Three_Hours, Six_Hours, Twelve_Hours, TwentyFour_Hours."
  }
}

variable "tag_based_exemption_enabled" {
  type        = bool
  description = "If true, the SSM document's CheckExclusion step reads principal tags and skips remediation when the exemption tag is present."
  default     = true
}

variable "exemption_tag_key" {
  type        = string
  description = "Tag key checked on the principal for exemption."
  default     = "CrwdRemediatorExempt"
}

variable "require_exemption_reason" {
  type        = bool
  description = "If true, the exemption tag is only honored when a companion CrwdRemediatorExemptReason tag contains a non-empty string."
  default     = true
}

variable "inline_backup_s3_bucket" {
  type        = string
  description = "S3 bucket for inline-policy backups before any mutation. Required in future versions when a mutating mode is selected. Reserved for forward compatibility."
  default     = ""
}

variable "enable_role_remediation" {
  type        = bool
  description = "Allow the SSM document to mutate inline policies on AWS::IAM::Role principals."
  default     = true
}

variable "enable_user_remediation" {
  type        = bool
  description = "Allow the SSM document to mutate inline policies on AWS::IAM::User principals."
  default     = true
}

variable "enable_group_remediation" {
  type        = bool
  description = "Opt-in. Allow the SSM document to mutate inline policies on AWS::IAM::Group principals. Group remediation has fan-out blast radius — one delete affects every group member."
  default     = false
}

variable "cloudtrail_lookback_days" {
  type        = number
  description = "Days of CloudTrail history to scan when generating action suggestions. Reserved for future scope-and-backup mode."
  default     = 90
  validation {
    condition     = var.cloudtrail_lookback_days >= 1 && var.cloudtrail_lookback_days <= 365
    error_message = "cloudtrail_lookback_days must be between 1 and 365."
  }
}

variable "min_actions_threshold" {
  type        = number
  description = "Minimum distinct CloudTrail actions before scope-and-backup proceeds. Reserved for future mutating mode."
  default     = 3
  validation {
    condition     = var.min_actions_threshold >= 1 && var.min_actions_threshold <= 100
    error_message = "min_actions_threshold must be between 1 and 100."
  }
}
