variable "name_prefix" {
  type        = string
  description = "Prefix used for naming Config rule, IAM role, Lambda function, and SSM document."
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

variable "remediation_action" {
  type        = string
  description = "SSM document Action mode. v1.0 supports 'analyze' only."
  default     = "analyze"
}

variable "evaluation_frequency" {
  type        = string
  description = "How often Config re-evaluates all in-scope IAM principals."
  default     = "TwentyFour_Hours"
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "Composite resource IDs to exempt from remediation."
  default     = []
}

variable "tag_based_exemption_enabled" {
  type        = bool
  description = "Read principal tags for exemption."
  default     = true
}

variable "exemption_tag_key" {
  type        = string
  description = "Tag key checked on the principal for exemption."
  default     = "CrwdRemediatorExempt"
}

variable "require_exemption_reason" {
  type        = bool
  description = "Require a non-empty companion reason tag for exemption."
  default     = true
}

variable "enable_role_remediation" {
  type        = bool
  default     = true
  description = "Reserved for future mutating modes."
}

variable "enable_user_remediation" {
  type        = bool
  default     = true
  description = "Reserved for future mutating modes."
}

variable "enable_group_remediation" {
  type        = bool
  default     = false
  description = "Opt-in. Reserved for future mutating modes."
}
