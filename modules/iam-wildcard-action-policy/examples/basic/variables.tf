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

variable "remediation_action" {
  type        = string
  description = "SSM action Config invokes automatically."
  default     = "analyze"
}

variable "evaluation_frequency" {
  type        = string
  description = "How often Config re-evaluates all IAM policies."
  default     = "TwentyFour_Hours"
}

variable "flap_window_days" {
  type        = number
  description = "Days within which successive scopes count as a flap."
  default     = 7
}

variable "tag_based_exemption_enabled" {
  type        = bool
  description = "Honor CrwdRemediatorExempt tag on policies."
  default     = true
}

variable "exemption_tag_key" {
  type        = string
  description = "Tag key checked for exemption."
  default     = "CrwdRemediatorExempt"
}

variable "require_exemption_reason" {
  type        = bool
  description = "Require a companion reason tag for exemption to be honored."
  default     = true
}

variable "auto_exempt_on_flap_enabled" {
  type        = bool
  description = "Auto-apply exemption tag on flap-threshold policies."
  default     = false
}

variable "auto_exempt_flap_threshold" {
  type        = number
  description = "Flap count that triggers auto-exempt."
  default     = 3
}

variable "auto_exempt_duration_days" {
  type        = number
  description = "Days until auto-applied exemption expires."
  default     = 30
}
