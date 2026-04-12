variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources."
  default     = "example"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply."
  default     = {}
}

variable "automatic_remediation" {
  type        = bool
  description = "Enable auto-assessment (Phase 1 only -- safe)."
  default     = false
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "Table names to exclude from remediation."
  default     = []
}

variable "create_kms_key" {
  type        = bool
  description = "Whether to create a KMS key."
  default     = true
}

variable "kms_key_arn" {
  type        = string
  description = "ARN of an existing KMS key (only if create_kms_key = false)."
  default     = ""
}

variable "assessment_tag_key" {
  type        = string
  description = "Tag key for assessment markers."
  default     = "CrwdRemediation"
}

variable "sns_topic_arn" {
  type        = string
  description = "Optional SNS topic for notifications."
  default     = ""
}
