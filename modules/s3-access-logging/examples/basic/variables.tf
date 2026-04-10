variable "name_prefix" {
  type        = string
  description = "Prefix used for naming all resources created by this module."
}

variable "log_destination_bucket" {
  type        = string
  description = "Name of the S3 bucket that receives server access logs."
}

variable "log_destination_prefix" {
  type        = string
  description = "Optional key prefix for log objects in the destination bucket."
  default     = ""
}

variable "automatic_remediation" {
  type        = bool
  description = "Whether AWS Config automatically invokes SSM remediation. Keep false until you have reviewed the non-compliance list."
  default     = false
}

variable "excluded_resource_ids" {
  type        = list(string)
  description = "Bucket names to exempt from remediation."
  default     = []
}
